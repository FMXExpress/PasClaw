program turn_clock_tests;
(*
  The per-turn clock: a model with no stated time falls back to its
  training cutoff, which silently corrupts date arithmetic, "is this still
  current" judgements, relative-time reasoning and anything schedule
  shaped. PasClaw stated the date nowhere -- it leaked in only as a memory
  file heading, and only when that day's file happened to exist.

  What this pins is mostly WHERE the clock goes, because that is the part
  with a cost attached:

    - The system block carries the cache_control breakpoint, so a clock
      there would invalidate the provider prefix cache on every single
      call. The progress ledger's own header states the constraint as
      "NO counters, no timestamps". The clock therefore rides in the
      messages array, which sits after both the system and last-tool
      breakpoints.

    - It extends the trailing USER message rather than adding one. A
      trailing mrSystem message would be hoisted into the system prompt by
      the Anthropic provider (it scans Messages for the first mrSystem
      when Options.SystemPrompt is empty), landing back in the cached
      prefix; a fresh mrUser message appended after tool results would sit
      between a tool_use and its tool_result.

    - The caller's history is never mutated, or every persisted transcript
      would accumulate a stamp per turn.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Utils,
  PasClaw.Providers.Types,
  PasClaw.Tools.ToolLoop;

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

procedure TestStampShape;
var
  S: string;
begin
  WriteLn('the stamp says what a model needs');
  S := NowStampWithZone;
  WriteLn('        ', S);
  { A bare local time is ambiguous and a bare UTC time makes the model do
    arithmetic to answer "what time is it here" -- so both, plus the
    offset that relates them. }
  Check('carries a UTC offset', Pos('UTC+', S) + Pos('UTC-', S) > 0);
  Check('carries the UTC equivalent', Pos('Z)', S) > 0);
  { "next Monday" is a question models actually get asked. }
  Check('names the weekday',
    (Pos('Mon', S) + Pos('Tue', S) + Pos('Wed', S) + Pos('Thu', S) +
     Pos('Fri', S) + Pos('Sat', S) + Pos('Sun', S)) > 0);
  Check('is a four-digit year', Pos('20', S) > 0);
end;

procedure TestInjectedIntoTheStream;
var
  Hist, Out_: TMessageArray;
begin
  WriteLn('the clock reaches the model');
  SetLength(Hist, 1);
  Hist[0].Role := mrUser;
  Hist[0].Content := 'what day is it?';

  Out_ := HistWithTurnClock(Hist);
  Check('a stamp is appended', Pos('[current date/time:', Out_[0].Content) > 0);
  Check('the original text survives',
    Pos('what day is it?', Out_[0].Content) > 0);

  { The transcript is what gets persisted; it must not grow a stamp. }
  Check('the caller history is NOT mutated',
    Pos('[current date/time:', Hist[0].Content) = 0);
  Check('message count is unchanged', Length(Out_) = Length(Hist));
end;

procedure TestStaysOutOfTheCachedPrefix;
var
  Hist, Out_: TMessageArray;
begin
  WriteLn('the clock stays out of the cached prefix');

  { A trailing tool result must NOT be extended: the stamp would land
    between a tool_use and its tool_result. }
  SetLength(Hist, 2);
  Hist[0].Role := mrAssistant; Hist[0].Content := 'calling a tool';
  Hist[1].Role := mrTool;      Hist[1].Content := 'tool output';
  Out_ := HistWithTurnClock(Hist);
  Check('a trailing tool result is left alone',
    Pos('[current date/time:', Out_[1].Content) = 0);

  { No mrSystem message is ever created -- the Anthropic provider would
    hoist it into the system prompt, i.e. into the cached prefix. }
  SetLength(Hist, 1);
  Hist[0].Role := mrSystem; Hist[0].Content := 'you are a helper';
  Out_ := HistWithTurnClock(Hist);
  Check('a system message is never stamped',
    Pos('[current date/time:', Out_[0].Content) = 0);
  Check('no message is added to a system-only history',
    Length(Out_) = 1);
end;

procedure TestDegenerateInputs;
var
  Hist, Out_: TMessageArray;
begin
  WriteLn('degenerate histories');
  SetLength(Hist, 0);
  Out_ := HistWithTurnClock(Hist);
  Check('an empty history stays empty', Length(Out_) = 0);

  SetLength(Hist, 1);
  Hist[0].Role := mrUser;
  Hist[0].Content := '';
  Out_ := HistWithTurnClock(Hist);
  Check('an empty user turn is not stamped',
    Pos('[current date/time:', Out_[0].Content) = 0);
end;

begin
  WriteLn('per-turn clock');
  TestStampShape;
  TestInjectedIntoTheStream;
  TestStaysOutOfTheCachedPrefix;
  TestDegenerateInputs;
  WriteLn;
  if Failures = 0 then
    WriteLn('all turn clock tests passed')
  else
  begin
    WriteLn(Failures, ' turn clock test(s) FAILED');
    Halt(1);
  end;
end.
