(*
  PasClaw.Tools.Worktree -- git worktrees, so parallel work gets parallel
  checkouts.

  Two subagents editing the same tree collide: one's half-finished edit
  is the other's compile error. git's answer is a worktree -- a second
  checkout of the same repository on its own branch, sharing the object
  store. This unit gives the model three tools over it and gives spawn /
  spawn_background a `worktree` argument that runs the child inside one
  (its sandbox workspace and shell cwd both point there; see
  TToolLoopConfig.Workspace).

    worktree_create(branch, base?)   -> path       (tcMutating)
    worktree_list                    -> text       (tcReadOnly)
    worktree_remove(path, force?)    -> ok         (tcMutating)

  Every git call goes through the active shell backend, so the Docker
  backend and the shell denylist apply exactly as they do to shell_exec.
  Worktrees live under worktree.directory (config), or by default beside
  the repository in <repo>-worktrees/<branch>, so a `git status` in the
  main tree never shows them. create is idempotent: an existing worktree
  for the branch is returned as-is, which is what a parent that spawns
  the same branch twice wants. remove refuses a worktree with uncommitted
  changes unless force is set -- and force is a resource the permissions
  list can gate (tool=worktree_remove).
*)
unit PasClaw.Tools.Worktree;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes,
  PasClaw.Tools.Registry;

{ The repository root that contains Dir ('' when Dir is not in a git
  checkout, or git is not on the PATH). }
function GitRepoRoot(const Dir: string; out Root: string): Boolean;

{ Where worktrees for RepoRoot go: Configured when set, else
  <parent of repo>/<repo name>-worktrees. }
function WorktreeBaseDir(const RepoRoot, Configured: string): string;

{ A branch name as a directory name: slashes and other separators become
  dashes, so feature/x and feature-x do not collide only by accident. }
function BranchDirName(const Branch: string): string;

{ Create (or find) the worktree for Branch. Base is the start point for a
  new branch ('' = HEAD); ignored when the branch already exists. Path is
  the worktree directory on success. }
function WorktreeCreate(const RepoRoot, Configured, Branch, Base: string;
                        out Path, Err: string): Boolean;

{ `git worktree list --porcelain` parsed to one line per worktree:
  "<path>  <branch or (detached)>  <head7>". }
function WorktreeList(const RepoRoot: string; out Text, Err: string): Boolean;

{ True when the worktree at Path has uncommitted changes (tracked or
  untracked). False also when Path is not a worktree -- callers check
  existence first. }
function WorktreeDirty(const Path: string): Boolean;

{ Remove the worktree at Path. Without Force a dirty worktree is refused
  with a message that says so. The branch is left in place. }
function WorktreeRemove(const RepoRoot, Path: string; Force: Boolean;
                        out Err: string): Boolean;

{ The spawn path: resolve the repository from the current sandbox
  workspace, read worktree.directory from the effective config, create or
  find the worktree for Branch. }
function EnsureWorktree(const Branch: string; out Path, Err: string): Boolean;

procedure RegisterWorktreeTools(R: TToolRegistry);

implementation

uses
  PasClaw.Logger,
  PasClaw.JSON,
  PasClaw.Config,
  PasClaw.Tools.Types,
  PasClaw.Tools.Sandbox,
  PasClaw.Shell.Backend;

{ ------------------------------------------------------------ git }

function Q(const S: string): string;
begin
  {$IFDEF MSWINDOWS}
  Result := '"' + StringReplace(S, '"', '\"', [rfReplaceAll]) + '"';
  {$ELSE}
  Result := '''' + StringReplace(S, '''', '''\''''', [rfReplaceAll]) + '''';
  {$ENDIF}
end;

{ Run one git command in WorkDir through the active shell backend.
  Returns the exit code; Output is stdout+stderr, trimmed. }
function Git(const WorkDir, Args: string; out Output: string): Integer;
var
  Cmd: string;
begin
  Cmd := 'git ' + Args;
  Result := RunOneShotViaBackend(GetCurrentSessionId, Cmd, WorkDir, Output);
  Output := Trim(Output);
end;

function GitRepoRoot(const Dir: string; out Root: string): Boolean;
var
  Out_: string;
  D: string;
begin
  Root := '';
  D := Dir;
  if Trim(D) = '' then D := GetCurrentDir;
  if not DirectoryExists(D) then Exit(False);
  Result := (Git(D, 'rev-parse --show-toplevel', Out_) = 0) and (Out_ <> '');
  if Result then
    Root := ExcludeTrailingPathDelimiter(ExpandFileName(Out_));
end;

