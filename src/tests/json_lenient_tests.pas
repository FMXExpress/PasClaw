program json_lenient_tests;
(*
  Pins the lenient-parse retry added to PasClaw.JSON: a raw control char
  (bare newline / tab) INSIDE a JSON string -- which strict RFC-8259 parsers
  (FPC's jsonscanner) reject with "string exceeds end of line" -- is repaired
  and parsed instead of crashing the caller. Reproduces the EPasClawJSON crash
  seen on a real Gemini build (an agent tool-call/response carrying an
  unescaped newline).

  Well-formed JSON must be UNAFFECTED (the retry only runs after a strict
  parse fails, and the sanitizer is a no-op on already-valid input).
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  PasClaw.JSON;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure EqS(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got ' + QuotedStr(Got) + ', want ' + QuotedStr(Want) + ')'); end;
procedure IsTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;

var
  O: TJsonObject;
  A: TJsonArray;
  Raised: Boolean;
const
  LF = #10;
  TAB = #9;
begin
  { 1. Literal newline inside a string value -> repaired, value preserved. }
  O := TJsonObject.Parse('{"content":"line1' + LF + 'line2"}');
  IsTrue(O <> nil, 'object with a bare newline in a string must parse');
  EqS(O.GetStr('content'), 'line1' + LF + 'line2',
      'the newline survives as a real newline in the parsed value');
  O.Free;

  { 2. Literal tab inside a string. }
  O := TJsonObject.Parse('{"k":"a' + TAB + 'b"}');
  IsTrue(O <> nil, 'bare tab in a string must parse');
  EqS(O.GetStr('k'), 'a' + TAB + 'b', 'tab preserved');
  O.Free;

  { 3. Already-escaped \n is unaffected (well-formed, no retry needed). }
  O := TJsonObject.Parse('{"a":"b\nc"}');
  EqS(O.GetStr('a'), 'b' + LF + 'c', 'escaped \n decodes to a newline as usual');
  O.Free;

  { 4. Pretty-printed JSON (newlines BETWEEN tokens, outside strings) is fine. }
  O := TJsonObject.Parse('{' + LF + '  "x": "y"' + LF + '}');
  EqS(O.GetStr('x'), 'y', 'structural whitespace newlines never mangled');
  O.Free;

  { 5. Structural chars INSIDE a string are not mistaken for structure even
       when a repair happens elsewhere -- string state machine correctness. }
  O := TJsonObject.Parse('{"s":"a},{' + LF + '\"q\": b"}');
  IsTrue(O <> nil, 'braces/commas/escaped-quotes inside a string parse');
  EqS(O.GetStr('s'), 'a},{' + LF + '"q": b', 'string content with braces + escaped quote intact');
  O.Free;

  { 6. Array with a bare newline in an element string. }
  A := TJsonArray.Parse('["ok","x' + LF + 'y"]');
  IsTrue((A <> nil) and (A.Count = 2), 'array with a bare newline must parse');
  EqS(A.ItemStr(1), 'x' + LF + 'y', 'array element newline preserved');
  A.Free;

  { 7. Genuinely invalid JSON (not a control-char issue) still raises. }
  Raised := False;
  try
    O := TJsonObject.Parse('{"a": }');
    if O <> nil then O.Free;
  except
    on EPasClawJSON do Raised := True;
  end;
  IsTrue(Raised, 'structurally invalid JSON still raises EPasClawJSON');

  WriteLn('  ok: bare control chars inside strings repaired; valid JSON untouched; bad JSON still errors');
  WriteLn('json_lenient_tests: OK');
end.
