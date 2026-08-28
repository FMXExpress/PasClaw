(*
  PasClaw.Projects.Store - Projects, Tasks and Jobs on disk.

  The desktop's unit of work is a Project: a thing being built, usually an app
  the agent is producing. Inside it are Tasks (units of intent) and inside
  those, Jobs (individual agent runs). The whole tree lives under the active
  workspace, one directory per node, one JSON manifest per node:

    <workspace>/projects/
      spam-filter/
        project.json          { name, title, description, created, updated }
        app/                  the app being built (see PasClaw.Apps)
        tasks/
          T0001/
            task.json         { id, title, status, notes, created, updated }
            jobs/
              J0001/
                job.json      { id, status, session_id, started, ended, summary }
                artifacts/

  Files are the database, exactly as sessions and cron already are: greppable,
  syncable, no migration, and a user poking around $PASCLAW_HOME sees what the
  UI shows. Ids are zero-padded ordinals so a directory listing sorts
  chronologically without reading a single manifest.

  Names arrive from two untrusted places -- the model (via the project tools)
  and HTTP (via the gateway) -- so SanitizeName is the only way a caller gets
  a project directory, and every read/write path is built from it.
*)
unit PasClaw.Projects.Store;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TTaskStatus = (tsTodo, tsActive, tsDone, tsBlocked);
  TJobStatus  = (jsQueued, jsRunning, jsDone, jsFailed, jsCancelled);

  TProjectInfo = record
    Name:        string;   { directory name / slug -- the identity }
    Title:       string;   { display name }
    Description: string;
    Created:     string;   { ISO-8601 UTC }
    Updated:     string;
    Icon:        string;   { desktop icon hint, e.g. 'Mail' }
    Suite:       Boolean;  { part of the seeded system suite (§2c) }
    HasApp:      Boolean;  { app/app.json present }
    TaskCount:   Integer;
    OpenTasks:   Integer;
  end;
  TProjectInfoArray = array of TProjectInfo;

  TTaskInfo = record
    Id:      string;   { 'T0001' }
    Project: string;
    Title:   string;
    Status:  TTaskStatus;
    Notes:   string;
    (* Which agent owns this task; '' = unassigned. An agent slug, set
       by a lead through the task tool. Recorded on the board rather
       than only said in a message, because a message is invisible to
       the wake loop and to the other workers -- two agents grabbing
       the same task is exactly what an unrecorded assignment allows. *)
    Assignee: string;
    Created: string;
    Updated: string;
    JobCount: Integer;
  end;
  TTaskInfoArray = array of TTaskInfo;

  TJobInfo = record
    Id:        string;   { 'J0001' }
    Project:   string;
    Task:      string;
    Status:    TJobStatus;
    SessionId: string;
    Started:   string;
    Ended:     string;
    Summary:   string;
  end;
  TJobInfoArray = array of TJobInfo;

{ ---- names ---- }

{ Fold an arbitrary string into a safe directory slug: lowercase, [a-z0-9-],
  runs collapsed, trimmed. Returns '' when nothing usable survives, which
  every caller must treat as a rejection. This is the ONLY way to turn
  caller-supplied text into a path segment. }
function SanitizeName(const S: string): string;

{ True when S is already a safe slug (what SanitizeName would return). }
function IsSafeName(const S: string): Boolean;

{ ---- paths ---- }

function ProjectsRoot: string;                         { <workspace>/projects }
function ProjectDir(const Project: string): string;    { '' when unsafe }
function ProjectAppDir(const Project: string): string;
function TaskDir(const Project, TaskId: string): string;
function JobDir(const Project, TaskId, JobId: string): string;

{ ---- projects ---- }

function ProjectExists(const Project: string): Boolean;
function ListProjects: TProjectInfoArray;
function GetProject(const Project: string; out Info: TProjectInfo): Boolean;

