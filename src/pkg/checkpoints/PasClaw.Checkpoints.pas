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

type
  TCheckpointBackend = (
    cbDisabled,   { Checkpoints feature off -- BeginTurn / Snapshot are
                    no-ops; UndoTurns returns False with a message. }
    cbLegacy,     (* Per-turn directory of raw blobs + manifest.json.
                    Original PR #221 storage. Fallback when the zpaq
                    archive can't be initialised at runtime. (The vendored
                    port now compiles under Delphi too, so this is no longer
                    the default there.) *)
    cbZpaq        { One streaming archive per session (archive.zpaq) +
                    JSON journal (index.json) tracking turn -> archive
                    entries + a redo stack. Compresses snapshots and
                    enables /redo. }
  );

procedure InitCheckpoints(const Cfg: TCheckpointConfig);
procedure BeginTurn;
procedure SnapshotBeforeWrite(const Path: string);

function CheckpointsEnabled: Boolean;
function CheckpointsBackend: TCheckpointBackend;
function CurrentTurnNumber: Integer;
function CountSnapshottedTurns(out OldestTurn, NewestTurn: Integer): Integer;

function UndoTurns(N: Integer; out Restored: TRestoredFileArray;
                   out ErrMsg: string): Boolean;

{ /redo support. Only available under cbZpaq -- legacy blob backend
  has no per-undo capture point to roll forward from.  Returns False
  with ErrMsg = 'redo not supported by this backend' under cbLegacy /
  cbDisabled. CanRedo is True when the redo stack has at least one
  entry; the UI uses it to gray out the /redo command. }
function RedoTurns(N: Integer; out Restored: TRestoredFileArray;
                   out ErrMsg: string): Boolean;
function CanRedo: Boolean;

{ JSON snapshot of checkpoint state for the gateway web UI: backend / enabled /
  current_turn / can_redo / oldest / newest / count, plus a per-turn list of the
  files each turn changed. Reads both the zpaq index.json and the legacy
  per-turn manifest.json. Returns an enabled:false skeleton when off. }
function CheckpointsStateJSON: string;

implementation

uses
  DateUtils,
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.Checkpoints.Zpaq;

{ Forward decls: the zpaq backend block uses these I/O helpers, which
  the legacy backend defines further down. Forward-declaring keeps
  both blocks readable without reshuffling the file. }
function ReadFileBytes(const Path: string; out Bytes: TBytes): Boolean; forward;
procedure WriteFileBytes(const Path: string; const Bytes: TBytes); forward;

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
  GBackend: TCheckpointBackend;
  GSession: string;
  GRoot:    string;
  GKeep:    Integer;
  GTurn:    Integer;
  { Files already snapshotted in the CURRENT turn; the second + nth
    snapshot of the same path within one turn is a no-op so we keep
    the earliest captured state. Cleared at BeginTurn. Shared between
    backends. }
  GTurnPaths: TStringList;

  { ---- Legacy (cbLegacy) backend state ---- }
  GTurnBlobCount: Integer;
  { In-memory record of the current turn's manifest entries. Each
    SnapshotBeforeWrite appends one TStringList row formatted as
    "blob|size|path" and rewrites the manifest.json atomically. }
  GTurnEntries: TStringList;
  GTurnTimestamp: string;

  { ---- Zpaq (cbZpaq) backend state ---- }
  { Cached archive entry count -- bumped on each ZpaqAppendBytes so we
    can tell new entries apart without re-listing the archive. }
  GZpaqArchiveCount: Integer;
  { Set after UndoTurns pushes a redo bundle; the next SnapshotBefore-
    Write that adds an archive entry clears the redo stack (standard
    editor semantic: new edits invalidate redo history).  /redo itself
    doesn't trigger SnapshotBeforeWrite, so the stack survives a
    sequence of undo / redo / undo / redo. }
  GZpaqRedoDirty: Boolean;

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
  GBackend := cbDisabled;
  GSession := '';
  GRoot    := '';
  GKeep    := DefaultKeepLastTurns;
  GTurn    := 0;
  if GTurnPaths <> nil then GTurnPaths.Clear;
  if GTurnEntries <> nil then GTurnEntries.Clear;
  GTurnBlobCount := 0;
  GTurnTimestamp := '';
  GZpaqArchiveCount := 0;
  GZpaqRedoDirty := False;
