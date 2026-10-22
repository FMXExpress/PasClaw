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
    - and the half that cheapness must not buy: a drain racing a push
      that already holds the lock WAITS for it, instead of reporting an
      empty queue and letting the turn run on without the steer

  PASCLAW_HOME must point at a scratch dir (the Makefile target does).
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF FPC}{$IFDEF UNIX}cthreads,{$ENDIF}{$ENDIF}
  SysUtils, Classes, SyncObjs, DateUtils,
  PasClaw.Agent.Steering;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;

const
  HOLD_MS = 400;

(* A push caught in its own window.

   PushSteering acquires the lock and THEN creates the queue file, so
   there is a moment when the lock directory exists and the file does
   not. That moment is the whole point of this fixture: the drain's fast
   path must not read it as "nothing queued".

   Reproduced with real artifacts rather than fabricated ones -- the
   message is written by PushSteering itself and only moved aside, so
   the test never encodes its own idea of the queue's line format and
   cannot drift from it.

   The lock path mirrors LockPath's convention (<queue>.lock), which is
   private to the unit. If that ever changes this fixture stops holding
   anything and the assertions below fail loudly, which is the outcome
   to want from a coupling like this. *)
type
  TMidPush = class(TThread)
  private
    FPath: string;
    FHeld: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
    procedure WaitUntilHolding;
  end;

constructor TMidPush.Create(const APath: string);
begin
  FPath := APath;
  FHeld := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;

destructor TMidPush.Destroy;
begin
  FHeld.Free;
  inherited Destroy;
end;

procedure TMidPush.WaitUntilHolding;
begin
  FHeld.WaitFor(10000);
end;

procedure TMidPush.Execute;
begin
  { Hold the lock with the queue file moved aside: a push that has
    locked but not yet written. }
  CreateDir(FPath + '.lock');
  FHeld.SetEvent;
  Sleep(HOLD_MS);
  { ...and now complete it: the file lands, then the lock is released. }
  RenameFile(FPath + '.held', FPath);
  RemoveDir(FPath + '.lock');
end;

var
  T0: TDateTime;
  Ms: Int64;
  Msgs: TSteeringMessageArray;
  Path: string;
  Pusher: TMidPush;
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

  (* ---- the fast path must not outrun a writer (Codex P2 on #617) ----

     A real message, moved aside so the file is absent, with the lock
     held: exactly the state PushSteering passes through. The drain has
     to wait for that push and come back with the message. Reading the
     missing file as an empty queue is what let a mid-turn steer slip
     past its own turn -- and if that iteration's response carried no
     tool calls, past the whole run. *)
  Path := SteeringPath('mid-push-key');
  AssertTrue(Path <> '', 'the key resolves to a path');
  AssertTrue(PushSteering('mid-push-key', 'stop and summarise'),
             'a real message is queued');
  AssertTrue(FileExists(Path), 'and it is on disk');
  AssertTrue(RenameFile(Path, Path + '.held'),
             'moved aside: the file a mid-push has not written yet');
  AssertTrue(not FileExists(Path), 'so the queue file is absent');

  Pusher := TMidPush.Create(Path);
  try
    Pusher.WaitUntilHolding;
    AssertTrue(DirectoryExists(Path + '.lock'), 'the writer holds the lock');

    T0 := Now;
    Msgs := DrainSteering('mid-push-key', 4);
    Ms := MilliSecondsBetween(Now, T0);

    AssertTrue(Length(Msgs) = 1,
      Format('the drain WAITED for the in-progress push and got its ' +
             'message (got %d message(s) after %d ms) -- an unlocked ' +
             '"no file means empty" check returns instantly here and ' +
             'the steer misses its turn', [Length(Msgs), Ms]));
    AssertTrue(Pos('stop and summarise', Msgs[0].Text) > 0,
               'and it is the message that was queued');
    AssertTrue(Ms >= HOLD_MS - 100,
      Format('it waited for the writer rather than winning a race ' +
             '(took %d ms, writer held %d ms)', [Ms, HOLD_MS]));
    WriteLn(Format('  ok: drain waited %d ms for a push holding the lock', [Ms]));
  finally
    Pusher.WaitFor;
    Pusher.Free;
  end;

  WriteLn('PASS');
end.
