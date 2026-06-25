program checkpoints_tests;
(*
  Covers PasClaw.Checkpoints -- the opt-in file-edit rollback that
  fs_write and fs_edit_hashline hook into so a TUI /undo can rewind
  N turns by restoring the pre-edit bytes.

  Strategy: no model, no agent loop. Drive InitCheckpoints +
  BeginTurn + SnapshotBeforeWrite + UndoTurns directly against
  scratch files in a temp dir, then assert the file contents and
  the on-disk manifest.

  Pinned contracts:
    - Disabled state is a no-op (no checkpoint dir, no snapshot)
    - SnapshotBeforeWrite captures the file's pre-edit bytes
    - Idempotency: snapshotting the same path twice in one turn
      keeps the EARLIEST capture (so a turn that edits a file
      twice still rolls back to the very first state)
    - UndoTurns(1) restores the file to its state at the START
      of the current turn
    - UndoTurns(N) walks N turns; the EARLIEST capture across
      those N wins for any file edited multiple times
    - UndoTurns rejects N=0, N<0, and returns an explanatory
      ErrMsg when the session has no recorded turns
    - Files the model CREATED inside a rewound turn (no
      pre-snapshot exists) are left in place by /undo -- v1's
      conservative semantic
    - KeepLast auto-prunes older turn dirs at BeginTurn time
    - CountSnapshottedTurns reports the live turn range
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.Checkpoints;

var
  GTmpRoot: string;
  GWorkDir: string;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertFalse(Cond: Boolean; const Msg: string);
begin
  if Cond then Fail_(Msg);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Copy(Got, 1, 200) + '", want "' +
          Copy(Want, 1, 200) + '")');
end;

procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin
  if Got <> Want then
    Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want]));
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) <= 0 then
    Fail_(Msg + ' (needle "' + Needle + '" missing)');
end;

procedure SetupSession(const SessionId: string; KeepLast: Integer);
var
  Cfg: TCheckpointConfig;
begin
  Cfg.Enabled   := True;
  Cfg.SessionId := SessionId;
  Cfg.Root      := JoinPath(GTmpRoot, 'cp');
  Cfg.KeepLast  := KeepLast;
  InitCheckpoints(Cfg);
end;

procedure SetupDisabled;
var
  Cfg: TCheckpointConfig;
begin
  Cfg.Enabled   := False;
  Cfg.SessionId := 'irrelevant';
  Cfg.Root      := JoinPath(GTmpRoot, 'cp');
  Cfg.KeepLast  := 0;
  InitCheckpoints(Cfg);
end;

function ScratchPath(const Name: string): string;
begin
  Result := JoinPath(GWorkDir, Name);
end;

procedure WriteScratch(const Path, Content: string);
begin
  EnsureDir(ExtractFilePath(Path));
  WriteFileText(Path, Content);
end;

procedure TestDisabledIsNoOp;
var
  P: string;
begin
  SetupDisabled;
  BeginTurn;
  P := ScratchPath('disabled.txt');
  WriteScratch(P, 'original');
  SnapshotBeforeWrite(P);
  WriteFileText(P, 'modified');
  AssertFalse(CheckpointsEnabled, 'disabled state reports disabled');
  AssertFalse(DirectoryExists(JoinPath(GTmpRoot, 'cp')),
              'no cp dir created when disabled');
end;

procedure TestUndoSingleTurn;
var
  P: string;
  Restored: TRestoredFileArray;
  Err: string;
begin
  SetupSession('undo1', 0);
  P := ScratchPath('a.txt');
  WriteScratch(P, 'original');

  BeginTurn;
  SnapshotBeforeWrite(P);
  WriteFileText(P, 'modified by model');

  AssertTrue(UndoTurns(1, Restored, Err), 'undo 1 succeeded');
  AssertEqStr(Err, '', 'no error');
  AssertEqInt(Length(Restored), 1, 'one file restored');
  AssertEqStr(ReadFileText(P), 'original', 'file rolled back');
end;

procedure TestIdempotentSnapshotKeepsEarliestState;
var
  P: string;
  Restored: TRestoredFileArray;
  Err: string;