end;

(* ===================================================================
   cbZpaq backend
   ===================================================================

   Layout (per session):

     <root>/<session>/archive.zpaq    one streaming archive, append-
                                       only. Each SnapshotBeforeWrite
                                       appends one segment.
     <root>/<session>/index.json      PasClaw-side journal:
                                       { "version": 1,
                                         "current_turn": N,
                                         "archive_count": M,
                                         "turns": [
                                           { "turn": K,
                                             "ts": "...",
                                             "entries": [
                                               { "path": "<abs>",
                                                 "archive_idx": I,
                                                 "was_created": bool }
                                             ] } ],
                                         "redo_stack": [
                                           { "turn_label": L,
                                             "entries": [
                                               { "path": "<abs>",
                                                 "archive_idx": I } ] } ] }

   archive_idx = -1 with was_created = True means the file did not
   exist before the turn that touches it (model created it).  The
   legacy carve-out -- leave model-created files in place on undo --
   is preserved; deleting them properly needs a post-write snapshot
   path and is deferred to a follow-up.

   Redo stack semantics: UndoTurns appends a fresh archive segment
   per touched path BEFORE restoring, then pushes the bundle onto
   the stack.  Any subsequent SnapshotBeforeWrite that adds a real
   new segment clears the stack (GZpaqRedoDirty).  /redo extracts
   the bundle's segments without going through SnapshotBeforeWrite,
   so a sequence of /undo, /redo, /undo, /redo cycles cleanly. *)

function ZpaqArchivePath: string;
begin
  Result := JoinPath(SessionDir, 'archive.zpaq');
end;

function ZpaqIndexPath: string;
begin
  Result := JoinPath(SessionDir, 'index.json');
end;

function ZpaqEnsureArray(Owner: TJsonObject; const Key: string): TJsonArray;
{ Return Owner's `Key` array, creating an empty one if missing. The
  result is owned by Owner (caller does NOT free). Wraps the
  PutArray-then-refetch dance: PutArray transfers ownership and nils
  the local var, so a "PutArray(...); .AddObject(...)" sequence
  would NPE.  EnsureArray hands back a live reference safe to mutate. }
var
  Fresh: TJsonArray;
begin
  Result := Owner.ChildArray(Key);
  if Result = nil then
  begin
    Fresh := TJsonArray.Create;
    Owner.PutArray(Key, Fresh);          { ownership transfers; Fresh := nil }
    Result := Owner.ChildArray(Key);     { re-fetch live reference }
  end;
end;

function ZpaqLoadIndex: TJsonObject;
{ Read index.json into a fresh TJsonObject. Returns a default v1
  skeleton (current_turn=0, empty turns / redo_stack) when the file
  is missing or unparseable. Caller owns the result. }
var
  S: string;
  Parsed: TJsonObject;
begin
  Result := TJsonObject.Create;
  if FileExists(ZpaqIndexPath) then
  begin
    try
      S := ReadFileText(ZpaqIndexPath);
      Parsed := TJsonObject.Parse(S);
      if Parsed <> nil then
      begin
        Result.Free;
        Exit(Parsed);
      end;
    except
      on E: Exception do
        LogWarn('checkpoints: index.json unreadable (%s) -- starting fresh',
                [E.Message]);
    end;
  end;
  Result.PutInt('version',       1);
  Result.PutInt('current_turn',  0);
  Result.PutInt('archive_count', 0);
  { Use EnsureArray for the side-effect: creates empty array,
    Result keeps ownership.  Returning the reference is unused here. }
  ZpaqEnsureArray(Result, 'turns');
  ZpaqEnsureArray(Result, 'redo_stack');
end;

procedure ZpaqSaveIndex(Root: TJsonObject);
{ Atomic write: tmp + rename so a crash mid-flush leaves either the
  old index or the new one, never a partial. The archive append that
  preceded this save is committed independently -- on crash, the
  archive may have one trailing segment the index never recorded;
  list-based scans recover by ignoring entries past archive_count. }
var
  Path, Tmp: string;