{ Create a project. ATitle is free text; the directory name is derived from it
  unless AName is given. Returns the created slug, or '' with Err set. An
  existing project of the same name is returned as-is (idempotent), so the
  agent re-running a create step doesn't fail the job. }
function CreateProject(const ATitle, AName, ADescription: string;
  out Err: string): string;

function UpdateProject(const Project, ATitle, ADescription, AIcon: string;
  out Err: string): Boolean;

{ Remove a project and everything under it. Refuses unsafe names. }
function DeleteProject(const Project: string; out Err: string): Boolean;

{ ---- tasks ---- }

function TaskStatusToStr(S: TTaskStatus): string;
function StrToTaskStatus(const S: string; Default: TTaskStatus = tsTodo): TTaskStatus;

function ListTasks(const Project: string): TTaskInfoArray;
function GetTask(const Project, TaskId: string; out Info: TTaskInfo): Boolean;
function CreateTask(const Project, ATitle, ANotes: string; out Err: string): string;
{ AAssignee follows the same two-sentinel contract as notes: '-' means
  leave it alone; '' explicitly clears the assignment. }
function UpdateTask(const Project, TaskId, ATitle, ANotes: string;
  const AStatus: string; out Err: string;
  const AAssignee: string = '-'): Boolean;

{ ---- jobs ---- }

function JobStatusToStr(S: TJobStatus): string;
function StrToJobStatus(const S: string; Default: TJobStatus = jsQueued): TJobStatus;

function ListJobs(const Project, TaskId: string): TJobInfoArray;
function GetJob(const Project, TaskId, JobId: string; out Info: TJobInfo): Boolean;

{ Open a job under a task. The runtime calls this when an agent turn or a
  background subagent starts working the task, so transcripts and status wire
  up without the model having to remember to. }
function CreateJob(const Project, TaskId, ASessionId: string; out Err: string): string;
function UpdateJob(const Project, TaskId, JobId, AStatus, ASummary,
  ASessionId: string; out Err: string): Boolean;

{ Append a line to a job's log (jobs/<id>/job.log). The desktop tails this. }
procedure AppendJobLog(const Project, TaskId, JobId, Line: string);
function ReadJobLog(const Project, TaskId, JobId: string): string;

implementation

uses
  SyncObjs,
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Workspaces,
  PasClaw.Desktop.Events;

var
  (* Guards id allocation. NextId picks max+1 by SCANNING the directory,
     which is a read-then-write with a window in the middle: two gateway
     worker threads creating tasks at the same moment both scanned, both
     saw T0004 as the highest, and both took T0005 -- the second write
     landing on the first one's manifest and erasing it.

     Not theoretical. Eight simultaneous creates against a live gateway
     produced seven tasks: two callers were handed the same id and one
     item vanished, silently, with a 200 for both. It went unnoticed
     while every writer was sequential; the desktop's checklist mirror
     now reconciles concurrently, which is what made it reachable.

     One process-wide lock is the right grain here: allocation is a
     directory scan measured in microseconds, and the alternative --
     a lock per project -- buys nothing until projects are being written
     to in parallel at a rate this never approaches. *)
  GIdLock: TCriticalSection = nil;

{ ------------------------------------------------------------------ names -- }

function SanitizeName(const S: string): string;
var
  I: Integer;
  C: Char;
  Prev: Char;
begin
  Result := '';
  Prev := #0;
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      'A'..'Z': C := Chr(Ord(C) + 32);
      'a'..'z', '0'..'9': ;
      else
        C := '-';
    end;
    { Collapse separator runs so "My  App!!" doesn't become "my--app--". }
    if (C = '-') and (Prev = '-') then
      Continue;
    { ...and never lead with one, which would also read as a CLI flag. }
    if (C = '-') and (Result = '') then
      Continue;
    Result := Result + C;
    Prev := C;
  end;
  while (Result <> '') and (Result[Length(Result)] = '-') do
    SetLength(Result, Length(Result) - 1);
  { Length cap: these become directory names on every supported filesystem. }
  if Length(Result) > 64 then
  begin
    SetLength(Result, 64);
    while (Result <> '') and (Result[Length(Result)] = '-') do
      SetLength(Result, Length(Result) - 1);
  end;
end;

function IsSafeName(const S: string): Boolean;
begin
  Result := (S <> '') and (S = SanitizeName(S));
end;

{ ------------------------------------------------------------------ paths -- }

function ProjectsRoot: string;
begin
  Result := WorkspacePath('projects');
end;

function ProjectDir(const Project: string): string;
begin
  if not IsSafeName(Project) then
    Exit('');
  Result := JoinPath(ProjectsRoot, Project);
end;

function ProjectAppDir(const Project: string): string;
var
  Dir: string;
begin
  Dir := ProjectDir(Project);
  if Dir = '' then Exit('');
  Result := JoinPath(Dir, 'app');
end;

function IsTaskId(const Id: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Length(Id) < 2 then Exit;
  if (Id[1] <> 'T') and (Id[1] <> 't') then Exit;
  for I := 2 to Length(Id) do
    if not (Id[I] in ['0'..'9']) then Exit;
  Result := True;
end;

function IsJobId(const Id: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Length(Id) < 2 then Exit;
  if (Id[1] <> 'J') and (Id[1] <> 'j') then Exit;
  for I := 2 to Length(Id) do
    if not (Id[I] in ['0'..'9']) then Exit;
  Result := True;
end;

function TaskDir(const Project, TaskId: string): string;
var
  Dir: string;
begin
  Result := '';
  Dir := ProjectDir(Project);
  if (Dir = '') or not IsTaskId(TaskId) then Exit;
  Result := JoinPath(JoinPath(Dir, 'tasks'), UpperCase(TaskId));
end;

function JobDir(const Project, TaskId, JobId: string): string;
var
  Dir: string;
begin
  Result := '';
  Dir := TaskDir(Project, TaskId);
  if (Dir = '') or not IsJobId(JobId) then Exit;
  Result := JoinPath(JoinPath(Dir, 'jobs'), UpperCase(JobId));
end;

{ ------------------------------------------------------------- shared I/O -- }

function ReadManifest(const Path: string): TJsonObject;
begin
  Result := nil;
  if not FileExists(Path) then Exit;
  try
    Result := TJsonObject.Parse(ReadFileText(Path));
  except
    Result := nil;   { a corrupt manifest must not take down a listing }
  end;
end;

procedure WriteManifest(const Path: string; Obj: TJsonObject);
begin
  EnsureDir(ExtractFileDir(Path));
  WriteFileText(Path, Obj.ToJSON);
end;

{ Directory names under Dir, sorted. Used for tasks/ and jobs/ where the
  zero-padded ids make lexical order chronological. }
function SubdirNames(const Dir: string): TStringList;
var
  Rec: TSearchRec;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(JoinPath(Dir, '*'), faAnyFile, Rec) = 0 then
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then Continue;
        if (Rec.Attr and faDirectory) <> 0 then
          Result.Add(Rec.Name);
      until FindNext(Rec) <> 0;
    finally
      FindClose(Rec);
    end;
end;

{ Next free zero-padded id under Dir, e.g. NextId('.../tasks', 'T') -> 'T0003'.
  Reads the directory rather than a counter file so a manually created or
  deleted directory can't desync a stored high-water mark. }
function NextId(const Dir, Prefix: string): string;
var
  Names: TStringList;
  I, N, Max_: Integer;
begin
  Max_ := 0;
  Names := SubdirNames(Dir);
  try
    for I := 0 to Names.Count - 1 do
      if (Length(Names[I]) > 1) and (UpperCase(Names[I][1]) = Prefix) then
      begin
        N := StrToIntDef(Copy(Names[I], 2, MaxInt), 0);
        if N > Max_ then Max_ := N;
      end;
  finally
    Names.Free;
  end;
  Result := Prefix + Format('%.4d', [Max_ + 1]);
end;

function ReserveId(const Dir, Prefix: string): string;
{ Allocate the next id and STAKE it, under one lock.

  Creating the directory is what makes the reservation visible: NextId
  decides by scanning subdirectories, so a caller that has taken an id
  but not yet made its directory is invisible to the next scanner. Doing
  both inside the lock closes that window; the manifest write afterwards
  does not need to be held, because the id is already spoken for. }
begin
  GIdLock.Enter;
  try
    Result := NextId(Dir, Prefix);
    EnsureDir(JoinPath(Dir, Result));
  finally
    GIdLock.Leave;
  end;
end;

{ --------------------------------------------------------------- projects -- }

function ProjectExists(const Project: string): Boolean;
var
  Dir: string;
begin
  Dir := ProjectDir(Project);
  Result := (Dir <> '') and DirectoryExists(Dir);
end;

function LoadProject(const Project: string; out Info: TProjectInfo): Boolean;
var
  Obj: TJsonObject;
  Dir: string;
  Tasks: TTaskInfoArray;
  I: Integer;
begin
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  Info.Name := ''; Info.Title := ''; Info.Description := '';
  Info.Created := ''; Info.Updated := ''; Info.Icon := '';
  Dir := ProjectDir(Project);
  if (Dir = '') or not DirectoryExists(Dir) then Exit;

  Info.Name := Project;
  Info.Title := Project;
  Obj := ReadManifest(JoinPath(Dir, 'project.json'));
  if Obj <> nil then
    try
      Info.Title       := Obj.GetStr('title', Project);
      Info.Description := Obj.GetStr('description', '');
      Info.Created     := Obj.GetStr('created', '');
      Info.Updated     := Obj.GetStr('updated', '');
      Info.Icon        := Obj.GetStr('icon', '');
      Info.Suite       := Obj.GetBool('suite', False);
    finally
      Obj.Free;
    end;
  Info.HasApp := FileExists(JoinPath(JoinPath(Dir, 'app'), 'app.json'));

  Tasks := ListTasks(Project);
  Info.TaskCount := Length(Tasks);
  Info.OpenTasks := 0;
  for I := 0 to High(Tasks) do
    if Tasks[I].Status in [tsTodo, tsActive] then
      Inc(Info.OpenTasks);
  Result := True;
end;

function GetProject(const Project: string; out Info: TProjectInfo): Boolean;
begin
  Result := LoadProject(Project, Info);
end;

function ListProjects: TProjectInfoArray;
var
  Names: TStringList;
  I, N: Integer;
  Info: TProjectInfo;
begin
  SetLength(Result, 0);
  Names := SubdirNames(ProjectsRoot);
  try
    SetLength(Result, Names.Count);
    N := 0;
    for I := 0 to Names.Count - 1 do
      if LoadProject(Names[I], Info) then
      begin
        Result[N] := Info;
        Inc(N);
      end;
    SetLength(Result, N);
  finally
    Names.Free;
  end;
end;

function CreateProject(const ATitle, AName, ADescription: string;
  out Err: string): string;
var
  Slug, Dir, Now_: string;
  Obj: TJsonObject;
begin
  Err := '';
  Result := '';
  if Trim(AName) <> '' then
    Slug := SanitizeName(AName)
  else
    Slug := SanitizeName(ATitle);
  if Slug = '' then
  begin
    Err := 'a project needs a name with at least one letter or digit';
    Exit;
  end;

  Dir := JoinPath(ProjectsRoot, Slug);
  { Idempotent: the agent re-running its own create step should not fail the
    job, it should carry on with the project that is already there. }
  if DirectoryExists(Dir) then
    Exit(Slug);

  Now_ := NowIsoUtc;
  EnsureDir(Dir);
  EnsureDir(JoinPath(Dir, 'tasks'));
  EnsureDir(JoinPath(Dir, 'app'));

  Obj := TJsonObject.Create;
  try
    Obj.PutStr('name', Slug);
    if Trim(ATitle) <> '' then
      Obj.PutStr('title', Trim(ATitle))
    else
      Obj.PutStr('title', Slug);
    Obj.PutStr('description', ADescription);
    Obj.PutStr('created', Now_);
    Obj.PutStr('updated', Now_);
    WriteManifest(JoinPath(Dir, 'project.json'), Obj);
  finally
    Obj.Free;
  end;
  PublishProjects;
  Result := Slug;
end;

function UpdateProject(const Project, ATitle, ADescription, AIcon: string;
  out Err: string): Boolean;
var
  Dir, Path: string;
  Obj: TJsonObject;
begin
  Err := '';
  Result := False;
  Dir := ProjectDir(Project);
  if (Dir = '') or not DirectoryExists(Dir) then
  begin
    Err := 'no such project: ' + Project;
    Exit;
  end;
  Path := JoinPath(Dir, 'project.json');
  Obj := ReadManifest(Path);
  if Obj = nil then
  begin
    Obj := TJsonObject.Create;
    Obj.PutStr('name', Project);
    Obj.PutStr('created', NowIsoUtc);
  end;
  try
    if Trim(ATitle) <> '' then Obj.PutStr('title', Trim(ATitle));
    { Description and icon are settable to empty on purpose -- clearing a
      description is a legitimate edit, so only nil-equivalent (unchanged)
      callers pass the sentinel '-'. }
    if ADescription <> '-' then Obj.PutStr('description', ADescription);
    if AIcon <> '-' then Obj.PutStr('icon', AIcon);
    Obj.PutStr('updated', NowIsoUtc);
    WriteManifest(Path, Obj);
  finally
    Obj.Free;
  end;
  Result := True;
end;

function RemoveTree(const Dir: string): Boolean;
var
  Rec: TSearchRec;
  Full: string;
begin
  Result := True;
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(JoinPath(Dir, '*'), faAnyFile, Rec) = 0 then
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then Continue;
        Full := JoinPath(Dir, Rec.Name);
        if (Rec.Attr and faDirectory) <> 0 then
          Result := RemoveTree(Full) and Result
        else
          Result := DeleteFile(Full) and Result;
      until FindNext(Rec) <> 0;
    finally
      FindClose(Rec);
    end;
  Result := RemoveDir(Dir) and Result;
end;

function DeleteProject(const Project: string; out Err: string): Boolean;
var
  Dir: string;
begin
  Err := '';
  Dir := ProjectDir(Project);
  if Dir = '' then
  begin
    Err := 'not a project name: ' + Project;
    Exit(False);
  end;
  if not DirectoryExists(Dir) then
  begin
    Err := 'no such project: ' + Project;
    Exit(False);
  end;
  Result := RemoveTree(Dir);
  if not Result then
    Err := 'could not remove ' + Dir
  else
    PublishProjects;
end;

{ ------------------------------------------------------------------ tasks -- }

function TaskStatusToStr(S: TTaskStatus): string;
begin
  case S of
    tsActive:  Result := 'active';
    tsDone:    Result := 'done';
    tsBlocked: Result := 'blocked';
    else       Result := 'todo';
  end;
end;

function StrToTaskStatus(const S: string; Default: TTaskStatus): TTaskStatus;
var
  L: string;
begin
  L := LowerCase(Trim(S));
  if      L = 'todo'    then Result := tsTodo
  else if L = 'active'  then Result := tsActive
  else if L = 'done'    then Result := tsDone
  else if L = 'blocked' then Result := tsBlocked
  else Result := Default;
end;

function LoadTask(const Project, TaskId: string; out Info: TTaskInfo): Boolean;
var
  Dir: string;
  Obj: TJsonObject;
  Jobs: TStringList;
begin
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  Info.Id := ''; Info.Project := ''; Info.Title := '';
  Info.Notes := ''; Info.Created := ''; Info.Updated := '';
  Dir := TaskDir(Project, TaskId);
  if (Dir = '') or not DirectoryExists(Dir) then Exit;

  Info.Id      := UpperCase(TaskId);
  Info.Project := Project;
  Info.Title   := Info.Id;
  Info.Status  := tsTodo;
  Obj := ReadManifest(JoinPath(Dir, 'task.json'));
  if Obj <> nil then
    try
      Info.Title   := Obj.GetStr('title', Info.Id);
      Info.Status  := StrToTaskStatus(Obj.GetStr('status', 'todo'));
      Info.Notes   := Obj.GetStr('notes', '');
      Info.Assignee := Trim(Obj.GetStr('assignee', ''));
      Info.Created := Obj.GetStr('created', '');
      Info.Updated := Obj.GetStr('updated', '');
    finally
      Obj.Free;
    end;
  Jobs := SubdirNames(JoinPath(Dir, 'jobs'));
  try
    Info.JobCount := Jobs.Count;
  finally
    Jobs.Free;
  end;
  Result := True;
end;

function GetTask(const Project, TaskId: string; out Info: TTaskInfo): Boolean;
begin
  Result := LoadTask(Project, TaskId, Info);
end;

function ListTasks(const Project: string): TTaskInfoArray;
var
  Dir: string;
  Names: TStringList;
  I, N: Integer;
  Info: TTaskInfo;
begin
  SetLength(Result, 0);
  Dir := ProjectDir(Project);
  if Dir = '' then Exit;
  Names := SubdirNames(JoinPath(Dir, 'tasks'));
  try
    SetLength(Result, Names.Count);
    N := 0;
    for I := 0 to Names.Count - 1 do
      if LoadTask(Project, Names[I], Info) then
      begin
        Result[N] := Info;
        Inc(N);
      end;
    SetLength(Result, N);
  finally
    Names.Free;
  end;
end;

function CreateTask(const Project, ATitle, ANotes: string; out Err: string): string;
var
  PDir, Id, Dir, Now_: string;
  Obj: TJsonObject;
begin
  Err := '';
  Result := '';
  PDir := ProjectDir(Project);
  if (PDir = '') or not DirectoryExists(PDir) then
  begin
    Err := 'no such project: ' + Project;
    Exit;
  end;
  if Trim(ATitle) = '' then
  begin
    Err := 'a task needs a title';
    Exit;
  end;

  EnsureDir(JoinPath(PDir, 'tasks'));
  Id  := ReserveId(JoinPath(PDir, 'tasks'), 'T');
  Dir := JoinPath(JoinPath(PDir, 'tasks'), Id);
  EnsureDir(JoinPath(Dir, 'jobs'));

  Now_ := NowIsoUtc;
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('id', Id);
    Obj.PutStr('title', Trim(ATitle));
    Obj.PutStr('status', 'todo');
    Obj.PutStr('notes', ANotes);
    Obj.PutStr('created', Now_);
    Obj.PutStr('updated', Now_);
    WriteManifest(JoinPath(Dir, 'task.json'), Obj);
  finally
    Obj.Free;
  end;
  PublishTask(Project, Id, 'todo');
  Result := Id;
end;

function UpdateTask(const Project, TaskId, ATitle, ANotes: string;
  const AStatus: string; out Err: string;
  const AAssignee: string): Boolean;
var
  Dir, Path: string;
  Obj: TJsonObject;
begin
  Err := '';
  Result := False;
  Dir := TaskDir(Project, TaskId);
  if (Dir = '') or not DirectoryExists(Dir) then
  begin
    Err := 'no such task: ' + Project + '/' + TaskId;
    Exit;
  end;
  if (Trim(AStatus) <> '') and
     (LowerCase(Trim(AStatus)) <> 'todo') and
     (LowerCase(Trim(AStatus)) <> 'active') and
     (LowerCase(Trim(AStatus)) <> 'done') and
     (LowerCase(Trim(AStatus)) <> 'blocked') then
  begin
    Err := 'status must be todo, active, done or blocked (got "' + AStatus + '")';
    Exit;
  end;

  Path := JoinPath(Dir, 'task.json');
  Obj := ReadManifest(Path);
  if Obj = nil then
  begin
    Obj := TJsonObject.Create;
    Obj.PutStr('id', UpperCase(TaskId));
    Obj.PutStr('created', NowIsoUtc);
  end;
  try
    { Two "leave this alone" spellings, because two callers grew them
      independently: '' (nothing supplied) and '-' (the route layer's
      explicit sentinel, since an absent JSON key must not clear text the
      user wrote). Accept both for every field. Titling a task '-' is not a
      thing anyone wants; silently wiping a title because a caller used the
      other unit's sentinel is a thing that already happened once. }
    if (Trim(ATitle) <> '') and (Trim(ATitle) <> '-') then
      Obj.PutStr('title', Trim(ATitle));
    if Trim(AStatus) <> '' then Obj.PutStr('status', LowerCase(Trim(AStatus)));
    if ANotes <> '-' then Obj.PutStr('notes', ANotes);
    if AAssignee <> '-' then Obj.PutStr('assignee', LowerCase(Trim(AAssignee)));
    Obj.PutStr('updated', NowIsoUtc);
    WriteManifest(Path, Obj);
  finally
    Obj.Free;
  end;
  PublishTask(Project, UpperCase(TaskId), LowerCase(Trim(AStatus)));
  Result := True;
end;

{ ------------------------------------------------------------------- jobs -- }

function JobStatusToStr(S: TJobStatus): string;
begin
  case S of
    jsRunning:   Result := 'running';
    jsDone:      Result := 'done';
    jsFailed:    Result := 'failed';
    jsCancelled: Result := 'cancelled';
    else         Result := 'queued';
  end;
end;

function StrToJobStatus(const S: string; Default: TJobStatus): TJobStatus;
var
  L: string;
begin
  L := LowerCase(Trim(S));
  if      L = 'queued'    then Result := jsQueued
  else if L = 'running'   then Result := jsRunning
  else if L = 'done'      then Result := jsDone
  else if L = 'failed'    then Result := jsFailed
  else if L = 'cancelled' then Result := jsCancelled
  else Result := Default;
end;

function LoadJob(const Project, TaskId, JobId: string; out Info: TJobInfo): Boolean;
var
  Dir: string;
  Obj: TJsonObject;
begin
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  Info.Id := ''; Info.Project := ''; Info.Task := '';
  Info.SessionId := ''; Info.Started := ''; Info.Ended := ''; Info.Summary := '';
  Dir := JobDir(Project, TaskId, JobId);
  if (Dir = '') or not DirectoryExists(Dir) then Exit;

  Info.Id      := UpperCase(JobId);
  Info.Project := Project;
  Info.Task    := UpperCase(TaskId);
  Info.Status  := jsQueued;
  Obj := ReadManifest(JoinPath(Dir, 'job.json'));
  if Obj <> nil then
    try
      Info.Status    := StrToJobStatus(Obj.GetStr('status', 'queued'));
      Info.SessionId := Obj.GetStr('session_id', '');
      Info.Started   := Obj.GetStr('started', '');
      Info.Ended     := Obj.GetStr('ended', '');
      Info.Summary   := Obj.GetStr('summary', '');
    finally
      Obj.Free;
    end;
  Result := True;
end;

function GetJob(const Project, TaskId, JobId: string; out Info: TJobInfo): Boolean;
begin
  Result := LoadJob(Project, TaskId, JobId, Info);
end;

function ListJobs(const Project, TaskId: string): TJobInfoArray;
var
  Dir: string;
  Names: TStringList;
  I, N: Integer;
  Info: TJobInfo;
begin
  SetLength(Result, 0);
  Dir := TaskDir(Project, TaskId);
  if Dir = '' then Exit;
  Names := SubdirNames(JoinPath(Dir, 'jobs'));
  try
    SetLength(Result, Names.Count);
    N := 0;
    for I := 0 to Names.Count - 1 do
      if LoadJob(Project, TaskId, Names[I], Info) then
      begin
        Result[N] := Info;
        Inc(N);
      end;
    SetLength(Result, N);
  finally
    Names.Free;
  end;
end;

function CreateJob(const Project, TaskId, ASessionId: string; out Err: string): string;
var
  TDir, Id, Dir: string;
  Obj: TJsonObject;
begin
  Err := '';
  Result := '';
  TDir := TaskDir(Project, TaskId);
  if (TDir = '') or not DirectoryExists(TDir) then
  begin
    Err := 'no such task: ' + Project + '/' + TaskId;
    Exit;
  end;

  EnsureDir(JoinPath(TDir, 'jobs'));
  { Same reservation as tasks: two turns starting on one task at the same
    moment would otherwise be handed the same job id, and the second
    would overwrite the first one's transcript. }
  Id  := ReserveId(JoinPath(TDir, 'jobs'), 'J');
  Dir := JoinPath(JoinPath(TDir, 'jobs'), Id);
  EnsureDir(JoinPath(Dir, 'artifacts'));

  Obj := TJsonObject.Create;
  try
    Obj.PutStr('id', Id);
    Obj.PutStr('status', 'running');
    Obj.PutStr('session_id', ASessionId);
    Obj.PutStr('started', NowIsoUtc);
    Obj.PutStr('ended', '');
    Obj.PutStr('summary', '');
    WriteManifest(JoinPath(Dir, 'job.json'), Obj);
  finally
    Obj.Free;
  end;

  { A job starting is what makes a task active -- the desktop shows the task
    lighting up without the model having to set the status itself. }
  UpdateTask(Project, TaskId, '', '-', 'active', Err);
  Err := '';
  PublishJob(Project, UpperCase(TaskId), Id, 'running');
  Result := Id;
end;

function UpdateJob(const Project, TaskId, JobId, AStatus, ASummary,
  ASessionId: string; out Err: string): Boolean;
var
  Dir, Path, St, Ignored: string;
  Obj: TJsonObject;
  Others: TJobInfoArray;
  T: TTaskInfo;
  I: Integer;
  Busy: Boolean;
begin
  Err := '';
  Result := False;
  Dir := JobDir(Project, TaskId, JobId);
  if (Dir = '') or not DirectoryExists(Dir) then
  begin
    Err := 'no such job: ' + Project + '/' + TaskId + '/' + JobId;
    Exit;
  end;
  St := LowerCase(Trim(AStatus));
  if (St <> '') and (St <> 'queued') and (St <> 'running') and (St <> 'done')
     and (St <> 'failed') and (St <> 'cancelled') then
  begin
    Err := 'status must be queued, running, done, failed or cancelled (got "'
           + AStatus + '")';
    Exit;
  end;

  Path := JoinPath(Dir, 'job.json');
  Obj := ReadManifest(Path);
  if Obj = nil then
  begin
    Obj := TJsonObject.Create;
    Obj.PutStr('id', UpperCase(JobId));
    Obj.PutStr('started', NowIsoUtc);
  end;
  try
    if St <> '' then
    begin
      Obj.PutStr('status', St);
      { A terminal status stamps the end time once; re-reporting 'done'
        shouldn't keep moving it. }
      if (St = 'done') or (St = 'failed') or (St = 'cancelled') then
      begin
        if Obj.GetStr('ended', '') = '' then
          Obj.PutStr('ended', NowIsoUtc);
      end
      else
        Obj.PutStr('ended', '');
    end;
    if ASummary   <> '-' then Obj.PutStr('summary', ASummary);
    if ASessionId <> '-' then Obj.PutStr('session_id', ASessionId);
    WriteManifest(Path, Obj);
  finally
    Obj.Free;
  end;
  if St <> '' then
    PublishJob(Project, UpperCase(TaskId), UpperCase(JobId), St);

  (* A task is done when its last job is. Opening a job makes the task
     active (CreateJob), so the symmetric rule belongs here rather than in
     any one caller -- the `task` tool, an HTTP PATCH and the gateway's job
     runner all finish jobs, and before this only the tool closed the task.

     Two guards: a task with another job still in flight stays active, and a
     task the user marked BLOCKED is not quietly reopened as done -- only an
     active task closes itself. *)
  if (St = 'done') or (St = 'failed') or (St = 'cancelled') then
  begin
    Others := ListJobs(Project, TaskId);
    Busy := False;
    for I := 0 to High(Others) do
      if Others[I].Status in [jsQueued, jsRunning] then
      begin
        Busy := True;
        Break;
      end;
    if not Busy and GetTask(Project, TaskId, T) and (T.Status = tsActive) then
    begin
      if St = 'done' then
        UpdateTask(Project, TaskId, '', '-', 'done', Ignored)
      else
        { A failed run leaves work to do -- back to todo, not done. }
        UpdateTask(Project, TaskId, '', '-', 'todo', Ignored);
    end;
  end;
  Result := True;
end;

procedure AppendJobLog(const Project, TaskId, JobId, Line: string);
var
  Dir, Path: string;
  F: TextFile;
begin
  Dir := JobDir(Project, TaskId, JobId);
  if (Dir = '') or not DirectoryExists(Dir) then Exit;
  Path := JoinPath(Dir, 'job.log');
  AssignFile(F, Path);
  try
    if FileExists(Path) then
      Append(F)
    else
      Rewrite(F);
    WriteLn(F, Line);
  finally
    CloseFile(F);
  end;
  PublishJobLog(Project, UpperCase(TaskId), UpperCase(JobId), Line);
end;

function ReadJobLog(const Project, TaskId, JobId: string): string;
var
  Dir, Path: string;
begin
  Result := '';
  Dir := JobDir(Project, TaskId, JobId);
  if Dir = '' then Exit;
  Path := JoinPath(Dir, 'job.log');
  if FileExists(Path) then
    Result := ReadFileText(Path);
end;

initialization
  GIdLock := TCriticalSection.Create;

finalization
  FreeAndNil(GIdLock);

end.