begin
  SetupSession('idem', 0);
  P := ScratchPath('b.txt');
  WriteScratch(P, 'state-A');

  BeginTurn;
  SnapshotBeforeWrite(P);              { captures state-A }
  WriteFileText(P, 'state-B');
  SnapshotBeforeWrite(P);              { no-op: keep state-A }
  WriteFileText(P, 'state-C');

  AssertTrue(UndoTurns(1, Restored, Err),
             'undo rolls back to state-A');
  AssertEqStr(ReadFileText(P), 'state-A',
              'earliest captured state wins inside a turn');
end;

procedure TestUndoAcrossTurns;
var
  P: string;
  Restored: TRestoredFileArray;
  Err: string;
begin
  SetupSession('across', 0);
  P := ScratchPath('c.txt');
  WriteScratch(P, 'gen-1');

  BeginTurn;
  SnapshotBeforeWrite(P);
  WriteFileText(P, 'gen-2');

  BeginTurn;
  SnapshotBeforeWrite(P);
  WriteFileText(P, 'gen-3');

  BeginTurn;
  SnapshotBeforeWrite(P);
  WriteFileText(P, 'gen-4');

  AssertTrue(UndoTurns(2, Restored, Err), 'undo 2 OK');
  AssertEqStr(ReadFileText(P), 'gen-2',
              'undo 2 turns -> restore start-of-turn-2 (= gen-2)');
end;

procedure TestUndoBeyondHistoryClampsToWhatExists;
var
  P: string;
  Restored: TRestoredFileArray;
  Err: string;
begin
  SetupSession('clamp', 0);
  P := ScratchPath('d.txt');
  WriteScratch(P, 'v0');

  BeginTurn;
  SnapshotBeforeWrite(P);
  WriteFileText(P, 'v1');

  AssertTrue(UndoTurns(50, Restored, Err),
             'undo of 50 against 1 turn still succeeds (clamps)');
  AssertEqStr(ReadFileText(P), 'v0',
              'rolled all the way back to v0');
end;

procedure TestUndoRejectsZeroAndNegative;
var
  Restored: TRestoredFileArray;
  Err: string;
begin
  SetupSession('reject', 0);
  BeginTurn;
  AssertFalse(UndoTurns(0, Restored, Err),
              'undo 0 rejected');
  AssertContains(Err, 'positive', 'clear error message');
  AssertFalse(UndoTurns(-3, Restored, Err),
              'undo -3 rejected');
end;

procedure TestUndoOnEmptySessionReportsClearly;
var
  Restored: TRestoredFileArray;
  Err: string;
begin
  SetupSession('empty', 0);
  AssertFalse(UndoTurns(1, Restored, Err),
              'no turns yet -> undo fails');
  AssertContains(Err, 'no snapshots', 'message names the cause');
end;

procedure TestUndoWhenDisabledFails;
var
  Restored: TRestoredFileArray;
  Err: string;
begin
  SetupDisabled;
  AssertFalse(UndoTurns(1, Restored, Err),
              'disabled checkpoints -> undo fails');
  AssertContains(Err, 'not enabled', 'message names the cause');
end;

procedure TestModelCreatedFilesAreLeftInPlace;
var
  P: string;
  Restored: TRestoredFileArray;
  Err: string;
begin
  SetupSession('newfile', 0);
  P := ScratchPath('e-new.txt');
  if FileExists(P) then DeleteFile(P);

  BeginTurn;
  SnapshotBeforeWrite(P);          { file does not exist -- no blob written }
  WriteFileText(P, 'created by model');

  AssertTrue(UndoTurns(1, Restored, Err), 'undo runs without error');
  { File still exists -- v1 leaves model-created files in place. }
  AssertTrue(FileExists(P), 'newly-created file survives undo');
  AssertEqStr(ReadFileText(P), 'created by model',
              'contents unchanged for model-created file');
end;

procedure TestKeepLastPrunesOlderTurns;
var
  Cfg: TCheckpointConfig;
  P: string;
  i: Integer;
  OldestTurn, NewestTurn: Integer;
