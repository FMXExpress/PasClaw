(*
  PasClaw.Workspaces - multiple agent worlds, one per directory.

  PasClaw has always had exactly one workspace: $PASCLAW_HOME/workspace, with
  memory/, sessions/, skills/ and cron/ inside it. The desktop client wants
  several -- switching one is meant to feel like switching virtual desktops --
  so this unit owns the whole idea of "which workspace is active" and hands
  out paths inside it.

  Layout ($PASCLAW_HOME):

    workspace/        <- the original directory. IS workspace #1; nothing moved.
      memory/ sessions/ skills/ cron/ projects/ pages/ desktop/
    workspace2/       <- created on demand, same shape
    workspace3/

  The active one is config.json's "active_workspace" (a bare directory name,
  default 'workspace'), overridable per-process by $PASCLAW_WORKSPACE -- which
  is what lets a subagent, a test, or a second gateway run against a different
  world without rewriting the user's config.

  Why directory names and not ids: the names ARE the on-disk truth, they sort,
  and a user who pokes around $PASCLAW_HOME sees exactly what the UI shows.
  Slot 1 keeps the unnumbered name for back-compat, so WorkspaceDirName(1) is
  'workspace' and WorkspaceDirName(2) is 'workspace2'.

  Everything else in the tree should ask this unit for its paths rather than
  joining 'workspace' itself. ActiveWorkspaceRoot is the single source of
  truth; when no one has switched anything it returns the same string the old
  hardcoded JoinPath(GetHome, 'workspace') produced, so existing installs are
  untouched.
*)
unit PasClaw.Workspaces;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

const
  { Slot 1 keeps the historical unnumbered name. }
  DefaultWorkspaceName = 'workspace';
  { Per-process override; wins over config.json. }
  EnvWorkspace         = 'PASCLAW_WORKSPACE';

