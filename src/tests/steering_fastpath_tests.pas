program steering_fastpath_tests;
(*
  The steering drain must be cheap when nothing is queued: the tool loop
  calls it at every iteration top. Before this test, a home with no
  steering directory made every drain spin a 2,000 ms lock timeout
  (bench/ragbench/OVERHEAD.md).

    - drain on a never-steered key returns empty in well under 200 ms
    - push then drain returns the message; the following drain is empty
      and fast again
    - the lock can be taken when the steering dir did not exist beforehand
      (AcquireLock creates the parent), so a real push/drain works from a
      fresh home

  PASCLAW_HOME must point at a scratch dir (the Makefile target does).
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils, DateUtils,
  PasClaw.Agent.Steering;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;

var
  T0: TDateTime;
  Ms: Int64;
  Msgs: TSteeringMessageArray;
begin
  T0 := Now;
  Msgs := DrainSteering('never-steered-key', 4);
  Ms := MilliSecondsBetween(Now, T0);
  AssertTrue(Length(Msgs) = 0, 'nothing queued');
  AssertTrue(Ms < 200, Format('empty drain is fast (took %d ms; was 2000)', [Ms]));
  WriteLn(Format('  ok: empty drain on a fresh home took %d ms', [Ms]));

  PushSteering('never-steered-key', 'turn left');
  T0 := Now;
  Msgs := DrainSteering('never-steered-key', 4);
  Ms := MilliSecondsBetween(Now, T0);
  AssertTrue(Length(Msgs) = 1, 'one message drained');
  AssertTrue(Pos('turn left', Msgs[0].Text) > 0, 'the message text');
  AssertTrue(Ms < 500, Format('drain with a message is fast (took %d ms)', [Ms]));

  T0 := Now;
  Msgs := DrainSteering('never-steered-key', 4);
  Ms := MilliSecondsBetween(Now, T0);
  AssertTrue(Length(Msgs) = 0, 'queue empty again');
  AssertTrue(Ms < 200, Format('empty drain fast again (took %d ms)', [Ms]));
  WriteLn('  ok: push / drain / empty drain');
  WriteLn('PASS');
end.