begin
  Cfg.Enabled   := True;
  Cfg.SessionId := 'prune';
  Cfg.Root      := JoinPath(GTmpRoot, 'cp');
  Cfg.KeepLast  := 3;
  InitCheckpoints(Cfg);

  P := ScratchPath('f.txt');
  WriteScratch(P, 'seed');
  for i := 1 to 6 do
  begin
    BeginTurn;
    SnapshotBeforeWrite(P);
    WriteFileText(P, 'gen-' + IntToStr(i));
  end;

  AssertEqInt(CountSnapshottedTurns(OldestTurn, NewestTurn), 3,
              'only last 3 turn dirs remain after auto-prune');
  AssertEqInt(OldestTurn, 4, 'oldest is turn 4');
  AssertEqInt(NewestTurn, 6, 'newest is turn 6');
end;

procedure TestInitResumesFromExistingTurnDirs;
(* Codex P2 on PR #221: the old design pulled the turn number from
   TSession.Meta.Stats.Turns, which only increments when
   stats_collection_enabled is True. With stats off (the default),
   every TUI turn called BeginTurn(1) and overwrote turn-0001's
   manifest. Fix: the module owns its own counter and resumes from
   the highest existing turn-NNNN dir at InitCheckpoints. This test
   pins that resume: drop a turn-0007 dir on disk, re-Init, and
   verify the next BeginTurn lands on turn-0008. *)
var
  Cfg: TCheckpointConfig;
  P: string;
  Restored: TRestoredFileArray;
  Err: string;
  Old, NewestT: Integer;
begin
  SetupSession('resume', 0);
  P := ScratchPath('h.txt');
  WriteScratch(P, 'baseline');

  BeginTurn;   { turn-0001 }
  SnapshotBeforeWrite(P);
  WriteFileText(P, 'edited-1');

  { Pretend we just relaunched pasclaw: re-Init the same session.
    The module should rediscover turn-0001 and resume from there. }
  Cfg.Enabled   := True;
  Cfg.SessionId := 'resume';
  Cfg.Root      := JoinPath(GTmpRoot, 'cp');
  Cfg.KeepLast  := 0;
  InitCheckpoints(Cfg);

  AssertEqInt(CountSnapshottedTurns(Old, NewestT), 1, 'one turn on disk');
  AssertEqInt(NewestT, 1, 'newest is 1');

  BeginTurn;   { should land on turn-0002, NOT turn-0001 again }
  SnapshotBeforeWrite(P);
  WriteFileText(P, 'edited-2');

  AssertEqInt(CountSnapshottedTurns(Old, NewestT), 2,
              'second BeginTurn after resume created a NEW turn dir');
  AssertEqInt(NewestT, 2, 'newest is 2 (resumed correctly)');

  AssertTrue(UndoTurns(1, Restored, Err), 'undo 1');
  AssertEqStr(ReadFileText(P), 'edited-1',
              'undo 1 rolls back to state at start of turn-0002');
end;

procedure TestMultipleFilesInOneTurn;
var
  P1, P2: string;
  Restored: TRestoredFileArray;
  Err: string;
begin
  SetupSession('multi', 0);
  P1 := ScratchPath('g1.txt');
  P2 := ScratchPath('g2.txt');
  WriteScratch(P1, 'one-original');
  WriteScratch(P2, 'two-original');

  BeginTurn;
  SnapshotBeforeWrite(P1);
  SnapshotBeforeWrite(P2);
  WriteFileText(P1, 'one-modified');
  WriteFileText(P2, 'two-modified');

  AssertTrue(UndoTurns(1, Restored, Err), 'undo OK');
  AssertEqInt(Length(Restored), 2, 'two files restored');
  AssertEqStr(ReadFileText(P1), 'one-original', 'p1 rolled back');
  AssertEqStr(ReadFileText(P2), 'two-original', 'p2 rolled back');
end;

{ ===================================================================
  Concurrency: per-session contexts (no global turn serialization).

  Each worker thread selects its OWN session via InitCheckpoints (the
  current context is thread-local), so two threads on two sessions
  must run their turns concurrently without corrupting each other.
  A thread on a SHARED session brackets each turn with
  Acquire/ReleaseCheckpointTurn and must serialize cleanly -- every
  turn lands, none are torn.
  =================================================================== }