begin
  Path := ZpaqIndexPath;
  Tmp  := Path + '.tmp';
  WriteFileText(Tmp, Root.ToJSON);
  { RenameFile is atomic on POSIX; on Windows DeleteFile+Rename is
    the standard sequence. SysUtils' RenameFile wraps both. }
  if FileExists(Path) then DeleteFile(Path);
  if not RenameFile(Tmp, Path) then
  begin
    LogWarn('checkpoints: atomic rename %s -> %s failed; falling back to direct write',
            [Tmp, Path]);
    WriteFileText(Path, Root.ToJSON);
    DeleteFile(Tmp);
  end;
end;

function ZpaqFindOrAddTurn(Index: TJsonObject; Turn: Integer): TJsonObject;
{ Return the existing turn record for Turn, or append a fresh one to
  the turns array. Caller does NOT own the result -- it's owned by
  the turns array, freed when Index is freed. }
var
  Turns: TJsonArray;
  Obj, Fresh: TJsonObject;
  i, NewIdx:  Integer;
begin
  Turns := ZpaqEnsureArray(Index, 'turns');
  for i := 0 to Turns.Count - 1 do
  begin
    Obj := Turns.ItemObject(i);
    if (Obj <> nil) and (Obj.GetInt('turn', -1) = Turn) then
      Exit(Obj);
  end;
  Fresh := TJsonObject.Create;
  Fresh.PutInt('turn', Turn);
  Fresh.PutStr('ts',   FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now));
  ZpaqEnsureArray(Fresh, 'entries');
  NewIdx := Turns.Count;
  Turns.AddObject(Fresh);              { ownership transferred; Fresh := nil }
  Result := Turns.ItemObject(NewIdx);  { live reference }
end;

procedure ZpaqClearRedoStack(Index: TJsonObject);
{ Drop every bundle from the redo stack in place. Cheaper and safer
  than swapping in a fresh array (no ownership transfer). }
var
  Stack: TJsonArray;
  i:     Integer;
begin
  Stack := Index.ChildArray('redo_stack');
  if (Stack = nil) or (Stack.Count = 0) then Exit;
  LogDebug('checkpoints: redo stack cleared (%d bundles invalidated)',
           [Stack.Count]);
  for i := Stack.Count - 1 downto 0 do
    Stack.Delete(i);
end;

procedure ZpaqInitFromDisk;
{ Called from InitCheckpoints after the backend has been selected and
  the session dir created. Loads the JSON journal to recover GTurn +
  GZpaqArchiveCount across pasclaw restarts. }
var
  Index: TJsonObject;
begin
  Index := ZpaqLoadIndex;
  try
    GTurn             := Index.GetInt('current_turn',  0);
    GZpaqArchiveCount := Index.GetInt('archive_count', 0);
    GZpaqRedoDirty    := False;
  finally
    Index.Free;
  end;
end;

procedure ZpaqPruneOldTurns;
{ Drop the oldest turn records from index.json until len(turns) fits
  the (GKeep - 1) budget -- mirrors the legacy backend's PruneOldTurns
  so CountSnapshottedTurns behaves the same way under both backends.

  Unlike the legacy backend, we don't (yet) compact the archive: the
  pruned segments stay on disk, just unreferenced from the journal.
  That's fine for v1; running zpaq journaling-format compaction here
  is a follow-up once the vendor exposes it. }
var
  Index: TJsonObject;
  Turns: TJsonArray;
  Budget: Integer;
begin
  Budget := GKeep - 1;
  if Budget < 0 then Budget := 0;

  Index := ZpaqLoadIndex;
  try
    Turns := Index.ChildArray('turns');
    if (Turns = nil) or (Turns.Count <= Budget) then Exit;
    while Turns.Count > Budget do
      Turns.Delete(0);
    ZpaqSaveIndex(Index);
  finally
    Index.Free;
  end;
end;

procedure ZpaqBeginTurn;
begin
  Inc(GTurn);
  GTurnPaths.Clear;
  GTurnTimestamp := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
  { Prune happens here so the operator sees the count drop at the
    start of each new turn, matching legacy timing. Skipped when
    KeepLast is unset (GKeep = 0). }
  if GKeep > 0 then
    ZpaqPruneOldTurns;
  { Note: redo stack is NOT cleared here -- a turn that produces no
    snapshots (model just thinks / chats) shouldn't invalidate the
    redo history. Clearing happens in ZpaqSnapshotBeforeWrite when an
    actual archive segment is appended. }
