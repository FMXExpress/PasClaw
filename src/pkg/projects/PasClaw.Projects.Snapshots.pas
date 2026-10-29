(*
  PasClaw.Projects.Snapshots -- the project as it stood when work was
  submitted.

  Phase 4 of docs/team-board-plan.md turns a cause that rejects work twice
  into a rule, and a rule is only worth keeping if it is PROVEN: it must
  fail against the submission that was rejected for that cause and pass
  against the one accepted after the fix. "Against" needs the files as
  they were at each submission, and the plan left open how to get them
  for a project that is not a git repository -- most team projects are a
  projects/<p>/app/ folder.

  Settled here: PasClaw takes its own copy at every submit. That works
  the same with or without git, it is exactly what the reviewer looked at
  (taken after the held-out gate, before the task moves to review), and it
  lives OUTSIDE the workspace -- $PASCLAW_HOME/snapshots/<workspace>/
  <project>/<task>/S0003/ -- so the builder cannot edit the evidence of
  what it submitted.

  What is copied: the project directory, minus the board's own records
  (tasks/, project.json, activity.jsonl) and directories that are
  dependencies rather than work (.git, node_modules, __pycache__, venv,
  .venv). Bounded at SnapshotMaxBytes; a project bigger than that is not
  snapshotted at all -- a partial copy would prove things about files
  that were never there -- and the submission says so. Symlinks are not
  followed. The newest SnapshotsKeptPerTask per task are kept.
*)
unit PasClaw.Projects.Snapshots;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

const
  SnapshotMaxBytes     = 50 * 1024 * 1024;
  SnapshotsKeptPerTask = 10;

{ $PASCLAW_HOME/snapshots/<workspace>/<project>; '' for an unsafe name. }
function SnapshotsRoot(const Project: string): string;
function SnapshotDir(const Project, TaskId, SnapId: string): string;

(* Copy the project for this task's next submission. SnapId is 'S0001',
   'S0002', ... per task. False with Err when the project is too big or
   the copy failed -- never a partial snapshot. *)
function TakeSnapshot(const Project, TaskId: string; out SnapId, Err: string): Boolean;

{ Remove every snapshot of a project (DeleteProject calls this). }
procedure RemoveSnapshots(const Project: string);

implementation

uses
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Workspaces;

function SafeSlug(const S: string): Boolean;
var
  I: Integer;
begin
  Result := S <> '';
  for I := 1 to Length(S) do
    if not (S[I] in ['a'..'z', '0'..'9', '-']) then Exit(False);
end;

function SnapshotsRoot(const Project: string): string;
begin
  Result := '';
  if not SafeSlug(Project) then Exit;
  Result := JoinPath(JoinPath(JoinPath(GetHome, 'snapshots'), ActiveWorkspaceName),
                     Project);
end;

function SafeId(const S: string; Prefix: Char): Boolean;
var
  I: Integer;
begin
  Result := (Length(S) >= 2) and (UpCase(S[1]) = Prefix);
  if not Result then Exit;
  for I := 2 to Length(S) do
    if not (S[I] in ['0'..'9']) then Exit(False);
end;

function SnapshotDir(const Project, TaskId, SnapId: string): string;
var
  Root: string;
begin
  Result := '';
  Root := SnapshotsRoot(Project);
  if (Root = '') or not SafeId(TaskId, 'T') or not SafeId(SnapId, 'S') then Exit;
  Result := JoinPath(JoinPath(Root, UpperCase(TaskId)), UpperCase(SnapId));
end;

{ Directories that are someone else's code or the board's records. }
function Skipped(const Name: string; TopLevel: Boolean): Boolean;
var
  L: string;
begin
  L := LowerCase(Name);
  Result := (L = '.git') or (L = 'node_modules') or (L = '__pycache__') or
            (L = 'venv') or (L = '.venv');
  if TopLevel then
    Result := Result or (L = 'tasks') or (L = 'project.json') or
              (L = 'activity.jsonl');
end;

function TreeBytes(const Dir: string; TopLevel: Boolean; Limit: Int64): Int64;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(JoinPath(Dir, '*'), faAnyFile, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faSymLink) <> 0 then Continue;
      if Skipped(SR.Name, TopLevel) then Continue;
      if (SR.Attr and faDirectory) <> 0 then
        Result := Result + TreeBytes(JoinPath(Dir, SR.Name), False, Limit - Result)
      else
        Result := Result + SR.Size;
      if Result > Limit then Exit;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure CopyOne(const From_, To_: string);
