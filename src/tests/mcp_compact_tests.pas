program mcp_compact_tests;
(*
  Covers PasClaw.MCP.Compact -- tabular re-encoding of MCP tool results.

  Pins:
    - a rectangular array of objects becomes a table, and the table is
      SHORTER than the JSON it replaces (the entire point)
    - an object wrapping the rows under a conventional key is found
    - values containing the delimiter, a backslash or a newline survive
      escaping, so a cell can never invent a column
    - wrapper SIBLINGS (next_cursor, total) survive the conversion, and a
      sibling that is itself a container refuses it outright -- an agent
      reads the compacted text, so a dropped cursor strands it mid-pagination
    - REFUSALS, which matter more than the conversions: ragged rows, nested
      values, too few rows, too few columns, free text and malformed JSON
      all come back untouched rather than half-reshaped
    - a conversion that would not be shorter is declined
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.MCP.Compact;

var
  Failures: Integer = 0;

procedure Check(const Name: string; Cond: Boolean);
begin
  if Cond then
    WriteLn('  ok    ', Name)
  else
  begin
    WriteLn('  FAIL  ', Name);
    Inc(Failures);
  end;
end;

procedure CheckEq(const Name, Expected, Actual: string);
begin
  if Expected = Actual then
    WriteLn('  ok    ', Name)
  else
  begin
    WriteLn('  FAIL  ', Name);
    WriteLn('        expected: ', Expected);
    WriteLn('        actual:   ', Actual);
    Inc(Failures);
  end;
end;

{ ---------------------------------------------------------------- helpers -- }

function RowsJSON(N: Integer): string;
var
  i: Integer;
begin
  Result := '[';
  for i := 1 to N do
  begin
    if i > 1 then
      Result := Result + ',';
    Result := Result + Format(
      '{"id":%d,"name":"row %d","role":"assistant","tokens":%d}',
      [i, i, 1000 + i]);
  end;
  Result := Result + ']';
end;

{ ------------------------------------------------------------------ tests -- }

procedure TestConverts;
var
  Src, Out_: string;
begin
  WriteLn('rectangular rows');
  Src := RowsJSON(12);
  Check('converts', CompactifyResultText(Src, Out_));
  Check('header names the shape', Pos('table 12x4: id|name|role|tokens', Out_) = 1);
  Check('a row is delimited, not repeated keys',
    Pos('1|row 1|assistant|1001', Out_) > 0);
  Check('no key repetition survives', Pos('"tokens"', Out_) = 0);
  Check('shorter than the JSON it replaces', Length(Out_) < Length(Src));
  WriteLn(Format('        %d chars -> %d (%d%% smaller)',
    [Length(Src), Length(Out_),
     Round(100 * (Length(Src) - Length(Out_)) / Length(Src))]));
end;

procedure TestWrapped;
var
  Out_: string;
begin
  WriteLn('rows under a wrapper key');
  Check('finds "rows"',
    CompactifyResultText('{"rows":' + RowsJSON(8) + '}', Out_));
  Check('header counts the wrapped rows', Pos('table 8x4:', Out_) = 1);
  Check('finds "results"',
    CompactifyResultText('{"results":' + RowsJSON(8) + '}', Out_));
end;

procedure TestSiblingsPreserved;
var
  Out_: string;
begin
  WriteLn('wrapper siblings (a dropped cursor strands the agent)');
  Check('converts with a cursor present', CompactifyResultText(
    '{"rows":' + RowsJSON(10) + ',"next_cursor":"abc123","total":250}', Out_));
  Check('next_cursor survives', Pos('next_cursor: abc123', Out_) > 0);
  Check('total survives',       Pos('total: 250', Out_) > 0);
  Check('siblings precede the table',
    Pos('next_cursor: abc123', Out_) < Pos('table 10x4:', Out_));
  Check('a cursor containing a pipe is NOT escaped (it is opaque)',
    CompactifyResultText('{"rows":' + RowsJSON(10) + ',"cur":"a|b"}', Out_)
    and (Pos('cur: a|b', Out_) > 0));
  Check('a container sibling refuses the whole conversion',
    not CompactifyResultText(
      '{"rows":' + RowsJSON(10) + ',"meta":{"page":1}}', Out_));
  Check('an array sibling refuses too',
    not CompactifyResultText(
      '{"rows":' + RowsJSON(10) + ',"warnings":["x"]}', Out_));
end;

procedure TestEscaping;
var
  Out_: string;
begin
  WriteLn('escaping');
  CheckEq('pipe cannot invent a column', 'a\|b', EscapeCell('a|b'));
  CheckEq('backslash escapes itself',    'a\\b', EscapeCell('a\b'));
  CheckEq('newline folds to \n',         'a\nb', EscapeCell('a'#10'b'));
  CheckEq('CR is dropped',               'ab',   EscapeCell('a'#13'b'));
  CheckEq('plain text untouched',        'hello world', EscapeCell('hello world'));

  Check('a piped VALUE keeps the column count',
    CompactifyResultText(
      '[{"a":"x|y","b":"1","c":"2"},{"a":"p","b":"3","c":"4"},' +
      '{"a":"q","b":"5","c":"6"},{"a":"r","b":"7","c":"8"}]', Out_));
  Check('the pipe arrives escaped', Pos('x\|y', Out_) > 0);
end;

procedure TestRefusals;
var
  Out_: string;
begin
  WriteLn('refusals (must return the original untouched)');
  Check('ragged rows refused', not CompactifyResultText(
    '[{"a":1,"b":2},{"a":1},{"a":1,"b":2},{"a":1,"b":2}]', Out_));
  Check('nested object refused', not CompactifyResultText(
    '[{"a":1,"b":{"c":2}},{"a":1,"b":{"c":2}},{"a":1,"b":{"c":2}}]', Out_));
  Check('nested array refused', not CompactifyResultText(
    '[{"a":1,"b":[1,2]},{"a":1,"b":[1,2]},{"a":1,"b":[1,2]}]', Out_));
  Check('too few rows refused', not CompactifyResultText(
    '[{"a":1,"b":2},{"a":3,"b":4}]', Out_));
  Check('single column refused', not CompactifyResultText(
    '[{"a":1},{"a":2},{"a":3},{"a":4}]', Out_));
  Check('array of scalars refused', not CompactifyResultText(
    '[1,2,3,4,5]', Out_));
  Check('free text refused', not CompactifyResultText(
    'the quick brown fox jumps over the lazy dog', Out_));
  Check('malformed JSON refused', not CompactifyResultText(
    '[{"a":1,"b":', Out_));
  Check('empty refused', not CompactifyResultText('', Out_));
  Check('a plain object refused', not CompactifyResultText(
    '{"a":1,"b":2,"c":3}', Out_));
end;

procedure TestNotShorterDeclined;
var
  Src, Out_: string;
begin
  WriteLn('a conversion that would not pay');
  { one-character keys and long values: the header costs more than the
    repeated keys save }
  Src := '[{"a":"' + StringOfChar('x', 400) + '","b":"1"},' +
         '{"a":"' + StringOfChar('y', 400) + '","b":"2"},' +
         '{"a":"' + StringOfChar('z', 400) + '","b":"3"}]';
  if CompactifyResultText(Src, Out_) then
    Check('declined or genuinely shorter', Length(Out_) < Length(Src))
  else
    Check('declined', True);
end;

begin
  WriteLn('PasClaw.MCP.Compact');
  TestConverts;
  TestWrapped;
  TestSiblingsPreserved;
  TestEscaping;
  TestRefusals;
  TestNotShorterDeclined;
  WriteLn;
  if Failures = 0 then
    WriteLn('all mcp compact tests passed')
  else
  begin
    WriteLn(Failures, ' mcp compact test(s) FAILED');
    Halt(1);
  end;
end.