type
  TCpWorker = class(TThread)
  private
    FSession: string;
    FFile:    string;
    FTurns:   Integer;
    FBracket: Boolean;   { hold the per-session turn lock across each turn }
  protected
    procedure Execute; override;
  public
    Failed: Boolean;
    FailMsg: string;
    constructor Create(const ASession, AFile: string;
                       ATurns: Integer; ABracket: Boolean);
  end;

constructor TCpWorker.Create(const ASession, AFile: string;
                             ATurns: Integer; ABracket: Boolean);
begin
  FSession := ASession;
  FFile    := AFile;
  FTurns   := ATurns;
  FBracket := ABracket;
  Failed   := False;
  inherited Create(False);   { run immediately }
end;

procedure TCpWorker.Execute;
var
  Cfg: TCheckpointConfig;
  i: Integer;
begin
  try
    { Select THIS thread's session. The current context is a threadvar,
      so each worker resolves independently. }
    Cfg.Enabled   := True;
    Cfg.SessionId := FSession;
    Cfg.Root      := JoinPath(GTmpRoot, 'cp');
    Cfg.KeepLast  := 0;
    InitCheckpoints(Cfg);
    for i := 1 to FTurns do
    begin
      if FBracket then AcquireCheckpointTurn;
      try
        BeginTurn;
        SnapshotBeforeWrite(FFile);
        WriteFileText(FFile, Format('%s-turn-%d', [FSession, i]));
      finally
        if FBracket then ReleaseCheckpointTurn;
      end;
      Sleep(1);   { encourage interleaving with the sibling thread }
    end;
  except
    on E: Exception do
    begin
      Failed  := True;
      FailMsg := E.ClassName + ': ' + E.Message;
    end;
  end;
end;