end;

procedure ZpaqSnapshotBeforeWrite(const AbsPath: string);
var
  Bytes: TBytes;
  Index: TJsonObject;
  TurnObj, EntryObj: TJsonObject;
  Entries: TJsonArray;
  Err: string;
  NewIdx: Integer;
  WasCreated: Boolean;
begin
  if GTurnPaths.IndexOf(AbsPath) >= 0 then Exit;
  GTurnPaths.Add(AbsPath);

  WasCreated := not FileExists(AbsPath);
  NewIdx     := -1;
  if not WasCreated then
  begin
    if not ReadFileBytes(AbsPath, Bytes) then
    begin
      LogWarn('checkpoints: read %s failed -- snapshot skipped', [AbsPath]);
      Exit;
    end;
    if not ZpaqAppendBytes(ZpaqArchivePath, Bytes, AbsPath,
                           ZpaqDefaultMethod, Err) then
    begin
      LogWarn('checkpoints: zpaq append %s failed (%s) -- snapshot skipped',
              [AbsPath, Err]);
      Exit;
    end;
    NewIdx := GZpaqArchiveCount;
    Inc(GZpaqArchiveCount);
  end;

  Index := ZpaqLoadIndex;
  try
    Index.PutInt('current_turn',  GTurn);
    Index.PutInt('archive_count', GZpaqArchiveCount);
    if GZpaqRedoDirty then
    begin
      ZpaqClearRedoStack(Index);
      GZpaqRedoDirty := False;
    end;
    TurnObj := ZpaqFindOrAddTurn(Index, GTurn);
    Entries := ZpaqEnsureArray(TurnObj, 'entries');
    EntryObj := TJsonObject.Create;
    EntryObj.PutStr('path',         AbsPath);
    EntryObj.PutInt('archive_idx',  NewIdx);
    EntryObj.PutBool('was_created', WasCreated);
    Entries.AddObject(EntryObj);  { ownership transferred; EntryObj := nil }
    ZpaqSaveIndex(Index);
  finally
    Index.Free;
  end;

  if WasCreated then
    LogDebug('checkpoints: turn=%d created %s (no snapshot bytes)',
             [GTurn, AbsPath])
  else
    LogDebug('checkpoints: turn=%d snap %s (%d bytes -> archive idx %d)',
             [GTurn, AbsPath, Length(Bytes), NewIdx]);
end;

function ZpaqUndoTurns(N: Integer;
                       out Restored: TRestoredFileArray;
                       out ErrMsg: string): Boolean;
var
  Index: TJsonObject;
  Turns, Entries, Stack, BundleEntries: TJsonArray;
  TurnObj, EntryObj, BundleObj, BundleEntry: TJsonObject;
  i, j, T, WindowLo, WindowHi, Idx: Integer;
  Path: string;
  TouchedPaths: TStringList;
  TouchedIdx: TStringList;   { parallel: stores archive_idx for restore }
  TouchedCreated: TStringList; { parallel: '1' if was_created else '0' }
  Bytes: TBytes;
  Err: string;
  ArchiveIdx: Integer;
  RestoredEntry: TRestoredFile;
