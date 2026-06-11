(*
  PasClaw.Checkpoints - opt-in file-edit rollback. Snapshots files before
  fs_write / fs_edit_hashline mutates them; `/undo N` rewinds N turns
  by restoring the contents that were captured at the START of each
  turn touched.

  Why opt-in (off by default):

    - "Could be heavy". A turn that fs_writes a 5 MB generated file
      copies that 5 MB into workspace/checkpoints/<session>/turn-NNN/.
      Over a long session that adds up. The bundle defaults to keeping
      the last 32 turns; that's a sensible bound but only relative
      to the operator's intent. They tell us via `pasclaw onboard`.

    - Filesystem cost outside the workspace. The fs tools accept any
      path the sandbox allows; we snapshot regardless. An operator
      who flips checkpoints on and then asks the model to edit a 2 GB
      logfile pays for it.

  Storage layout (per session):

      $PASCLAW_HOME/workspace/checkpoints/<session-id>/
        turn-0001/
          manifest.json   { "turn":1, "ts":"…", "files":[{path,blob,size}] }
          blobs/0000.bin
          blobs/0001.bin
        turn-0002/
          …

  Per turn, every snapshotted file is copied verbatim under blobs/NNNN.bin
  with the original path recorded in manifest.json. The "blob index"
  decouples on-disk names from path strings, so weird input -- absolute
  paths, paths with `..`, paths with whitespace -- needs no escaping.

  `/undo N` then iterates turn-(CurrentTurn) downto turn-(CurrentTurn-N+1),
  restoring each file recorded in those manifests. Files the model
  CREATED during the rewound turns (no pre-write snapshot exists) are
  LEFT IN PLACE -- v1 is conservative; deleting model-created files is
  a follow-up. Restoration order within a single turn doesn't matter
  (each file is restored to its pre-turn state once); across turns we
  iterate newest -> oldest so the EARLIEST captured state wins for any
  file that was edited across multiple of the rewound turns. That's
  symmetric with how SnapshotBeforeWrite itself is idempotent within
  one turn -- the first capture is the keeper.

  Thread-safety: SnapshotBeforeWrite is called from RunToolLoop's
  per-tool dispatch, which can be parallel for tcReadOnly batches.
  fs_write and fs_edit_hashline are tcMutating so they don't race in
  practice -- but the unit uses a critical section anyway so a future
  batching change (or an embedder calling from a thread) stays safe.
*)
unit PasClaw.Checkpoints;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes, SyncObjs;

const
  DefaultKeepLastTurns = 32;

type
  TCheckpointConfig = record
    Enabled:   Boolean;
    { Per-session subdirectory key. Empty disables checkpoints
      even when Enabled is True -- the agent loop has no session
      to scope snapshots to. }
    SessionId: string;
    { Root directory under which <SessionId>/turn-NNNN/ lives.
      Typically $PASCLAW_HOME/workspace/checkpoints. The unit
      creates the dir as needed. }
    Root:      string;
    { Maximum turn dirs to retain per session. Older dirs auto-
      pruned at BeginTurn time so long sessions don't grow the
      disk indefinitely. 0 means "default" (32). }
    KeepLast:  Integer;
  end;

  TRestoredFile = record
    Path:        string;
    BlobIdx:     Integer;
    SnappedTurn: Integer;
    BytesRestored: Int64;
  end;
  TRestoredFileArray = array of TRestoredFile;

procedure InitCheckpoints(const Cfg: TCheckpointConfig);
procedure BeginTurn;
procedure SnapshotBeforeWrite(const Path: string);

function CheckpointsEnabled: Boolean;
function CurrentTurnNumber: Integer;
function CountSnapshottedTurns(out OldestTurn, NewestTurn: Integer): Integer;

function UndoTurns(N: Integer; out Restored: TRestoredFileArray;
                   out ErrMsg: string): Boolean;

implementation

uses
  DateUtils,
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Logger;