procedure TestConcurrentDistinctSessionsDoNotCrossContaminate;
{ Two sessions, two threads, turns running at the same time. Each
  session's history must stay its own -- undo restores that session's
  baseline, never the sibling's bytes. }
var
  WA, WB: TCpWorker;
  PA, PB: string;
  Restored: TRestoredFileArray;
  Err: string;
  Old, NewestT: Integer;
  Cfg: TCheckpointConfig;
begin
  PA := ScratchPath('conc-a.txt');
  PB := ScratchPath('conc-b.txt');
  WriteScratch(PA, 'base-a');
  WriteScratch(PB, 'base-b');

  WA := TCpWorker.Create('conc-a', PA, 6, False);
  WB := TCpWorker.Create('conc-b', PB, 6, False);
  WA.WaitFor;
  WB.WaitFor;
  AssertFalse(WA.Failed, 'worker A errored: ' + WA.FailMsg);
  AssertFalse(WB.Failed, 'worker B errored: ' + WB.FailMsg);
  WA.Free;
  WB.Free;

  { Re-select each session on THIS thread and verify independent history. }
  Cfg.Enabled := True; Cfg.Root := JoinPath(GTmpRoot, 'cp'); Cfg.KeepLast := 0;

  Cfg.SessionId := 'conc-a'; InitCheckpoints(Cfg);
  AssertEqInt(CountSnapshottedTurns(Old, NewestT), 6, 'session A has 6 turns');
  AssertTrue(UndoTurns(6, Restored, Err), 'undo A: ' + Err);
  AssertEqStr(ReadFileText(PA), 'base-a', 'session A restored to its own baseline');

  Cfg.SessionId := 'conc-b'; InitCheckpoints(Cfg);
  AssertEqInt(CountSnapshottedTurns(Old, NewestT), 6, 'session B has 6 turns');
  AssertTrue(UndoTurns(6, Restored, Err), 'undo B: ' + Err);
  AssertEqStr(ReadFileText(PB), 'base-b', 'session B restored to its own baseline');
end;

procedure TestConcurrentSameSessionSerializesCleanly;
{ Two threads pounding the SAME session, each bracketing its turns
  with the per-session turn lock. No turn may be torn: the final turn
  count is exactly the sum, and the counter is monotonic. }
var
  WA, WB: TCpWorker;
  P: string;
  Old, NewestT, Cnt: Integer;
  Cfg: TCheckpointConfig;
begin
  P := ScratchPath('conc-shared.txt');
  WriteScratch(P, 'shared-base');

  WA := TCpWorker.Create('conc-shared', P, 8, True);
  WB := TCpWorker.Create('conc-shared', P, 8, True);
  WA.WaitFor;
  WB.WaitFor;
  AssertFalse(WA.Failed, 'shared worker A errored: ' + WA.FailMsg);
  AssertFalse(WB.Failed, 'shared worker B errored: ' + WB.FailMsg);
  WA.Free;
  WB.Free;

  Cfg.Enabled := True; Cfg.Root := JoinPath(GTmpRoot, 'cp');
  Cfg.KeepLast := 0; Cfg.SessionId := 'conc-shared';
  InitCheckpoints(Cfg);
  { 16 turns total, each snapshots the file once -> 16 distinct turn
    records, newest == 16. A torn turn (two BeginTurns racing without
    the lock) would drop or double-count, breaking both. }
  Cnt := CountSnapshottedTurns(Old, NewestT);
  AssertEqInt(Cnt, 16, 'all 16 serialized turns recorded');
  AssertEqInt(NewestT, 16, 'turn counter is monotonic to 16');
end;

procedure CleanupTmp;
begin
  if (GTmpRoot <> '') and DirectoryExists(GTmpRoot) then
  begin
    { Best-effort recursive rm via simple shellout -- POSIX only. }
    {$IFDEF UNIX}
    ExecuteProcess('/bin/sh', ['-c', 'rm -rf "' + GTmpRoot + '"']);
    {$ENDIF}
  end;
end;

begin
  Randomize;  { without this, Random returns the same sequence every
                run -- and a leftover tmp dir from a prior run breaks
                the "disabled is no-op" test that checks the cp dir
                doesn't exist. }
  GTmpRoot := JoinPath(GetTempDir, 'pasclaw-cp-test-' + IntToStr(Random(MaxInt)));
  { Defensive: nuke any leftover dir with this exact name (extremely
    rare collision under a seeded Random; cheap insurance). }
  {$IFDEF UNIX}
  ExecuteProcess('/bin/sh', ['-c', 'rm -rf "' + GTmpRoot + '"']);
  {$ENDIF}
  GWorkDir := JoinPath(GTmpRoot, 'work');
  EnsureDir(GWorkDir);
  try
    TestDisabledIsNoOp;                       WriteLn('  ok: disabled is no-op');
    TestUndoSingleTurn;                       WriteLn('  ok: undo single turn');
    TestIdempotentSnapshotKeepsEarliestState; WriteLn('  ok: idempotent snapshot keeps earliest');
    TestUndoAcrossTurns;                      WriteLn('  ok: undo across turns');
    TestUndoBeyondHistoryClampsToWhatExists;  WriteLn('  ok: undo beyond history clamps');
    TestUndoRejectsZeroAndNegative;           WriteLn('  ok: undo rejects non-positive N');
    TestUndoOnEmptySessionReportsClearly;     WriteLn('  ok: undo on empty session');
    TestUndoWhenDisabledFails;                WriteLn('  ok: undo when disabled fails');
    TestModelCreatedFilesAreLeftInPlace;      WriteLn('  ok: model-created files left in place');
    TestKeepLastPrunesOlderTurns;             WriteLn('  ok: KeepLast prunes older turns');
    TestInitResumesFromExistingTurnDirs;      WriteLn('  ok: Init resumes turn counter from disk');
    TestMultipleFilesInOneTurn;               WriteLn('  ok: multiple files in one turn');
    TestConcurrentDistinctSessionsDoNotCrossContaminate;
                                              WriteLn('  ok: concurrent distinct sessions stay isolated');
    TestConcurrentSameSessionSerializesCleanly;
                                              WriteLn('  ok: concurrent same session serializes cleanly');
    WriteLn('PASS');
  finally
    CleanupTmp;
  end;
end.