begin
  Result := False;
  SetLength(Restored, 0);
  ErrMsg := '';
  if N <= 0 then begin ErrMsg := 'argument must be a positive turn count'; Exit; end;

  Index := ZpaqLoadIndex;
  TouchedPaths := nil;
  TouchedIdx := nil;
  TouchedCreated := nil;
  try
    Turns := Index.ChildArray('turns');
    if (Turns = nil) or (Turns.Count = 0) then
    begin
      ErrMsg := 'no snapshots recorded for this session yet';
      Exit;
    end;

    if N > GTurn then N := GTurn;
    WindowHi := GTurn;
    WindowLo := GTurn - N + 1;
    if WindowLo < 1 then WindowLo := 1;

    { Pass 1: collect unique paths in the window. For each path, find
      its EARLIEST snapshot inside the window (oldest-wins per file,
      matching the legacy semantic: "restore to state at start of
      oldest rewound turn"). }
    TouchedPaths   := TStringList.Create;
    TouchedPaths.CaseSensitive := True;
    TouchedIdx     := TStringList.Create;
    TouchedCreated := TStringList.Create;
    for i := 0 to Turns.Count - 1 do
    begin
      TurnObj := Turns.ItemObject(i);
      if TurnObj = nil then Continue;
      T := TurnObj.GetInt('turn', -1);
      if (T < WindowLo) or (T > WindowHi) then Continue;
      Entries := TurnObj.ChildArray('entries');
      if Entries = nil then Continue;
      for j := 0 to Entries.Count - 1 do
      begin
        EntryObj := Entries.ItemObject(j);
        if EntryObj = nil then Continue;
        Path := EntryObj.GetStr('path', '');
        if Path = '' then Continue;
        if TouchedPaths.IndexOf(Path) >= 0 then Continue;
        TouchedPaths.Add(Path);
        TouchedIdx.Add(IntToStr(EntryObj.GetInt('archive_idx', -1)));
        if EntryObj.GetBool('was_created', False) then
          TouchedCreated.Add('1')
        else
          TouchedCreated.Add('0');
      end;
    end;

    if TouchedPaths.Count = 0 then
    begin
      Result := True;   { friendly no-op, same as legacy }
      Exit;
    end;

    { Pass 2: snapshot CURRENT bytes of each touched path into the
      archive -- that's the redo bundle. Paths that no longer exist
      on disk are skipped (model deleted them post-edit); the legacy
      "leave created files in place" carve-out propagates: /undo
      doesn't undo deletions either. Fix in a follow-up.

      Push the bundle onto the stack first (as a freshly-allocated
      TJsonObject), then re-fetch the live reference and fill in
      entries. Doing it in this order avoids holding a dangling
      pointer after AddObject's ownership transfer. }
    Stack := ZpaqEnsureArray(Index, 'redo_stack');
    BundleObj := TJsonObject.Create;
    BundleObj.PutInt('turn_label', WindowLo);   { the turn we rewound TO }
    ZpaqEnsureArray(BundleObj, 'entries');
    Stack.AddObject(BundleObj);                 { ownership transferred }
    BundleObj := Stack.ItemObject(Stack.Count - 1);
    BundleEntries := BundleObj.ChildArray('entries');

    for i := 0 to TouchedPaths.Count - 1 do
    begin
      Path := TouchedPaths[i];
      if FileExists(Path) then
      begin
        if not ReadFileBytes(Path, Bytes) then
        begin
          LogWarn('checkpoints: undo: read %s failed -- redo bundle entry skipped',
                  [Path]);
          Continue;
        end;
        if not ZpaqAppendBytes(ZpaqArchivePath, Bytes, Path,
                               ZpaqDefaultMethod, Err) then
        begin
          LogWarn('checkpoints: undo: zpaq append %s failed (%s)',
                  [Path, Err]);
          Continue;
        end;
        BundleEntry := TJsonObject.Create;
        BundleEntry.PutStr('path',        Path);
        BundleEntry.PutInt('archive_idx', GZpaqArchiveCount);
        BundleEntries.AddObject(BundleEntry);
        Inc(GZpaqArchiveCount);
      end;
    end;

    { Pass 3: restore. For each touched path, write the pre-window
      bytes back if archive_idx >= 0; if was_created (idx = -1), leave
      the file in place (carve-out). }
    for i := 0 to TouchedPaths.Count - 1 do
    begin
      Path := TouchedPaths[i];
      ArchiveIdx := StrToIntDef(TouchedIdx[i], -1);
      if TouchedCreated[i] = '1' then
      begin
        LogDebug('checkpoints: undo: %s was created -- left in place', [Path]);
        Continue;
      end;
      if ArchiveIdx < 0 then Continue;
      if not ZpaqExtractByIndex(ZpaqArchivePath, ArchiveIdx, Bytes, Err) then
      begin
        LogWarn('checkpoints: undo: extract %s (idx=%d) failed: %s',
                [Path, ArchiveIdx, Err]);
        Continue;
      end;
      try
        WriteFileBytes(Path, Bytes);
      except
        on E: Exception do
        begin
          LogWarn('checkpoints: undo: write %s failed: %s', [Path, E.Message]);
          Continue;
        end;
      end;
      RestoredEntry.Path          := Path;
      RestoredEntry.BlobIdx       := ArchiveIdx;
      RestoredEntry.SnappedTurn   := WindowLo;
      RestoredEntry.BytesRestored := Length(Bytes);
      SetLength(Restored, Length(Restored) + 1);
      Restored[High(Restored)] := RestoredEntry;
    end;

    Index.PutInt('archive_count', GZpaqArchiveCount);
    ZpaqSaveIndex(Index);
    GZpaqRedoDirty := True;
    Result := True;
  finally
    TouchedPaths.Free;
    TouchedIdx.Free;
    TouchedCreated.Free;
    Index.Free;
  end;
end;

function ZpaqRedoTurns(N: Integer;
                       out Restored: TRestoredFileArray;
                       out ErrMsg: string): Boolean;
var
  Index: TJsonObject;
  Stack, BundleEntries: TJsonArray;
  BundleObj, EntryObj: TJsonObject;
  i, j, Pops: Integer;
  Path: string;
  ArchiveIdx: Integer;
  Bytes: TBytes;
  Err: string;
  RestoredEntry: TRestoredFile;
begin
  Result := False;
  SetLength(Restored, 0);
  ErrMsg := '';
  if N <= 0 then begin ErrMsg := 'argument must be a positive turn count'; Exit; end;

  Index := ZpaqLoadIndex;
  try
    Stack := Index.ChildArray('redo_stack');
    if (Stack = nil) or (Stack.Count = 0) then
    begin
      ErrMsg := 'nothing to redo -- redo stack is empty';
      Exit;
    end;
    Pops := N;
    if Pops > Stack.Count then Pops := Stack.Count;

    { Pop from the top (newest bundle first). Each bundle's entries
      overwrite the files; later bundles win where paths overlap --
      same shape as the undo restoration in reverse. }
    for i := 0 to Pops - 1 do
    begin
      BundleObj := Stack.ItemObject(Stack.Count - 1);
      if BundleObj = nil then Break;
      BundleEntries := BundleObj.ChildArray('entries');
      if BundleEntries <> nil then
      begin
        for j := 0 to BundleEntries.Count - 1 do
        begin
          EntryObj := BundleEntries.ItemObject(j);
          if EntryObj = nil then Continue;
          Path := EntryObj.GetStr('path', '');
          ArchiveIdx := EntryObj.GetInt('archive_idx', -1);
          if (Path = '') or (ArchiveIdx < 0) then Continue;
          if not ZpaqExtractByIndex(ZpaqArchivePath, ArchiveIdx,
                                    Bytes, Err) then
          begin
            LogWarn('checkpoints: redo: extract %s (idx=%d) failed: %s',
                    [Path, ArchiveIdx, Err]);
            Continue;
          end;
          try
            WriteFileBytes(Path, Bytes);
          except
            on E: Exception do
            begin
              LogWarn('checkpoints: redo: write %s failed: %s',
                      [Path, E.Message]);
              Continue;
            end;
          end;
          RestoredEntry.Path          := Path;
          RestoredEntry.BlobIdx       := ArchiveIdx;
          RestoredEntry.SnappedTurn   := BundleObj.GetInt('turn_label', 0);
          RestoredEntry.BytesRestored := Length(Bytes);
          SetLength(Restored, Length(Restored) + 1);
          Restored[High(Restored)] := RestoredEntry;
        end;
      end;
      Stack.Delete(Stack.Count - 1);
    end;

    ZpaqSaveIndex(Index);
    Result := True;
  finally
    Index.Free;
  end;
end;

function ZpaqCanRedo: Boolean;
var
  Index: TJsonObject;
  Stack: TJsonArray;
begin
  Result := False;
  if GBackend <> cbZpaq then Exit;
  Index := ZpaqLoadIndex;
  try
    Stack := Index.ChildArray('redo_stack');
    Result := (Stack <> nil) and (Stack.Count > 0);
  finally
    Index.Free;
  end;
end;

function ZpaqCountSnapshottedTurns(out OldestTurn,
                                   NewestTurn: Integer): Integer;
var
  Index: TJsonObject;
  Turns: TJsonArray;
  TurnObj: TJsonObject;
  i, T, Lo, Hi: Integer;
begin
  Result     := 0;
  OldestTurn := 0;
  NewestTurn := 0;
  Index := ZpaqLoadIndex;
  try
    Turns := Index.ChildArray('turns');
    if Turns = nil then Exit;
    Lo := MaxInt;
    Hi := -1;
    for i := 0 to Turns.Count - 1 do
    begin
      TurnObj := Turns.ItemObject(i);
      if TurnObj = nil then Continue;
      T := TurnObj.GetInt('turn', -1);
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
    Index.Free;
  end;
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

    { Pick backend. zpaq wins when the vendor is on disk; otherwise
      we fall back to the legacy turn-NNNN blob tree so checkpoints
      keep working under Delphi / fresh-clones-without-`make get-zpaq`.
      The on-disk shapes are disjoint (archive.zpaq vs turn-NNNN/),
      so detecting which one this session ran under previously is
      cheap: if archive.zpaq exists we resume zpaq mode, else if
      turn-NNNN dirs exist we resume legacy, else pick zpaq when
      available. }
    if FileExists(ZpaqArchivePath) and ZpaqAvailable then
      GBackend := cbZpaq
    else
    begin
      MaxT := 0;
      Names := TStringList.Create;
      try
        ListSubdirs(SessionDir, Names);
        for i := 0 to Names.Count - 1 do
          if (Length(Names[i]) >= 9) and (Copy(Names[i], 1, 5) = 'turn-') then
          begin
            T := StrToIntDef(Copy(Names[i], 6, MaxInt), -1);
            if T > MaxT then MaxT := T;
          end;
      finally
        Names.Free;
      end;
      if MaxT > 0 then
        GBackend := cbLegacy
      else if ZpaqAvailable then
        GBackend := cbZpaq
      else
        GBackend := cbLegacy;
    end;

    case GBackend of
      cbZpaq:
        begin
          ZpaqInitFromDisk;
          LogDebug('checkpoints: enabled (zpaq) session=%s root=%s archive_count=%d resume_turn=%d',
                   [GSession, GRoot, GZpaqArchiveCount, GTurn]);
        end;
      cbLegacy:
        begin
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
          GTurn := MaxT;
          LogDebug('checkpoints: enabled (legacy) session=%s root=%s keep=%d resume_turn=%d',
                   [GSession, GRoot, GKeep, GTurn]);
        end;
    end;
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
    case GBackend of
      cbZpaq:
        begin
          ZpaqBeginTurn;
        end;
      cbLegacy:
        begin
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
        end;
    end;
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
    case GBackend of
      cbZpaq:
        ZpaqSnapshotBeforeWrite(AbsPath);
      cbLegacy:
        begin
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
            GTurnPaths.Add(AbsPath);
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
        end;
    end;
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
    if not GEnabled then Exit;
    if GBackend = cbZpaq then
    begin
      Result := ZpaqCountSnapshottedTurns(OldestTurn, NewestTurn);
      Exit;
    end;
    Dir := SessionDir;
    if (Dir = '') or (not DirectoryExists(Dir)) then Exit;
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
    if GBackend = cbZpaq then
    begin
      Result := ZpaqUndoTurns(N, Restored, ErrMsg);
      Exit;
    end;
    { ----- legacy blob backend ----- }
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

function CheckpointsBackend: TCheckpointBackend;
begin
  GLock.Acquire;
  try
    Result := GBackend;
  finally
    GLock.Release;
  end;
end;

function RedoTurns(N: Integer; out Restored: TRestoredFileArray;
                   out ErrMsg: string): Boolean;
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
    if GBackend <> cbZpaq then
    begin
      ErrMsg := 'redo not supported by this backend (legacy blob store has no per-undo capture point; ' +
                'run `make get-zpaq` and start a fresh session for redo)';
      Exit;
    end;
    Result := ZpaqRedoTurns(N, Restored, ErrMsg);
  finally
    GLock.Release;
  end;
end;

function CanRedo: Boolean;
begin
  GLock.Acquire;
  try
    if (not GEnabled) or (GBackend <> cbZpaq) then
      Exit(False);
    Result := ZpaqCanRedo;
  finally
    GLock.Release;
  end;
end;

function CheckpointsStateJSON: string;
{ Built without holding GLock (it calls the public, individually-locked
  accessors and reads the on-disk index/manifests fresh) so it can't deadlock
  against the recursive-vs-not GLock. A turn being written concurrently is a
  benign read-skew for a listing. }
var
  Root, TurnOut, FileOut: TJsonObject;
  TurnsOut, FilesOut: TJsonArray;
  Oldest, Newest, Cnt: Integer;
  Backend: TCheckpointBackend;

  procedure EmitZpaqTurns;
  var
    Idx: TJsonObject;
    Turns, Entries: TJsonArray;
    TObj, EObj: TJsonObject;
    i, j: Integer;
  begin
    Idx := ZpaqLoadIndex;
    try
      Turns := Idx.ChildArray('turns');
      if Turns = nil then Exit;
      for i := 0 to Turns.Count - 1 do
      begin
        TObj := Turns.ItemObject(i);
        if TObj = nil then Continue;
        Entries := TObj.ChildArray('entries');
        if (Entries = nil) or (Entries.Count = 0) then Continue;
        TurnOut := TJsonObject.Create;
        TurnOut.PutInt('turn', TObj.GetInt('turn', 0));
        TurnOut.PutStr('ts',   TObj.GetStr('ts', ''));
        FilesOut := TJsonArray.Create;
        for j := 0 to Entries.Count - 1 do
        begin
          EObj := Entries.ItemObject(j);
          if EObj = nil then Continue;
          FileOut := TJsonObject.Create;
          FileOut.PutStr ('path',    EObj.GetStr('path', ''));
          FileOut.PutBool('created', EObj.GetBool('was_created', False));
          FilesOut.AddObject(FileOut);
        end;
        TurnOut.PutArray('files', FilesOut);
        TurnsOut.AddObject(TurnOut);
      end;
    finally
      Idx.Free;
    end;
  end;

  procedure EmitLegacyTurns;
  var
    T, j: Integer;
    MPath, S: string;
    Man: TJsonObject;
    Files: TJsonArray;
    FObj: TJsonObject;
  begin
    for T := Oldest to Newest do
    begin
      MPath := JoinPath(TurnDir(T), 'manifest.json');
      if not FileExists(MPath) then Continue;
      Man := nil;
      try
        S := ReadFileText(MPath);
        Man := TJsonObject.Parse(S);
      except
        Man := nil;
      end;
      if Man = nil then Continue;
      try
        Files := Man.ChildArray('files');
        TurnOut := TJsonObject.Create;
        TurnOut.PutInt('turn', Man.GetInt('turn', T));
        TurnOut.PutStr('ts',   Man.GetStr('ts', ''));
        FilesOut := TJsonArray.Create;
        if Files <> nil then
          for j := 0 to Files.Count - 1 do
          begin
            FObj := Files.ItemObject(j);
            if FObj = nil then Continue;
            FileOut := TJsonObject.Create;
            FileOut.PutStr ('path',    FObj.GetStr('path', ''));
            FileOut.PutBool('created', False);  { legacy manifest has no created flag }
            FilesOut.AddObject(FileOut);
          end;
        TurnOut.PutArray('files', FilesOut);
        TurnsOut.AddObject(TurnOut);
      finally
        Man.Free;
      end;
    end;
  end;

begin
  Backend := CheckpointsBackend;
  Cnt := CountSnapshottedTurns(Oldest, Newest);
  Root := TJsonObject.Create;
  try
    Root.PutBool('enabled', CheckpointsEnabled);
    case Backend of
      cbZpaq:   Root.PutStr('backend', 'zpaq');
      cbLegacy: Root.PutStr('backend', 'legacy');
    else        Root.PutStr('backend', 'disabled');
    end;
    Root.PutInt ('current_turn', CurrentTurnNumber);
    Root.PutBool('can_redo',     CanRedo);
    Root.PutInt ('count',        Cnt);
    Root.PutInt ('oldest',       Oldest);
    Root.PutInt ('newest',       Newest);
    TurnsOut := TJsonArray.Create;
    if CheckpointsEnabled then
      case Backend of
        cbZpaq:   EmitZpaqTurns;
        cbLegacy: EmitLegacyTurns;
      end;
    Root.PutArray('turns', TurnsOut);
    Result := Root.ToJSON;
  finally
    Root.Free;
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