procedure ListSubdirs(const Dir: string; List: TStringList);
{ Local helper: enumerate the immediate subdirectory names of Dir
  into List. Skips `.` and `..`. PasClaw.Utils doesn't export a
  cross-compiler dirwalker, so the unit keeps its own. }
var
  SR: TSearchRec;
begin
  if (Dir = '') or (not DirectoryExists(Dir)) then Exit;
  if FindFirst(JoinPath(Dir, '*'), faAnyFile or faDirectory, SR) = 0 then
  try
    repeat
      if ((SR.Attr and faDirectory) <> 0) and
         (SR.Name <> '.') and (SR.Name <> '..') then
        List.Add(SR.Name);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure RemoveTreeRecursive(const Path: string);
{ Best-effort `rm -rf`. Used to prune old turn dirs. Errors get
  swallowed; the next prune pass picks up the dangling entries. }
var
  SR: TSearchRec;
  Child: string;
begin
  if (Path = '') or (not DirectoryExists(Path)) then
  begin
    if FileExists(Path) then DeleteFile(Path);
    Exit;
  end;
  if FindFirst(JoinPath(Path, '*'), faAnyFile or faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      Child := JoinPath(Path, SR.Name);
      if (SR.Attr and faDirectory) <> 0 then
        RemoveTreeRecursive(Child)
      else
        DeleteFile(Child);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(Path);
end;

var
  GLock:    TCriticalSection;
  GEnabled: Boolean;
  GSession: string;
  GRoot:    string;
  GKeep:    Integer;
  GTurn:    Integer;
  { Files already snapshotted in the CURRENT turn; the second + nth
    snapshot of the same path within one turn is a no-op so we keep
    the earliest captured state. Cleared at BeginTurn. }
  GTurnPaths: TStringList;
  GTurnBlobCount: Integer;
  { In-memory record of the current turn's manifest entries. Each
    SnapshotBeforeWrite appends one TStringList row formatted as
    "blob|size|path" and rewrites the manifest.json atomically.
    Holding the array in memory avoids parsing manifest.json every
    snapshot -- the previous load-modify-save dance through the JSON
    unit was leaking references on the second invocation per turn. }
  GTurnEntries: TStringList;
  GTurnTimestamp: string;

function SessionDir: string;
begin
  if (GRoot = '') or (GSession = '') then
    Exit('');
  Result := JoinPath(GRoot, GSession);
end;

function TurnDir(TurnNumber: Integer): string;
begin
  if SessionDir = '' then Exit('');
  Result := JoinPath(SessionDir, Format('turn-%4.4d', [TurnNumber]));
end;

function CurrentTurnDir: string;
begin
  Result := TurnDir(GTurn);
end;

function CurrentBlobsDir: string;
begin
  if CurrentTurnDir = '' then Exit('');
  Result := JoinPath(CurrentTurnDir, 'blobs');
end;

function CurrentManifestPath: string;
begin
  if CurrentTurnDir = '' then Exit('');
  Result := JoinPath(CurrentTurnDir, 'manifest.json');
end;

procedure PruneOldTurns;
{ Walk SessionDir; drop the OLDEST turn-NNNN entries until the count
  fits the budget. Called at the TOP of each BeginTurn, so the cap is
  KeepLast - 1 -- the new turn about to start will add one more dir,
  and we want the post-snapshot total to be at most KeepLast.

  Best-effort: removal failures get logged but don't abort the next
  snapshot. The next BeginTurn picks up any dangling entry. }
var
  Dir, Path: string;
  Names: TStringList;
  Budget, i: Integer;
begin
  Dir := SessionDir;
  if Dir = '' then Exit;
  if not DirectoryExists(Dir) then Exit;
  Budget := GKeep - 1;
  if Budget < 0 then Budget := 0;
  Names := TStringList.Create;
  try
    ListSubdirs(Dir, Names);
    Names.Sorted := True;
    { Filter to turn-* entries only. }
    for i := Names.Count - 1 downto 0 do
      if (Length(Names[i]) < 5) or (Copy(Names[i], 1, 5) <> 'turn-') then
        Names.Delete(i);
    while Names.Count > Budget do
    begin
      Path := JoinPath(Dir, Names[0]);
      try
        RemoveTreeRecursive(Path);
      except
        on E: Exception do
          LogWarn('checkpoints: prune %s failed: %s', [Path, E.Message]);
      end;
      Names.Delete(0);
    end;
  finally
    Names.Free;
  end;
end;

procedure ResetState;
begin
  GEnabled := False;
  GSession := '';
  GRoot    := '';
  GKeep    := DefaultKeepLastTurns;
  GTurn    := 0;
  if GTurnPaths <> nil then GTurnPaths.Clear;
  if GTurnEntries <> nil then GTurnEntries.Clear;
  GTurnBlobCount := 0;
  GTurnTimestamp := '';
end;

procedure InitCheckpoints(const Cfg: TCheckpointConfig);
{ Resume the per-session counter from on-disk state. PasClaw can restart
  between turns -- the next BeginTurn must land on turn (MaxExisting + 1)
  so we don't clobber the previous run's snapshots. Codex P2 on PR #221:
  the old design relied on the caller passing a TurnNumber sourced from
  TSession.Meta.Stats.Turns, which only increments when stats collection
  is enabled; with stats off (the default) every TUI turn called
  BeginTurn(1) and rewrote turn-0001's manifest. Fixed by making the
  module own its own monotonically-increasing counter, independent of
  the optional session-stats field. }
var
  Names: TStringList;
  i, T, MaxT: Integer;
begin
  GLock.Acquire;
  try
    ResetState;
    if (not Cfg.Enabled) or (Cfg.SessionId = '') or (Cfg.Root = '') then
    begin
      LogDebug('checkpoints: disabled (enabled=%s session=%s root=%s)',
               [BoolToStr(Cfg.Enabled, True), Cfg.SessionId, Cfg.Root]);
      Exit;
    end;
    GEnabled := True;
    GSession := Cfg.SessionId;
    GRoot    := Cfg.Root;
    if Cfg.KeepLast > 0 then GKeep := Cfg.KeepLast
    else GKeep := DefaultKeepLastTurns;
    EnsureDir(SessionDir);
    { Scan for the highest existing turn-NNNN under SessionDir so
      BeginTurn picks up where the previous run left off. }
    MaxT := 0;
    Names := TStringList.Create;
    try
      ListSubdirs(SessionDir, Names);
      for i := 0 to Names.Count - 1 do
      begin
        if (Length(Names[i]) < 9) or (Copy(Names[i], 1, 5) <> 'turn-') then Continue;
        T := StrToIntDef(Copy(Names[i], 6, MaxInt), -1);
        if T > MaxT then MaxT := T;
      end;
    finally
      Names.Free;
    end;
    GTurn := MaxT;  { BeginTurn will Inc this to MaxT+1 before snapshotting }
    LogDebug('checkpoints: enabled session=%s root=%s keep=%d resume_turn=%d',
             [GSession, GRoot, GKeep, GTurn]);
  finally
    GLock.Release;
  end;
end;

function CheckpointsEnabled: Boolean;
begin
  GLock.Acquire;
  try
    Result := GEnabled;
  finally
    GLock.Release;
  end;
end;

function CurrentTurnNumber: Integer;
begin
  GLock.Acquire;
  try
    Result := GTurn;
  finally
    GLock.Release;
  end;
end;

procedure BeginTurn;
{ Advance the per-session turn counter and reset per-turn state.
  Codex P2 on PR #221: caller no longer passes a TurnNumber sourced
  from TSession.Meta.Stats.Turns (which depends on stats_collection_
  enabled). The module owns its own counter, initialised from
  on-disk state at InitCheckpoints, so checkpoints turn numbering
  is independent of the optional stats subsystem AND survives
  pasclaw restarts cleanly. }
begin
  GLock.Acquire;
  try
    if not GEnabled then Exit;
    Inc(GTurn);
    GTurnBlobCount := 0;
    GTurnPaths.Clear;
    GTurnEntries.Clear;
    GTurnTimestamp := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
    { The turn dir + blob dir lazy-create on first snapshot; we
      don't want to litter empty dirs for turns that don't touch
      the FS. Prune happens here so the operator sees the dir size
      drop right at the start of each new turn. }
    PruneOldTurns;
  finally
    GLock.Release;
  end;
end;

function ReadFileBytes(const Path: string; out Bytes: TBytes): Boolean;
var
  F: TFileStream;
begin
  Result := False;
  if not FileExists(Path) then Exit;
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Bytes, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Bytes[0], F.Size);
    Result := True;
  finally
    F.Free;
  end;
