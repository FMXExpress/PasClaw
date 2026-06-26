program memory_autodistill_tests;
(*
  Covers the pure logic in PasClaw.Memory.AutoDistill -- BuildRecentTranscript,
  which selects the recent tail handed to the per-turn distiller. The
  background thread / store glue is exercised via the distill + facts
  suites; here we just pin the windowing contract:

    - keeps at most MaxMsgs trailing messages
    - appends FinalContent as a trailing assistant message when non-empty
    - omits the assistant message when FinalContent is blank
    - returns everything (plus final) when the history is shorter than the window
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Providers.Types,
  PasClaw.Memory.AutoDistill;

procedure Fail_(const Msg: string);
begin WriteLn('FAIL: ' + Msg); Halt(1); end;

procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want])); end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;

function Hist(N: Integer): TMessageArray;
var i: Integer;
begin
  SetLength(Result, N);
  for i := 0 to N - 1 do
    Result[i] := MakeMessage(mrUser, 'm' + IntToStr(i));
end;

procedure TestWindowCapsTail;
var
  R: TMessageArray;
begin
  { 10 messages, window 4, no final -> last 4 (m6..m9). }
  R := BuildRecentTranscript(Hist(10), '', 4);
  AssertEqInt(Length(R), 4, 'capped to window');
  AssertEqStr(R[0].Content, 'm6', 'tail starts at m6');
  AssertEqStr(R[3].Content, 'm9', 'tail ends at m9');
end;

procedure TestFinalContentAppended;
var
  R: TMessageArray;
begin
  R := BuildRecentTranscript(Hist(3), 'the answer', 8);
  AssertEqInt(Length(R), 4, '3 history + 1 final');
  AssertEqStr(R[3].Content, 'the answer', 'final appended last');
  if R[3].Role <> mrAssistant then Fail_('final is an assistant message');
end;

procedure TestBlankFinalOmitted;
var
  R: TMessageArray;
begin
  R := BuildRecentTranscript(Hist(2), '   ', 8);
  AssertEqInt(Length(R), 2, 'blank final not appended');
end;

procedure TestShortHistoryKeptWhole;
var
  R: TMessageArray;
begin
  R := BuildRecentTranscript(Hist(2), 'x', 8);
  AssertEqInt(Length(R), 3, 'short history kept whole + final');
  AssertEqStr(R[0].Content, 'm0', 'first kept');
end;

begin
  TestWindowCapsTail;        WriteLn('  ok: window caps the tail');
  TestFinalContentAppended;  WriteLn('  ok: final content appended as assistant');
  TestBlankFinalOmitted;     WriteLn('  ok: blank final omitted');
  TestShortHistoryKeptWhole; WriteLn('  ok: short history kept whole');
  WriteLn('PASS');
end.
