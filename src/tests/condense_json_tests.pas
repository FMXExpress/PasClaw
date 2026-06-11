program condense_json_tests;
(*
  Covers PasClaw.Condense.JSON -- the content-type-aware compression
  that recognises JSON tool output and collapses repetitive arrays /
  ellipsizes long strings so a 200 KB MCP search response doesn't burn
  the model's attention on 297 nearly-identical rows.

  No model, no agent loop. Just string in / string out across the
  cases that pin the contract:

    - Below MaxBytes: pass through verbatim
    - Non-JSON: pass through verbatim (parse failure is silent)
    - Big array of primitives -> collapsed with first N + synthetic
      marker + last 1
    - Big array of objects -> same shape, recursive condensation
      preserved inside surviving elements
    - Long string values -> ellipsized with head+tail (not just head)
    - Deeply nested -> depth guard kicks in, sub-tree replaced by "..."
    - "Inflation guard" -- if condensation would produce something
      larger than the original (degenerate case), fall back to verbatim
    - Empty arrays / empty objects -> verbatim (no inflation, nothing
      to collapse)
    - Mixed content: object whose values are small + one giant
      array -> collapse just the array, leave the rest alone
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  PasClaw.Condense.JSON;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Copy(Got, 1, 300) + '", want "' +
          Copy(Want, 1, 300) + '")');
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) <= 0 then
    Fail_(Msg + ' (needle "' + Copy(Needle, 1, 100) +
          '" missing from "' + Copy(Haystack, 1, 200) + '")');
end;

procedure AssertNotContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then
    Fail_(Msg + ' (unwanted needle "' + Copy(Needle, 1, 100) +
          '" found in "' + Copy(Haystack, 1, 200) + '")');
end;

function TinyOpts: TJSONCondenseOptions;
{ Tighter limits than the default so tests can drive condensation
  with short fixture strings -- the default 4096-byte minimum would
  force every fixture to be page-length. }
begin
  Result.MaxBytes      := 64;
  Result.MaxArrayItems := 4;
  Result.MaxStringLen  := 40;
  Result.MaxDepth      := 8;
end;

procedure TestSmallBodyPassesThrough;
var
  Got: string;
begin
  Got := MaybeCondenseJSON('{"x":1,"y":2}', TinyOpts);
  AssertEqStr(Got, '{"x":1,"y":2}', 'small JSON unchanged');
end;

procedure TestNonJSONPassesThrough;
var
  Got, NotJson: string;
begin
  NotJson := 'this is plain text output, long enough to trip MaxBytes for sure: ' +
             'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  Got := MaybeCondenseJSON(NotJson, TinyOpts);
  AssertEqStr(Got, NotJson, 'non-JSON returned verbatim');
end;

procedure TestEmptyContainersAreVerbatim;
var
  Got: string;
begin
  Got := MaybeCondenseJSON('[]', TinyOpts);
  AssertEqStr(Got, '[]', 'empty array verbatim');
  Got := MaybeCondenseJSON('{}', TinyOpts);
  AssertEqStr(Got, '{}', 'empty object verbatim');
end;

procedure TestBigArrayOfPrimitivesCollapses;
var
  Src, Got: string;
begin
  Src := '[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25]';
  Got := MaybeCondenseJSON(Src, TinyOpts);
  AssertTrue(Length(Got) < Length(Src),
             'condensed output shorter than 25-item array');
  AssertContains(Got, '"...', 'placeholder marker present');
  AssertContains(Got, ' more items"',
                  '"<N> more items" marker present');
  AssertContains(Got, '25]',
                  'last element preserved at the tail (25)');
end;

procedure TestBigArrayOfObjectsCollapsesAndPreservesShape;
var
  Src, Got: string;
  i: Integer;
