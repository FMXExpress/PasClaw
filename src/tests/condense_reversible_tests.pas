program condense_reversible_tests;
(*
  Covers PasClaw.Tools.OutputCache.AttachReversibleStashFooter -- the
  headroom-inspired CCR (reversible compression) layer that sits on
  top of the JSON / shell condensers. When the condenser shrinks tool
  output, the original gets stashed under an OutputCache handle and
  a footer naming it is appended so the model can retrieve the full
  text via tool_output_get when the structural view isn't enough.

  Contracts pinned:
    - Same-size input/output (no real condensation): no stash, no footer.
    - Saving below MinSavingsBytes floor: no stash, no footer.
    - Real saving: stash + footer + handle dereferences to the original.
    - SetCondenseReversible(False): always returns Condensed unchanged.
    - Counters accumulate across calls.
    - Idempotence is the caller's job -- we don't test "wrap of a wrap"
      because chokepoint 2's promptware uses a banner-mark guard;
      condense doesn't have that and the footer parse is the model's
      problem if a caller double-wraps.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Tools.OutputCache;

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
    Fail_(Msg + ' (got "' + Copy(Got, 1, 200) + '", want "' +
          Copy(Want, 1, 200) + '")');
end;

function MakeOriginal(N: Integer): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to N do Result := Result + 'x';
end;

procedure TestNoOpWhenNoSavings;
var
  Got: string;
begin
  ClearOutputCache;
  SetCondenseReversible(True);
  Got := AttachReversibleStashFooter('abc', 'abc');
  AssertEqStr(Got, 'abc', 'identical input/output returned verbatim');
end;

procedure TestSavingBelowFloor;
var
  Orig, Cond, Got: string;
begin
  ClearOutputCache;
  SetCondenseReversible(True);
  Orig := MakeOriginal(500);
  Cond := MakeOriginal(400);   { 100 bytes saved, < default 256 floor }
  Got  := AttachReversibleStashFooter(Orig, Cond);
  AssertEqStr(Got, Cond, 'sub-floor saving does not trigger stash');
end;

procedure TestRealSavingStashesAndAppendsFooter;
var
  Orig, Cond, Got, Tail, Handle, Fetched, FetchErr: string;
  HandlePos, EndQuote: Integer;
begin
  ClearOutputCache;
  SetCondenseReversible(True);
  Orig := MakeOriginal(5000);
  Cond := '[summary] 5000 bytes of x';
  Got  := AttachReversibleStashFooter(Orig, Cond);
  AssertTrue(Length(Got) > Length(Cond), 'output longer than condensed only');
  AssertTrue(Pos(Cond, Got) = 1, 'condensed body comes first');
  Tail := Copy(Got, Length(Cond) + 1, MaxInt);
  AssertTrue(Pos('handle="', Tail) > 0, 'footer names a handle');
  AssertTrue(Pos('tool_output_get', Tail) > 0,
             'footer points at tool_output_get');

  { Extract handle and dereference. }
  HandlePos := Pos('handle="', Tail);
  EndQuote  := Pos('"', Copy(Tail, HandlePos + Length('handle="'), MaxInt));
  AssertTrue(EndQuote > 0, 'handle quote closes');
  Handle    := Copy(Tail, HandlePos + Length('handle="'), EndQuote - 1);
  AssertTrue(FetchStashedOutput(Handle, 0, -1, Fetched, FetchErr),
             'handle dereferences');
  AssertEqStr(Fetched, Orig, 'dereferenced bytes equal the ORIGINAL');
end;

procedure TestDisableSwitch;
var
  Orig, Cond, Got: string;
begin
  ClearOutputCache;
  Orig := MakeOriginal(5000);
  Cond := '[summary]';
  SetCondenseReversible(False);
  try
    Got := AttachReversibleStashFooter(Orig, Cond);
    AssertEqStr(Got, Cond, 'disabled: no footer attached');
  finally
    SetCondenseReversible(True);
  end;
end;

procedure TestCountersAccumulate;
var
  Before, After: Int64;
  BeforeBytes, AfterBytes: Int64;
begin
  ClearOutputCache;
  SetCondenseReversible(True);
  Before := CondenseStashCount;
  BeforeBytes := CondenseStashBytesPreserved;
  AttachReversibleStashFooter(MakeOriginal(5000), '[a]');
  AttachReversibleStashFooter(MakeOriginal(3000), '[b]');
  After := CondenseStashCount;
  AfterBytes := CondenseStashBytesPreserved;
  AssertTrue(After - Before = 2, 'two new stashes counted');
  AssertTrue(AfterBytes - BeforeBytes = 8000,
             'cumulative original bytes counted');
end;

procedure TestMinSavingsParamOverride;
var
  Got: string;
begin
  ClearOutputCache;
  SetCondenseReversible(True);
  { Caller passing MinSavingsBytes=1 lets a tiny saving stash. }
  Got := AttachReversibleStashFooter(MakeOriginal(300), MakeOriginal(290), 1);
  AssertTrue(Pos('handle="', Got) > 0,
             'explicit MinSavingsBytes override honoured');
end;

begin
  TestNoOpWhenNoSavings;
  WriteLn('  ok: identical input/output returned verbatim');
  TestSavingBelowFloor;
  WriteLn('  ok: sub-floor saving does not stash');
  TestRealSavingStashesAndAppendsFooter;
  WriteLn('  ok: real saving stashes original + dereferenceable handle');
  TestDisableSwitch;
  WriteLn('  ok: enable switch honoured');
  TestCountersAccumulate;
  WriteLn('  ok: counters accumulate');
  TestMinSavingsParamOverride;
  WriteLn('  ok: MinSavingsBytes override');
  WriteLn('PASS');
end.