type
  TWorkspaceInfo = record
    Name:     string;   { directory name, e.g. 'workspace2' }
    Slot:     Integer;  { 1 for 'workspace', N for 'workspaceN' }
    Path:     string;   { absolute path }
    Label_:   string;   { display name from desktop/workspace.json, or '' }
    Active:   Boolean;
    Projects: Integer;  { project count, for the UI's pager tooltip }
  end;
  TWorkspaceInfoArray = array of TWorkspaceInfo;

{ The directory name for a slot: 1 -> 'workspace', 2 -> 'workspace2'. }
function WorkspaceDirName(Slot: Integer): string;

{ True when Name is a legal workspace directory name ('workspace' or
  'workspace' + digits). Guards every path that comes in over HTTP. }
function IsWorkspaceName(const Name: string): Boolean;

{ Slot number encoded in a workspace directory name; 0 when it isn't one. }
function WorkspaceSlot(const Name: string): Integer;

{ The active workspace's directory name -- $PASCLAW_WORKSPACE, else
  config.json's active_workspace, else 'workspace'. Never returns ''. }
function ActiveWorkspaceName: string;

{ Absolute path of the active workspace. The replacement for every
  JoinPath(GetHome, 'workspace') in the tree. }
function ActiveWorkspaceRoot: string;

{ Absolute path of a named workspace (no existence check). }
function WorkspaceRoot(const Name: string): string;

{ A subdirectory of the active workspace, created if missing:
    WorkspaceSubdir('memory') -> <home>/workspace/memory
  Sub may be a multi-segment relative path using '/' separators. }
function WorkspaceSubdir(const Sub: string): string;

{ Same, without creating anything. }
function WorkspacePath(const Sub: string): string;

{ Enumerate every workspace directory that exists, ordered by slot. Always
  reports slot 1 even when $PASCLAW_HOME/workspace hasn't been created yet,
  so a fresh install still shows one desktop to switch to. }
function ListWorkspaces: TWorkspaceInfoArray;

{ Create the next free slot (or a specific one) and seed its subdirectories.
  Returns the new directory name. ALabel is stored for display and may be ''. }
function CreateWorkspace(const ALabel: string = ''): string;
function CreateWorkspaceSlot(Slot: Integer; const ALabel: string = ''): string;

{ Switch the active workspace, persisting to config.json. Fails (False) when
  the name is malformed or the directory doesn't exist. }
function SetActiveWorkspace(const Name: string; out Err: string): Boolean;

{ Display label for a workspace, falling back to a generated one
  ('Workspace 1'). }
function WorkspaceLabel(const Name: string): string;
procedure SetWorkspaceLabel(const Name, ALabel: string);

{ Create the standard subdirectory set inside a workspace. Idempotent --
  called on create and lazily by ActiveWorkspaceRoot's first use. }
procedure EnsureWorkspaceLayout(const Root: string);

implementation

uses
  PasClaw.Utils,     { JoinPath, EnsureDir, ReadFileText, WriteFileText }
  PasClaw.Config,    { GetHome, GetConfigPath }
  PasClaw.JSON;

const
  { Seeded in every workspace so the agent's existing machinery (memory index,
    session store, skills scan) finds its directories in a new world too. }
  StdSubdirs: array[0..6] of string =
    ('memory', 'sessions', 'skills', 'cron', 'projects', 'pages', 'desktop');

function WorkspaceDirName(Slot: Integer): string;
begin
  if Slot <= 1 then
    Result := DefaultWorkspaceName
  else
    Result := DefaultWorkspaceName + IntToStr(Slot);
end;

function WorkspaceSlot(const Name: string): Integer;
var
  Tail: string;
  I: Integer;
begin
  Result := 0;
  if Name = DefaultWorkspaceName then
    Exit(1);
  if not HasPrefix(Name, DefaultWorkspaceName) then
    Exit;
  Tail := Copy(Name, Length(DefaultWorkspaceName) + 1, MaxInt);
  if Tail = '' then
    Exit;
  for I := 1 to Length(Tail) do
    if not (Tail[I] in ['0'..'9']) then
      Exit(0);
  { 'workspace0' and 'workspace1' are not names we mint (slot 1 is the bare
     name); accepting them would give one directory two identities. }
  Result := StrToIntDef(Tail, 0);
  if Result < 2 then
    Result := 0;
end;

function IsWorkspaceName(const Name: string): Boolean;
begin
  Result := WorkspaceSlot(Name) > 0;
end;

function WorkspaceRoot(const Name: string): string;
begin
  Result := JoinPath(GetHome, Name);
end;

function ActiveWorkspaceName: string;
var
  Env, Cfg, Body: string;
  Obj: TJsonObject;
begin
  Env := Trim(GetEnvironmentVariable(EnvWorkspace));
  if (Env <> '') and IsWorkspaceName(Env) then
    Exit(Env);

  Result := DefaultWorkspaceName;
  if not FileExists(GetConfigPath) then
    Exit;
  { Read config.json directly rather than through LoadConfig: this unit sits
    underneath the config record (paths are needed while it is being built)
    and a full load here would recurse. }
  Body := ReadFileText(GetConfigPath);
  if Trim(Body) = '' then
    Exit;
  try
    Obj := TJsonObject.Parse(Body);
  except
    Exit;   { a broken config must not strand the user without a workspace }
  end;
  try
    Cfg := Trim(Obj.GetStr('active_workspace', ''));
    if (Cfg <> '') and IsWorkspaceName(Cfg) then
      Result := Cfg;
  finally
    Obj.Free;
  end;
end;

procedure EnsureWorkspaceLayout(const Root: string);
var
  I: Integer;
begin
  EnsureDir(Root);
  for I := Low(StdSubdirs) to High(StdSubdirs) do
    EnsureDir(JoinPath(Root, StdSubdirs[I]));
end;

function ActiveWorkspaceRoot: string;
begin
  Result := WorkspaceRoot(ActiveWorkspaceName);
end;

function WorkspacePath(const Sub: string): string;
begin
  Result := ActiveWorkspaceRoot;
  if Sub <> '' then
    Result := JoinPath(Result, Sub);
end;

function WorkspaceSubdir(const Sub: string): string;
begin
  Result := WorkspacePath(Sub);
  EnsureDir(Result);
end;

function WorkspaceMetaPath(const Name: string): string;
begin
  Result := JoinPath(JoinPath(WorkspaceRoot(Name), 'desktop'), 'workspace.json');
end;

function WorkspaceLabel(const Name: string): string;
var
  Obj: TJsonObject;
  Path: string;
  Slot: Integer;
begin
  Result := '';
  Path := WorkspaceMetaPath(Name);
  if FileExists(Path) then
    try
      Obj := TJsonObject.Parse(ReadFileText(Path));
      try
        Result := Trim(Obj.GetStr('label', ''));
      finally
        Obj.Free;
      end;
    except
      Result := '';
    end;
  if Result = '' then
  begin
    Slot := WorkspaceSlot(Name);
    if Slot > 0 then
      Result := 'Workspace ' + IntToStr(Slot)
    else
      Result := Name;
  end;
end;

procedure SetWorkspaceLabel(const Name, ALabel: string);
var
  Obj: TJsonObject;
  Path: string;
begin
  if not IsWorkspaceName(Name) then
    Exit;
  Path := WorkspaceMetaPath(Name);
  EnsureDir(ExtractFileDir(Path));
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('label', ALabel);
    Obj.PutStr('name', Name);
    WriteFileText(Path, Obj.ToJSON);
  finally
    Obj.Free;
  end;
end;

function CountProjects(const Root: string): Integer;
var
  Rec: TSearchRec;
  Dir: string;
begin
  Result := 0;
  Dir := JoinPath(Root, 'projects');
  if not DirectoryExists(Dir) then
    Exit;
  if FindFirst(JoinPath(Dir, '*'), faAnyFile, Rec) = 0 then
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then
          Continue;
        if (Rec.Attr and faDirectory) <> 0 then
          Inc(Result);
      until FindNext(Rec) <> 0;
    finally
      FindClose(Rec);
    end;
end;

function ListWorkspaces: TWorkspaceInfoArray;
var
  Rec: TSearchRec;
  Names: TStringList;
  Active: string;
  I, Slot, J: Integer;
  Info: TWorkspaceInfo;
  Tmp: TWorkspaceInfo;
begin
  SetLength(Result, 0);
  Active := ActiveWorkspaceName;
  Names := TStringList.Create;
  try
    if FindFirst(JoinPath(GetHome, DefaultWorkspaceName + '*'), faAnyFile, Rec) = 0 then
      try
        repeat
          if (Rec.Attr and faDirectory) = 0 then
            Continue;
          if IsWorkspaceName(Rec.Name) and (Names.IndexOf(Rec.Name) < 0) then
            Names.Add(Rec.Name);
        until FindNext(Rec) <> 0;
      finally
        FindClose(Rec);
      end;

    { Slot 1 always exists conceptually -- a fresh install has no directories
      yet but still has one desktop. }
    if Names.IndexOf(DefaultWorkspaceName) < 0 then
      Names.Add(DefaultWorkspaceName);
    { The active one must be listable even if its directory was removed under
      us, or the UI would show no current workspace at all. }
    if Names.IndexOf(Active) < 0 then
      Names.Add(Active);

    SetLength(Result, Names.Count);
    for I := 0 to Names.Count - 1 do
    begin
      Slot := WorkspaceSlot(Names[I]);
      Info.Name     := Names[I];
      Info.Slot     := Slot;
      Info.Path     := WorkspaceRoot(Names[I]);
      Info.Label_   := WorkspaceLabel(Names[I]);
      Info.Active   := Names[I] = Active;
      Info.Projects := CountProjects(Info.Path);
      Result[I] := Info;
    end;
  finally
    Names.Free;
  end;

  { Insertion sort by slot -- the list is single digits long in practice. }
  for I := 1 to High(Result) do
  begin
    Tmp := Result[I];
    J := I - 1;
    while (J >= 0) and (Result[J].Slot > Tmp.Slot) do
    begin
      Result[J + 1] := Result[J];
      Dec(J);
    end;
    Result[J + 1] := Tmp;
  end;
end;

function CreateWorkspaceSlot(Slot: Integer; const ALabel: string): string;
begin
  if Slot < 1 then
    Slot := 1;
  Result := WorkspaceDirName(Slot);
  EnsureWorkspaceLayout(WorkspaceRoot(Result));
  if ALabel <> '' then
    SetWorkspaceLabel(Result, ALabel);
end;

function CreateWorkspace(const ALabel: string): string;
var
  Slot: Integer;
begin
  { First free slot, counting from 2 -- slot 1 is the original workspace and
    is never "created" by this path. }
  Slot := 2;
  while DirectoryExists(WorkspaceRoot(WorkspaceDirName(Slot))) do
    Inc(Slot);
  Result := CreateWorkspaceSlot(Slot, ALabel);
end;

function SetActiveWorkspace(const Name: string; out Err: string): Boolean;
var
  Obj: TJsonObject;
  Body: string;
begin
  Err := '';
  Result := False;
  if not IsWorkspaceName(Name) then
  begin
    Err := 'not a workspace name: ' + Name;
    Exit;
  end;
  if not DirectoryExists(WorkspaceRoot(Name)) then
  begin
    { Slot 1 is allowed to not exist yet -- it is created on first use, the
      same way the pre-workspaces code created it. }
    if WorkspaceSlot(Name) = 1 then
      EnsureWorkspaceLayout(WorkspaceRoot(Name))
    else
    begin
      Err := 'no such workspace: ' + Name;
      Exit;
    end;
  end;

  Body := '';
  if FileExists(GetConfigPath) then
    Body := ReadFileText(GetConfigPath);
  if Trim(Body) = '' then
    Body := '{}';
  try
    Obj := TJsonObject.Parse(Body);
  except
    on E: Exception do
    begin
      Err := 'config.json is not valid JSON: ' + E.Message;
      Exit;
    end;
  end;
  try
    Obj.PutStr('active_workspace', Name);
    EnsureDir(ExtractFileDir(GetConfigPath));
    WriteFileText(GetConfigPath, Obj.ToJSON);
  finally
    Obj.Free;
  end;

  { A switch that leaves $PASCLAW_WORKSPACE set would look like it silently
    failed -- the env var outranks what we just wrote. Say so. }
  if (Trim(GetEnvironmentVariable(EnvWorkspace)) <> '') and
     (Trim(GetEnvironmentVariable(EnvWorkspace)) <> Name) then
    Err := 'saved, but $' + EnvWorkspace + ' overrides it for this process';
  Result := True;
end;

end.
