(*
  PasClaw.Agent.ProjectFacts -- deterministic "## Project" system-prompt
  section: what stack is this, how do I build it, how do I test it, what
  git branch am I on.

  Why: a coding agent dropped into a repo burns its first 5-10 tool calls
  rediscovering facts the filesystem states outright (the observed
  pasclaw.dev-build transcript opened with a wall of fs_list / probe
  calls). Claude Code ships git state in every session env for the same
  reason. With the commands in the prompt, Rule 3's "verify changes" can
  point at THE actual command instead of hand-waving.

  Design constraints:
    * PURE FILE READS -- no LLM call, no process exec. `pasclaw runbook`
      does the LLM-authored deep version; this is the zero-cost floor
      that works on every turn, offline, on both compilers (no TProcess).
      Git branch comes from .git/HEAD; working-tree state is the model's
      to query (`git status`) -- the block says so.
    * BOUNDED -- small fixed probe list, first ~40 Makefile targets, one
      package.json parse. Reading these per prompt build is microseconds.
    * DEFERENT -- BuildSystemPrompt skips this section entirely when the
      project has an AGENTS.md (the operator-authored doc wins; this is
      the floor for repos that have nothing).
*)
unit PasClaw.Agent.ProjectFacts;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

{ The "## Project" section for Dir, or '' when nothing recognisable is
  there (an empty gateway workspace, a scratch dir). Dir is normally
  CurrentWorkspace -- the directory relative tool paths resolve to. }
function BuildProjectFactsSection(const Dir: string): string;

implementation

uses
  SysUtils, Classes,
  PasClaw.JSON;

function ReadSmallFile(const Path: string; MaxBytes: Integer): string;
var
  FS: TFileStream;
  Bytes: TBytes;
  N: Integer;
begin
  Result := '';
  if not FileExists(Path) then Exit;
  try
    FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
    try
      N := FS.Size;
      if N > MaxBytes then N := MaxBytes;
      SetLength(Bytes, N);
      if N > 0 then FS.ReadBuffer(Bytes[0], N);
      Result := TEncoding.UTF8.GetString(Bytes);
    finally
      FS.Free;
    end;
  except
    Result := '';
  end;
end;

function MakefileTargets(const Body: string; out HasTest, HasBuildish: Boolean): string;
{ First ~8 plain target names from a Makefile ("name:" at column 0,
  skipping dot-targets, pattern rules and variable lines). Enough for the
  model to see the vocabulary; the file itself is one read_file away. }
var
  Lines: TStringList;
  i, Shown: Integer;
  L, Name: string;
  P: Integer;