end;

procedure WriteFileBytes(const Path: string; const Bytes: TBytes);
var
  F: TFileStream;
begin
  EnsureDir(ExtractFilePath(Path));
  F := TFileStream.Create(Path, fmCreate);
  try
    if Length(Bytes) > 0 then
      F.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    F.Free;
  end;
end;

procedure WriteCurrentManifest;
{ Render GTurnEntries as a fresh JSON object and overwrite
  manifest.json. Atomic on POSIX (rename is atomic via WriteFileText
  if it uses tmp+rename; SysUtils' default doesn't, but a partially-
  written manifest is recoverable -- the snapshot blob it would have
  named is already on disk from before the manifest write). }
var
  Root, Entry: TJsonObject;
  Arr: TJsonArray;
  i, Pipe1, Pipe2, Size: Integer;
  Line, BlobName, PathStr, SizeStr: string;
begin
  EnsureDir(CurrentTurnDir);
  Root := TJsonObject.Create;
  try
    Root.PutInt('turn', GTurn);
    Root.PutStr('ts',   GTurnTimestamp);
    Arr := TJsonArray.Create;
    try
      for i := 0 to GTurnEntries.Count - 1 do
      begin
        Line := GTurnEntries[i];
        Pipe1 := Pos('|', Line);
        if Pipe1 <= 0 then Continue;
        BlobName := Copy(Line, 1, Pipe1 - 1);
        Pipe2 := Pos('|', Line, Pipe1 + 1);
        if Pipe2 <= 0 then Continue;
        SizeStr := Copy(Line, Pipe1 + 1, Pipe2 - Pipe1 - 1);
        PathStr := Copy(Line, Pipe2 + 1, MaxInt);
        Size := StrToIntDef(SizeStr, 0);
        Entry := TJsonObject.Create;
        Entry.PutStr('path', PathStr);
        Entry.PutStr('blob', BlobName);
        Entry.PutInt('size', Size);
        Arr.AddObject(Entry);
      end;
      Root.PutArray('files', Arr);
    except
      Arr.Free;
      raise;
    end;
    WriteFileText(CurrentManifestPath, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure SnapshotBeforeWrite(const Path: string);
var
  AbsPath: string;
  Bytes: TBytes;
  BlobName, BlobPath: string;
begin
  GLock.Acquire;
  try
    if (not GEnabled) or (GTurn <= 0) then Exit;
    AbsPath := ExpandFileName(Path);
    if GTurnPaths.IndexOf(AbsPath) >= 0 then
    begin
      { Already snapshotted earlier in this turn -- keep the
        earliest state. fs_edit_hashline that touches the same file
        twice in one turn must roll back to BEFORE the first edit,
        not BEFORE the second. }
      Exit;
    end;
    if not ReadFileBytes(AbsPath, Bytes) then
    begin
      { Truly-new file (didn't exist before the model wrote it).
        Record nothing -- on /undo we leave model-created files in
        place. The operator can rm them; the alternative ("delete
        any file created during a rewound turn") risks data loss
        if the model also re-wrote an unrelated file as part of
        the same turn. }
      GTurnPaths.Add(AbsPath);  { still mark so a later edit in
                                  this same turn doesn't try to
                                  snapshot a file the model just
                                  created -- the original-state
                                  "no file" is already implied. }
      Exit;
    end;
    EnsureDir(CurrentBlobsDir);
    BlobName := Format('%4.4d.bin', [GTurnBlobCount]);
    BlobPath := JoinPath(CurrentBlobsDir, BlobName);
    WriteFileBytes(BlobPath, Bytes);
    GTurnEntries.Add(BlobName + '|' + IntToStr(Length(Bytes)) + '|' + AbsPath);
    WriteCurrentManifest;

    GTurnPaths.Add(AbsPath);
    Inc(GTurnBlobCount);
    LogDebug('checkpoints: turn=%d snap %s (%d bytes -> %s)',
             [GTurn, AbsPath, Length(Bytes), BlobName]);
  finally
    GLock.Release;
  end;
end;

function CountSnapshottedTurns(out OldestTurn, NewestTurn: Integer): Integer;
var
  Dir, NameStr: string;
  Names: TStringList;
  i, T, Lo, Hi: Integer;
begin
  Result    := 0;
  OldestTurn := 0;
  NewestTurn := 0;
  GLock.Acquire;
  try
    Dir := SessionDir;
    if (not GEnabled) or (Dir = '') or (not DirectoryExists(Dir)) then Exit;
    Names := TStringList.Create;
    try
      ListSubdirs(Dir, Names);
      Lo := MaxInt;
      Hi := -1;
      for i := 0 to Names.Count - 1 do
      begin
        NameStr := Names[i];
        if (Length(NameStr) < 9) or (Copy(NameStr, 1, 5) <> 'turn-') then Continue;
        T := StrToIntDef(Copy(NameStr, 6, MaxInt), -1);
        if T < 0 then Continue;
        Inc(Result);
        if T < Lo then Lo := T;
        if T > Hi then Hi := T;
      end;
      if Result > 0 then
      begin
        OldestTurn := Lo;
        NewestTurn := Hi;
      end;
    finally
      Names.Free;
    end;
  finally
    GLock.Release;
  end;
end;

function UndoTurns(N: Integer; out Restored: TRestoredFileArray;
                   out ErrMsg: string): Boolean;
var
  Dir, ManifestPath, S, BlobName, BlobPath, EntryPath: string;
  RawSize: Int64;
  Names: TStringList;
  TurnNumbers: array of Integer;
  i, j, T, Hit, RawCount: Integer;
  ManRoot: TJsonObject;
  Files: TJsonArray;
  FileObj: TJsonObject;
  AlreadyRestored: TStringList;
  Bytes: TBytes;
  RestoredEntry: TRestoredFile;
begin
  Result := False;
  SetLength(Restored, 0);
  ErrMsg := '';
  GLock.Acquire;
  try
    if not GEnabled then
    begin
      ErrMsg := 'checkpoints not enabled for this session';
      Exit;
    end;
    if N <= 0 then
    begin
      ErrMsg := 'argument must be a positive turn count';
      Exit;
    end;
    Dir := SessionDir;
    if (Dir = '') or (not DirectoryExists(Dir)) or (GTurn <= 0) then
    begin
      ErrMsg := 'no snapshots recorded for this session yet';
      Exit;
    end;
    Names := TStringList.Create;
    try
      ListSubdirs(Dir, Names);
      SetLength(TurnNumbers, 0);
      for i := 0 to Names.Count - 1 do
      begin
        if (Length(Names[i]) < 9) or (Copy(Names[i], 1, 5) <> 'turn-') then Continue;
        T := StrToIntDef(Copy(Names[i], 6, MaxInt), -1);
        if T < 0 then Continue;
        SetLength(TurnNumbers, Length(TurnNumbers) + 1);
        TurnNumbers[High(TurnNumbers)] := T;
      end;
    finally
      Names.Free;
    end;
    if Length(TurnNumbers) = 0 then
    begin
      { GTurn > 0 (checked above) so the session HAS begun turns, but
        none of them touched files yet. /undo is a friendly no-op
        here rather than an error -- the operator sees "0 files
        restored" and moves on. The hard-fail case (no BeginTurn
        ever called) was caught above. }
      Result := True;
      Exit;
    end;
    { Sort ascending so we walk OLDEST -> newest. Then for any file
      that appears across multiple of the rewound turns, the manifest
      from the EARLIEST turn in the range wins (because the
      AlreadyRestored set blocks the later turns). That gives
      "restore everything to the state at the start of the oldest
      rewound turn" -- exactly what `/undo N` from turn HEAD means.

      Then we trim TurnNumbers down to just the last N entries -- the
      newest N turns. Trim before walking, not before sort, so the
      trim picks up the actually-newest turns regardless of
      filesystem enumeration order. }
    for i := 0 to High(TurnNumbers) - 1 do
      for j := i + 1 to High(TurnNumbers) do
        if TurnNumbers[j] < TurnNumbers[i] then
        begin
          T := TurnNumbers[i];
          TurnNumbers[i] := TurnNumbers[j];
          TurnNumbers[j] := T;
        end;
    if N > Length(TurnNumbers) then N := Length(TurnNumbers);
    if Length(TurnNumbers) > N then
    begin
      { Drop the OLDEST (Length-N) entries; we only walk the newest N. }
      for i := 0 to N - 1 do
        TurnNumbers[i] := TurnNumbers[Length(TurnNumbers) - N + i];
      SetLength(TurnNumbers, N);
    end;
    AlreadyRestored := TStringList.Create;
    try
      { TurnNumbers now contains exactly the last N turns in
        ascending order. Walk oldest -> newest. }
      for Hit := 0 to High(TurnNumbers) do
      begin
        T := TurnNumbers[Hit];
        ManifestPath := JoinPath(JoinPath(Dir, Format('turn-%4.4d', [T])),
                                  'manifest.json');
        if not FileExists(ManifestPath) then Continue;
        S := ReadFileText(ManifestPath);
        ManRoot := TJsonObject.Parse(S);
        if ManRoot = nil then Continue;
        try
          Files := ManRoot.ChildArray('files');
          if Files = nil then Continue;
          try
            for i := 0 to Files.Count - 1 do
            begin
              FileObj := Files.ItemObject(i);
              if FileObj = nil then Continue;
              try
                EntryPath := FileObj.GetStr('path', '');
                BlobName  := FileObj.GetStr('blob', '');
                RawSize   := FileObj.GetInt('size', 0);
                if (EntryPath = '') or (BlobName = '') then Continue;
                if AlreadyRestored.IndexOf(EntryPath) >= 0 then Continue;
                BlobPath := JoinPath(
                  JoinPath(JoinPath(Dir, Format('turn-%4.4d', [T])), 'blobs'),
                  BlobName);
                if not ReadFileBytes(BlobPath, Bytes) then Continue;
                try
                  WriteFileBytes(EntryPath, Bytes);
                except
                  on E: Exception do
                  begin
                    LogWarn('checkpoints: restore %s failed: %s',
                            [EntryPath, E.Message]);
                    Continue;
                  end;
                end;
                AlreadyRestored.Add(EntryPath);
                RestoredEntry.Path          := EntryPath;
                RawCount := Length(Bytes);
                RestoredEntry.BytesRestored := RawCount;
                if RawSize = 0 then ;  { silence unused warning -- kept
                                         for future schema use }
                RestoredEntry.BlobIdx     := i;
                RestoredEntry.SnappedTurn := T;
                SetLength(Restored, Length(Restored) + 1);
                Restored[High(Restored)] := RestoredEntry;
              finally
                FileObj.Free;
              end;
            end;
          finally
            Files.Free;
          end;
        finally
          ManRoot.Free;
        end;
      end;
    finally
      AlreadyRestored.Free;
    end;
    Result := True;
  finally
    GLock.Release;
  end;
end;

initialization
  GLock := TCriticalSection.Create;
  GTurnPaths := TStringList.Create;
  GTurnPaths.CaseSensitive := True;
  GTurnEntries := TStringList.Create;
  ResetState;

finalization
  GLock.Free;
  GTurnPaths.Free;
  GTurnEntries.Free;

end.