var
  A, B: TFileStream;
begin
  A := TFileStream.Create(From_, fmOpenRead or fmShareDenyNone);
  try
    B := TFileStream.Create(To_, fmCreate);
    try
      if A.Size > 0 then B.CopyFrom(A, A.Size);
    finally
      B.Free;
    end;
  finally
    A.Free;
  end;
end;

procedure CopyTree(const FromDir, ToDir: string; TopLevel: Boolean);
var
  SR: TSearchRec;
begin
  ForceDirectories(ToDir);
  if FindFirst(JoinPath(FromDir, '*'), faAnyFile, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faSymLink) <> 0 then Continue;
      if Skipped(SR.Name, TopLevel) then Continue;
      if (SR.Attr and faDirectory) <> 0 then
        CopyTree(JoinPath(FromDir, SR.Name), JoinPath(ToDir, SR.Name), False)
      else
        CopyOne(JoinPath(FromDir, SR.Name), JoinPath(ToDir, SR.Name));
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

function RemoveTree(const Dir: string): Boolean;
var
  SR: TSearchRec;
  Full: string;
begin
  Result := True;
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(JoinPath(Dir, '*'), faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      Full := JoinPath(Dir, SR.Name);
      if ((SR.Attr and faDirectory) <> 0) and ((SR.Attr and faSymLink) = 0) then
        Result := RemoveTree(Full) and Result
      else
        Result := SysUtils.DeleteFile(Full) and Result;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  Result := RemoveDir(Dir) and Result;
end;

function SnapNames(const TaskDir: string): TStringList;
var
  SR: TSearchRec;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  if not DirectoryExists(TaskDir) then Exit;
  if FindFirst(JoinPath(TaskDir, 'S*'), faDirectory, SR) = 0 then
  try
    repeat
      if ((SR.Attr and faDirectory) <> 0) and SafeId(SR.Name, 'S') then
        Result.Add(UpperCase(SR.Name));
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

function TakeSnapshot(const Project, TaskId: string; out SnapId, Err: string): Boolean;
var
  Src, TaskRoot, Dst: string;
  Names: TStringList;
  I, Max_, N: Integer;
begin
  SnapId := '';
  Err := '';
  Result := False;
  Src := JoinPath(WorkspacePath('projects'), Project);
  if (SnapshotsRoot(Project) = '') or not SafeId(TaskId, 'T') or
     not DirectoryExists(Src) then
  begin
    Err := 'no such project to snapshot: ' + Project;
    Exit;
  end;
  if TreeBytes(Src, True, SnapshotMaxBytes) > SnapshotMaxBytes then
  begin
    Err := Format('the project is over %d MB, so this submission was not ' +
                  'snapshotted -- a rule cannot be proven against it',
                  [SnapshotMaxBytes div (1024 * 1024)]);
    Exit;
  end;
  TaskRoot := JoinPath(SnapshotsRoot(Project), UpperCase(TaskId));
  Names := SnapNames(TaskRoot);
  try
    Max_ := 0;
    for I := 0 to Names.Count - 1 do
    begin
      N := StrToIntDef(Copy(Names[I], 2, MaxInt), 0);
      if N > Max_ then Max_ := N;
    end;
  finally
    Names.Free;
  end;
  SnapId := 'S' + Format('%.4d', [Max_ + 1]);
  Dst := JoinPath(TaskRoot, SnapId);
  try
    CopyTree(Src, Dst, True);
  except
    on E: Exception do
    begin
      RemoveTree(Dst);
      Err := 'snapshot failed: ' + E.Message;
      SnapId := '';
      Exit;
    end;
  end;
  { Keep the newest few per task; a long review loop should not fill a disk. }
  Names := SnapNames(TaskRoot);
  try
    for I := 0 to Names.Count - SnapshotsKeptPerTask - 1 do
      RemoveTree(JoinPath(TaskRoot, Names[I]));
  finally
    Names.Free;
  end;
  Result := True;
end;

procedure RemoveSnapshots(const Project: string);
var
  Root: string;
begin
  Root := SnapshotsRoot(Project);
  if Root <> '' then RemoveTree(Root);
end;

end.