begin
  Result := '';
  HasTest := False;
  HasBuildish := False;
  Shown := 0;
  Lines := TStringList.Create;
  try
    Lines.Text := Body;
    for i := 0 to Lines.Count - 1 do
    begin
      L := Lines[i];
      if (L = '') or (L[1] = #9) or (L[1] = ' ') or (L[1] = '.') or (L[1] = '#') then
        Continue;
      P := Pos(':', L);
      if P < 2 then Continue;
      { Variable assignments, not rules: "CC := gcc" (the '=' follows the
        colon) and "CC=..." with an embedded colon later. }
      if (P < Length(L)) and (L[P + 1] = '=') then Continue;
      if Pos('=', Copy(L, 1, P)) > 0 then Continue;
      Name := Trim(Copy(L, 1, P - 1));
      if (Name = '') or (Pos(' ', Name) > 0) or (Pos('%', Name) > 0)
         or (Pos('$', Name) > 0) then Continue;
      if SameText(Name, 'test') or (Pos('test', LowerCase(Name)) = 1) then
        HasTest := True;
      if SameText(Name, 'all') or SameText(Name, 'build') then
        HasBuildish := True;
      if Shown < 8 then
      begin
        if Result <> '' then Result := Result + ', ';
        Result := Result + Name;
        Inc(Shown);
      end;
    end;
  finally
    Lines.Free;
  end;
end;

function PackageJsonScripts(const Body: string): string;
{ "name: command" lines for up to 6 package.json scripts, build/test/
  start/dev first. }
const
  Preferred: array[0..3] of string = ('build', 'test', 'start', 'dev');
var
  Root, Scripts: TJsonObject;
  i, Shown: Integer;
  K, V: string;
begin
  Result := '';
  Root := nil;
  try
    Root := TJsonObject.Parse(Body);
  except
    Root := nil;
  end;
  if Root = nil then Exit;
  try
    Scripts := Root.ChildObject('scripts');
    if Scripts = nil then Exit;
    try
      Shown := 0;
      for i := 0 to High(Preferred) do
      begin
        V := Scripts.GetStr(Preferred[i], '');
        if V = '' then Continue;
        K := 'npm run ' + Preferred[i];
        if Preferred[i] = 'test' then K := 'npm test';
        if Result <> '' then Result := Result + '; ';
        Result := Result + K;
        Inc(Shown);
        if Shown >= 6 then Break;
      end;
    finally
      Scripts.Free;
    end;
  finally
    Root.Free;
  end;
end;

function GitBranch(const Dir: string): string;
{ Branch name from .git/HEAD ("ref: refs/heads/<branch>"); a detached
  HEAD (bare hash) is reported as such. Pure read -- working-tree state
  is deliberately NOT computed here (that would need exec); the section
  tells the model to run `git status` itself. }
var
  Head: string;
begin
  Result := '';
  Head := Trim(ReadSmallFile(Dir + PathDelim + '.git' + PathDelim + 'HEAD', 512));
  if Head = '' then Exit;
  if Copy(Head, 1, 16) = 'ref: refs/heads/' then
    Result := Copy(Head, 17, MaxInt)
  else
    Result := '(detached: ' + Copy(Head, 1, 12) + ')';
end;

function HasAny(const Dir: string; const Names: array of string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(Names) do
    if FileExists(Dir + PathDelim + Names[i]) then Exit(True);
end;

function HasExt(const Dir, Ext: string): Boolean;
var
  SR: TSearchRec;
begin
  Result := FindFirst(Dir + PathDelim + '*' + Ext, faAnyFile, SR) = 0;
  FindClose(SR);
end;

function BuildProjectFactsSection(const Dir: string): string;
var
  Stack, BuildCmd, TestCmd, Targets, Scripts, Branch: string;
  MkBody: string;
  HasTest, HasBuildish: Boolean;

  procedure AddStack(const S: string);
  begin
    if Stack <> '' then Stack := Stack + ', ';
    Stack := Stack + S;
  end;

begin
  Result := '';
  if (Dir = '') or (not DirectoryExists(Dir)) then Exit;
  Stack := ''; BuildCmd := ''; TestCmd := ''; Targets := ''; Scripts := '';

  MkBody := ReadSmallFile(Dir + PathDelim + 'Makefile', 128 * 1024);
  if MkBody <> '' then
  begin
    AddStack('Makefile');
    Targets := MakefileTargets(MkBody, HasTest, HasBuildish);
    if BuildCmd = '' then BuildCmd := 'make';
    if HasTest then TestCmd := 'make test';
  end;

  if FileExists(Dir + PathDelim + 'package.json') then
  begin
    AddStack('Node (package.json)');
    Scripts := PackageJsonScripts(ReadSmallFile(Dir + PathDelim + 'package.json', 64 * 1024));
    if (BuildCmd = '') and (Pos('npm run build', Scripts) > 0) then BuildCmd := 'npm run build';
    if (TestCmd = '') and (Pos('npm test', Scripts) > 0) then TestCmd := 'npm test';
  end;

  if FileExists(Dir + PathDelim + 'Cargo.toml') then
  begin
    AddStack('Rust (Cargo.toml)');
    if BuildCmd = '' then BuildCmd := 'cargo build';
    if TestCmd = '' then TestCmd := 'cargo test';
  end;

  if FileExists(Dir + PathDelim + 'go.mod') then
  begin
    AddStack('Go (go.mod)');
    if BuildCmd = '' then BuildCmd := 'go build ./...';
    if TestCmd = '' then TestCmd := 'go test ./...';
  end;

  if HasExt(Dir, '.dpr') or HasExt(Dir, '.lpi') then
    AddStack('Pascal (FPC/Delphi project)');

  if HasAny(Dir, ['pyproject.toml', 'requirements.txt']) then
  begin
    AddStack('Python');
    if (TestCmd = '') and (HasAny(Dir, ['pytest.ini']) or
        DirectoryExists(Dir + PathDelim + 'tests')) then
      TestCmd := 'pytest';
  end;

  Branch := GitBranch(Dir);

  { Nothing recognisable -> no section (an empty workspace stays quiet). }
  if (Stack = '') and (Branch = '') then Exit;

  Result := '## Project' + sLineBreak;
  if Stack <> '' then
    Result := Result + 'Stack: ' + Stack + sLineBreak;
  if BuildCmd <> '' then
    Result := Result + 'Build: ' + BuildCmd + sLineBreak;
  if TestCmd <> '' then
    Result := Result + 'Test:  ' + TestCmd +
              '   <- run this to verify after code edits' + sLineBreak;
  if Targets <> '' then
    Result := Result + 'Make targets: ' + Targets + sLineBreak;
  if Scripts <> '' then
    Result := Result + 'npm scripts: ' + Scripts + sLineBreak;
  if Branch <> '' then
    Result := Result + 'Git branch: ' + Branch +
              ' (run `git status` for working-tree state)' + sLineBreak;
  Result := TrimRight(Result);
end;

end.