function WorktreeBaseDir(const RepoRoot, Configured: string): string;
var
  R: string;
begin
  if Trim(Configured) <> '' then
    Exit(ExcludeTrailingPathDelimiter(ExpandFileName(Configured)));
  R := ExcludeTrailingPathDelimiter(RepoRoot);
  Result := IncludeTrailingPathDelimiter(ExtractFileDir(R)) + ExtractFileName(R) + '-worktrees';
end;

function BranchDirName(const Branch: string): string;
var
  i: Integer;
  C: Char;
begin
  Result := '';
  for i := 1 to Length(Branch) do
  begin
    C := Branch[i];
    if C in ['a'..'z', 'A'..'Z', '0'..'9', '.', '_', '-'] then
      Result := Result + C
    else
      Result := Result + '-';
  end;
  while (Result <> '') and (Result[1] = '-') do Delete(Result, 1, 1);
  while (Result <> '') and (Result[Length(Result)] = '-') do Delete(Result, Length(Result), 1);
  if Result = '' then Result := 'worktree';
end;

function ValidBranch(const Branch: string): Boolean;
begin
  { git's own check-ref-format is the authority; this just keeps the
    obvious shell-shaped garbage out before it reaches the command. }
  Result := (Trim(Branch) <> '') and (Pos(' ', Branch) = 0) and (Pos('..', Branch) = 0) and
            (Pos('''', Branch) = 0) and (Pos('"', Branch) = 0) and (Pos('$', Branch) = 0) and
            (Pos('`', Branch) = 0) and (Pos(';', Branch) = 0) and (Pos('|', Branch) = 0) and
            (Pos('&', Branch) = 0) and (Branch[1] <> '-');
end;

{ Registered worktree path for Branch, '' when none. Parses
  `worktree list --porcelain` (blocks of "worktree <p>" / "HEAD" /
  "branch refs/heads/<b>"). }
function FindWorktreeForBranch(const RepoRoot, Branch: string): string;
var
  Out_, Line, CurPath: string;
  L: TStringList;
  i: Integer;
begin
  Result := '';
  if Git(RepoRoot, 'worktree list --porcelain', Out_) <> 0 then Exit;
  L := TStringList.Create;
  try
    L.Text := Out_;
    CurPath := '';
    for i := 0 to L.Count - 1 do
    begin
      Line := Trim(L[i]);
      if Copy(Line, 1, 9) = 'worktree ' then CurPath := Trim(Copy(Line, 10, MaxInt))
      else if (Copy(Line, 1, 7) = 'branch ') and
              (Trim(Copy(Line, 8, MaxInt)) = 'refs/heads/' + Branch) then
      begin
        Result := CurPath;
        Exit;
      end;
    end;
  finally
    L.Free;
  end;
end;

function WorktreeCreate(const RepoRoot, Configured, Branch, Base: string;
                        out Path, Err: string): Boolean;
var
  Out_, BaseDir, Args: string;
  BranchExists: Boolean;
begin
  Result := False;
  Path := '';
  Err := '';
  if not ValidBranch(Branch) then
  begin
    Err := 'worktree_create: branch name is not acceptable: ' + Branch;
    Exit;
  end;
  if (Base <> '') and (not ValidBranch(Base)) then
  begin
    Err := 'worktree_create: base ref is not acceptable: ' + Base;
    Exit;
  end;
  { Already checked out somewhere? Return that. }
  Path := FindWorktreeForBranch(RepoRoot, Branch);
  if (Path <> '') and DirectoryExists(Path) then Exit(True);

  BaseDir := WorktreeBaseDir(RepoRoot, Configured);
  if not ForceDirectories(BaseDir) then
  begin
    Err := 'worktree_create: cannot create ' + BaseDir;
    Exit;
  end;
  Path := IncludeTrailingPathDelimiter(BaseDir) + BranchDirName(Branch);
  if DirectoryExists(Path) then
  begin
    Err := 'worktree_create: ' + Path + ' exists but is not the worktree for ' +
           Branch + ' -- remove it or pick another branch name';
    Path := '';
    Exit;
  end;
  BranchExists := Git(RepoRoot, 'rev-parse --verify --quiet ' + Q('refs/heads/' + Branch), Out_) = 0;
  if BranchExists then
    Args := 'worktree add ' + Q(Path) + ' ' + Q(Branch)
  else
  begin
    Args := 'worktree add -b ' + Q(Branch) + ' ' + Q(Path);
    if Base <> '' then Args := Args + ' ' + Q(Base);
  end;
  if Git(RepoRoot, Args, Out_) <> 0 then
  begin
    Err := 'worktree_create: git failed: ' + Out_;
    Path := '';
    Exit;
  end;
  LogInfo('worktree: created %s for branch %s', [Path, Branch]);
  Result := True;
end;

function WorktreeList(const RepoRoot: string; out Text, Err: string): Boolean;
var
  Out_, Line, CurPath, CurHead, CurBranch: string;
  L: TStringList;
  i: Integer;
  procedure Flush;
  begin
    if CurPath = '' then Exit;
    if CurBranch = '' then CurBranch := '(detached)';
    Text := Text + CurPath + '  ' + CurBranch + '  ' + Copy(CurHead, 1, 7) + sLineBreak;
    CurPath := ''; CurHead := ''; CurBranch := '';
  end;
begin
  Text := '';
  Err := '';
  Result := False;
  if Git(RepoRoot, 'worktree list --porcelain', Out_) <> 0 then
  begin
    Err := 'worktree_list: git failed: ' + Out_;
    Exit;
  end;
  L := TStringList.Create;
  try
    L.Text := Out_;
    CurPath := ''; CurHead := ''; CurBranch := '';
    for i := 0 to L.Count - 1 do
    begin
      Line := Trim(L[i]);
      if Copy(Line, 1, 9) = 'worktree ' then
      begin
        Flush;
        CurPath := Trim(Copy(Line, 10, MaxInt));
      end
      else if Copy(Line, 1, 5) = 'HEAD ' then CurHead := Trim(Copy(Line, 6, MaxInt))
      else if Copy(Line, 1, 7) = 'branch ' then
      begin
        CurBranch := Trim(Copy(Line, 8, MaxInt));
        if Copy(CurBranch, 1, 11) = 'refs/heads/' then Delete(CurBranch, 1, 11);
      end;
    end;
    Flush;
  finally
    L.Free;
  end;
  Text := TrimRight(Text);
  Result := True;
end;

function WorktreeDirty(const Path: string): Boolean;
var
  Out_: string;
begin
  if not DirectoryExists(Path) then Exit(False);
  Result := (Git(Path, 'status --porcelain', Out_) = 0) and (Out_ <> '');
end;

function WorktreeRemove(const RepoRoot, Path: string; Force: Boolean;
                        out Err: string): Boolean;
var
  Out_, P, Args: string;
begin
  Result := False;
  Err := '';
  P := ExcludeTrailingPathDelimiter(ExpandFileName(Path));
  if (P = '') or (P = ExcludeTrailingPathDelimiter(ExpandFileName(RepoRoot))) then
  begin
    Err := 'worktree_remove: refusing to remove the main checkout';
    Exit;
  end;
  if not DirectoryExists(P) then
  begin
    { Stale registration (directory already gone): prune it. }
    Git(RepoRoot, 'worktree prune', Out_);
    Err := 'worktree_remove: no such directory: ' + P + ' (pruned stale entries)';
    Exit;
  end;
  if (not Force) and WorktreeDirty(P) then
  begin
    Err := 'worktree_remove: ' + P + ' has uncommitted changes. Commit or ' +
           'stash them, or pass force:true to discard them.';
    Exit;
  end;
  Args := 'worktree remove ';
  if Force then Args := Args + '--force ';
  Args := Args + Q(P);
  if Git(RepoRoot, Args, Out_) <> 0 then
  begin
    Err := 'worktree_remove: git failed: ' + Out_;
    Exit;
  end;
  LogInfo('worktree: removed %s', [P]);
  Result := True;
end;

function ConfiguredWorktreeDir: string;
var
  Cfg: TConfig;
begin
  Result := '';
  Cfg := LoadEffectiveConfig;
  if Cfg = nil then Exit;
  try
    Result := Cfg.Worktree.Directory;
  finally
    Cfg.Free;
  end;
end;

function EnsureWorktree(const Branch: string; out Path, Err: string): Boolean;
var
  Root: string;
begin
  Path := '';
  if not GitRepoRoot(CurrentWorkspace, Root) then
  begin
    Err := 'worktree: the workspace ' + CurrentWorkspace + ' is not inside a git repository';
    Exit(False);
  end;
  Result := WorktreeCreate(Root, ConfiguredWorktreeDir, Branch, '', Path, Err);
end;

{ ---------------------------------------------------------- tools }

function ArgStr(const ArgsJSON, Field: string): string;
var
  Obj: TJsonObject;
begin
  Result := '';
  try
    Obj := TJsonObject.Parse(ArgsJSON);
  except
    Obj := nil;
  end;
  if Obj = nil then Exit;
  try
    Result := Obj.GetStr(Field, '');
  finally
    Obj.Free;
  end;
end;

function ArgBool(const ArgsJSON, Field: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
  except
    Obj := nil;
  end;
  if Obj = nil then Exit;
  try
    Result := Obj.GetBool(Field, False);
  finally
    Obj.Free;
  end;
end;

function RepoOrErr(out Root, ErrMsg: string): Boolean;
begin
  Result := GitRepoRoot(CurrentWorkspace, Root);
  if not Result then
    ErrMsg := 'the workspace ' + CurrentWorkspace + ' is not inside a git repository';
end;

function Tool_WorktreeCreate(const ArgsJSON: string; out ErrMsg: string): string;
var
  Root, Branch, Base, Path, Err: string;
begin
  Result := '';
  ErrMsg := '';
  Branch := Trim(ArgStr(ArgsJSON, 'branch'));
  Base := Trim(ArgStr(ArgsJSON, 'base'));
  if Branch = '' then begin ErrMsg := 'worktree_create: branch required'; Exit; end;
  if not RepoOrErr(Root, ErrMsg) then Exit;
  if not WorktreeCreate(Root, ConfiguredWorktreeDir, Branch, Base, Path, Err) then
  begin
    ErrMsg := Err;
    Exit;
  end;
  Result := 'worktree ready: ' + Path + sLineBreak +
            'branch: ' + Branch + sLineBreak +
            'Use it as the cwd for shell_exec, or spawn a subagent with worktree:"' + Branch + '".';
end;

function Tool_WorktreeList(const ArgsJSON: string; out ErrMsg: string): string;
var
  Root, Text, Err: string;
begin
  Result := '';
  ErrMsg := '';
  if not RepoOrErr(Root, ErrMsg) then Exit;
  if not WorktreeList(Root, Text, Err) then
  begin
    ErrMsg := Err;
    Exit;
  end;
  Result := Text;
end;

function Tool_WorktreeRemove(const ArgsJSON: string; out ErrMsg: string): string;
var
  Root, Path, Err: string;
begin
  Result := '';
  ErrMsg := '';
  Path := Trim(ArgStr(ArgsJSON, 'path'));
  if Path = '' then begin ErrMsg := 'worktree_remove: path required'; Exit; end;
  if not RepoOrErr(Root, ErrMsg) then Exit;
  if not WorktreeRemove(Root, Path, ArgBool(ArgsJSON, 'force'), Err) then
  begin
    ErrMsg := Err;
    Exit;
  end;
  Result := 'removed worktree ' + Path;
end;

procedure RegisterWorktreeTools(R: TToolRegistry);
var
  T: TTool;
begin
  if R = nil then Exit;

  FillChar(T, SizeOf(T), 0);
  T.Name := 'worktree_create';
  T.Description :=
    'Create (or find) a git worktree for a branch: a second checkout of the ' +
    'current repository in its own directory, sharing history. Use one per ' +
    'parallel task so edits do not collide. Returns the directory; pass it ' +
    'as cwd to shell_exec, or give spawn / spawn_background worktree:"<branch>" ' +
    'to run a subagent inside it. A new branch starts from base (default HEAD).';
  T.Schema :=
    '{"type":"object","properties":{' +
    '"branch":{"type":"string","description":"Branch to check out (created if missing)."},' +
    '"base":{"type":"string","description":"Start point for a new branch, e.g. main. Default HEAD."}},' +
    '"required":["branch"]}';
  T.Handler  := Tool_WorktreeCreate;
  T.IsCore   := False;
  T.Category := tcMutating;
  R.Register(T);

  FillChar(T, SizeOf(T), 0);
  T.Name := 'worktree_list';
  T.Description := 'List the git worktrees of the current repository: path, branch, head.';
  T.Schema := '{"type":"object","properties":{}}';
  T.Handler  := Tool_WorktreeList;
  T.IsCore   := False;
  T.Category := tcReadOnly;
  R.Register(T);

  FillChar(T, SizeOf(T), 0);
  T.Name := 'worktree_remove';
  T.Description :=
    'Remove a git worktree directory. Refuses when it has uncommitted changes ' +
    'unless force is true (which discards them). The branch is kept.';
  T.Schema :=
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"The worktree directory, as worktree_create / worktree_list returned it."},' +
    '"force":{"type":"boolean","description":"Discard uncommitted changes. Default false."}},' +
    '"required":["path"]}';
  T.Handler  := Tool_WorktreeRemove;
  T.IsCore   := False;
  T.Category := tcMutating;
  R.Register(T);
end;

end.