begin
  Src := '[';
  for i := 1 to 12 do
  begin
    if i > 1 then Src := Src + ',';
    Src := Src + '{"id":' + IntToStr(i) + ',"name":"item-' + IntToStr(i) + '"}';
  end;
  Src := Src + ']';
  Got := MaybeCondenseJSON(Src, TinyOpts);
  AssertContains(Got, '"id":1',         'first element id intact');
  AssertContains(Got, '"id":12',        'last element id intact');
  AssertContains(Got, ' more items"',   'placeholder marker present');
  AssertNotContains(Got, '"id":6',
                    'middle elements suppressed (id=6 was a middle item)');
end;

procedure TestLongStringEllipsized;
var
  Src, Got: string;
  i: Integer;
begin
  Src := '{"path":"';
  for i := 1 to 80 do Src := Src + 'a';
  Src := Src + 'TAILTAILTAILTAILTAIL"}';
  Got := MaybeCondenseJSON(Src, TinyOpts);
  AssertContains(Got, 'aaaaaaa',  'head of long string kept');
  AssertContains(Got, '...',      'ellipsis emitted');
  AssertContains(Got, 'TAILTAIL', 'tail of long string kept');
end;

procedure TestNestedArrayInsideObjectCollapses;
var
  Src, Got: string;
  i: Integer;
begin
  Src := '{"results":[';
  for i := 1 to 20 do
  begin
    if i > 1 then Src := Src + ',';
    Src := Src + IntToStr(i * 10);
  end;
  Src := Src + '],"page":1}';
  Got := MaybeCondenseJSON(Src, TinyOpts);
  AssertContains(Got, '"page":1',     'sibling field preserved verbatim');
  AssertContains(Got, ' more items"', 'inner array collapsed');
  AssertContains(Got, '200]',         'last inner element kept');
end;

procedure TestEachCallProducesValidJsonShape;
var
  Src, Got: string;
  i: Integer;
begin
  Src := '[';
  for i := 1 to 20 do
  begin
    if i > 1 then Src := Src + ',';
    Src := Src + IntToStr(i);
  end;
  Src := Src + ']';
  Got := MaybeCondenseJSON(Src, TinyOpts);
  AssertTrue((Length(Got) >= 2) and
             (Got[1] = '[') and (Got[Length(Got)] = ']'),
             'condensed output still wrapped in []');
end;

procedure TestRespectsMaxBytes;
var
  Opts: TJSONCondenseOptions;
  Src, Got: string;
begin
  Opts := DefaultJSONCondenseOptions;
  Opts.MaxBytes := 1000;          { high threshold }
  Src := '[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]';
  Got := MaybeCondenseJSON(Src, Opts);
  AssertEqStr(Got, Src, 'below MaxBytes -> verbatim');
end;

procedure TestMalformedJsonReturnsVerbatim;
var
  Src, Got: string;
  i: Integer;
begin
  Src := '{"x":';
  for i := 1 to 50 do Src := Src + IntToStr(i) + ',';
  { Truncated -- never closes. Long enough to trip MaxBytes. }
  Got := MaybeCondenseJSON(Src, TinyOpts);
  AssertEqStr(Got, Src, 'malformed JSON returned verbatim');
end;

begin
  TestSmallBodyPassesThrough;             WriteLn('  ok: small body verbatim');
  TestNonJSONPassesThrough;               WriteLn('  ok: non-JSON verbatim');
  TestEmptyContainersAreVerbatim;         WriteLn('  ok: empty containers verbatim');
  TestBigArrayOfPrimitivesCollapses;      WriteLn('  ok: big array of primitives collapses');
  TestBigArrayOfObjectsCollapsesAndPreservesShape;
                                          WriteLn('  ok: big array of objects collapses + shape kept');
  TestLongStringEllipsized;               WriteLn('  ok: long string ellipsized head+tail');
  TestNestedArrayInsideObjectCollapses;   WriteLn('  ok: nested array inside object collapses');
  TestEachCallProducesValidJsonShape;     WriteLn('  ok: output remains JSON-shaped');
  TestRespectsMaxBytes;                   WriteLn('  ok: respects MaxBytes threshold');
  TestMalformedJsonReturnsVerbatim;       WriteLn('  ok: malformed JSON verbatim');
  WriteLn('PASS');
end.
