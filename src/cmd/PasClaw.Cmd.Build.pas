unit PasClaw.Cmd.Build;
(*
  PasClaw.Cmd.Build - one-shot multi-iteration build runs with an
  optional workspace.zip handshake for shipping PASCLAW_HOME state
  between ephemeral compute environments (Replicate cogs, k8s Jobs,
  GitHub Actions runners, etc.).

  This is a thin orchestration layer over `pasclaw agent`. The
  agent already supports multi-turn tool-using loops via
  --max-iterations; build just gives it a friendlier surface with
  saner defaults for unattended runs (max-iters = 50, quiet output)
  and adds two workspace-zip flags so the entire $PASCLAW_HOME
  (memory, sessions, kb, checkpoints, skills, scars + the project
  files the model just wrote) can round-trip through cloud storage.

  Usage:

    pasclaw build -d "<task>"
                  [--max-iters N]                (default 50)
                  [--workspace-in <zip>]         optional, unpacked
                                                 into PASCLAW_HOME
                                                 before the run
                  [--workspace-out <zip>]        optional, written
                                                 after the run
                  [--cwd <dir>]                  cwd for fs_write
                  [--home <dir>]                 override PASCLAW_HOME
                                                 (defaults to env or a
                                                 fresh tempdir)
                  [--keep-home]                  do not delete the
                                                 tempdir on exit;
                                                 useful for local
                                                 debugging
                  ... forwarded agent flags (--provider, --model,
                       --max-tokens, --thinking, --session, --mode,
                       --profile, ...)

  Output: the model's final reply text goes to stdout (same as
  `pasclaw agent -q`), so callers piping through subprocess.run can
  capture it verbatim. The workspace.zip (when --workspace-out is
  set) is written to disk; size logged to stderr.

  The handshake protocol:

    in_zip  -> ExtractZipToDir($home)
    cwd     -> SetCurrentDir(--cwd or $home/workspace)
    agent   -> Cmd_Agent_Run with forwarded argv
    out_zip -> PackDirToZip($home -> --workspace-out)

  $home contents are walked verbatim (no exclusions beyond the
  ExcludeNames denylist below) so logs / tmp / kb-files all ship.
  The denylist hides only zip-build noise: the .git dir of any
  surrounding repo (the operator probably doesn't want to ship
  that), and the per-session ephemeral lockfiles SQLite leaves
  behind.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

function Cmd_Build_Run(const Argv: array of string): Integer;

const
  { 4 GiB hard cap on the input zip. Replicate's container limits and
    network timeouts are the real bound; the cap is here so a runaway
    operator who passes a wrong file fails fast instead of OOM'ing
    the unzip. Operators with genuine multi-gig workspaces should
    split by skill or session. }
  PASCLAW_WORKSPACE_ZIP_CAP = Int64(4) * 1024 * 1024 * 1024;

  { Default iteration budget for `pasclaw build`. agent's default is
    8 (interactive sessions correct themselves quickly); build is
    unattended and may need more headroom to finish a feature. }
  PASCLAW_BUILD_DEFAULT_MAX_ITERS = 50;

implementation

uses
  SysUtils, Classes,
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Utils,
  PasClaw.Skills.Zip,
  PasClaw.Cmd.Agent;

{$IFDEF UNIX}
{ libc setenv is POSIX-portable across glibc / musl / macOS / BSD --
  FPC's RTL doesn't expose it (only the env-modification helpers in
  the unitsrc/3.2.2 tree's UnixUtil which aren't packaged on every
  distro). Declare it directly. }
function libc_setenv(const Name, Value: PAnsiChar; Overwrite: Integer): Integer;
  cdecl; external 'c' name 'setenv';
{$ENDIF}

procedure SetEnv(const Name, Value: string);
begin
  {$IFDEF UNIX}
  libc_setenv(PAnsiChar(AnsiString(Name)), PAnsiChar(AnsiString(Value)), 1);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows.SetEnvironmentVariable(PChar(Name), PChar(Value));
  {$ENDIF}
end;

type
  TBuildArgs = record
    Description:   string;
    MaxIters:      Integer;
    WorkspaceIn:   string;
    WorkspaceOut:  string;
    Cwd:           string;
    HomeOverride:  string;
    KeepHome:      Boolean;
    HelpRequested: Boolean;
    Forwarded:     TStringList;  { remaining flags handed to Cmd_Agent_Run }
  end;

procedure InitArgs(out A: TBuildArgs);
begin
  A.Description   := '';
  A.MaxIters      := PASCLAW_BUILD_DEFAULT_MAX_ITERS;
  A.WorkspaceIn   := '';
  A.WorkspaceOut  := '';
  A.Cwd           := '';
  A.HomeOverride  := '';
  A.KeepHome      := False;
  A.HelpRequested := False;
  A.Forwarded     := TStringList.Create;
end;

procedure PrintHelp;
begin
  PrintLn('Usage: pasclaw build -d "<task>" [flags] [agent flags]');
  PrintLn;
  PrintLn('One-shot multi-iteration agent run, designed for unattended');
  PrintLn('use in ephemeral compute (Replicate cog, CI runners, etc.).');
  PrintLn('Optionally round-trips $PASCLAW_HOME via two zip handshakes');
  PrintLn('so the agent''s memory / KB / checkpoints / project files');
  PrintLn('survive between calls on different hosts.');
  PrintLn;
  PrintLn('Build flags:');
  PrintLn('  -d, --describe <text>      The task to perform (REQUIRED).');
  PrintLn('  --max-iters N              Iteration budget (default 50).');
  PrintLn('  --workspace-in <zip>       Unzip this into PASCLAW_HOME first.');
  PrintLn('  --workspace-out <zip>      Zip PASCLAW_HOME here after the run.');
  PrintLn('  --cwd <dir>                cwd for fs_write (default: ');
  PrintLn('                             $PASCLAW_HOME/workspace).');
  PrintLn('  --home <dir>               Override PASCLAW_HOME (default: env');
  PrintLn('                             or a fresh tempdir).');
  PrintLn('  --keep-home                Don''t delete the tempdir on exit.');
  PrintLn;
  PrintLn('Agent flags forwarded as-is:');
  PrintLn('  --provider, --model, --max-tokens, --thinking,');
  PrintLn('  --session, --profile, --mode {plan|build}, --no-tools,');
  PrintLn('  --no-mcp, --no-hashline, --system <prompt>, ...');
  PrintLn;
  PrintLn('Output:');
  PrintLn('  stdout: the model''s final reply (same as `pasclaw agent -q`).');
  PrintLn('  stderr: progress + workspace.zip size when applicable.');
  PrintLn;
  PrintLn('Example:');
  PrintLn('  pasclaw build -d "add a --version flag to the CLI" \');
  PrintLn('    --max-iters 30 \');
  PrintLn('    --workspace-in /tmp/prev.zip \');
  PrintLn('    --workspace-out /tmp/next.zip \');
  PrintLn('    --provider openai --model gpt-4o');
end;

function ParseArgs(const Argv: array of string;
                   var A: TBuildArgs;
                   out ErrMsg: string): Boolean;
var
  i: Integer;
  Token: string;
begin
  Result := False;
  ErrMsg := '';
  i := Low(Argv);
  while i <= High(Argv) do
  begin
    Token := Argv[i];
    if (Token = '-h') or (Token = '--help') then
    begin
      A.HelpRequested := True;
      Exit(True);
    end
    else if (Token = '-d') or (Token = '--describe') or (Token = '-m') then
    begin
      { -m is accepted as an alias for -d / --describe so scripts
        already using the agent's syntax keep working. }
      if i = High(Argv) then
      begin
        ErrMsg := Token + ' needs a value';
        Exit;
      end;
      Inc(i);
      A.Description := Argv[i];
    end
    else if Token = '--max-iters' then
    begin
      if i = High(Argv) then begin ErrMsg := '--max-iters needs a value'; Exit; end;
      Inc(i);
      A.MaxIters := StrToIntDef(Argv[i], A.MaxIters);
      if A.MaxIters <= 0 then
      begin
        ErrMsg := '--max-iters must be positive (got ' + Argv[i] + ')';
        Exit;
      end;
    end
    else if Token = '--workspace-in' then
    begin
      if i = High(Argv) then begin ErrMsg := '--workspace-in needs a path'; Exit; end;
      Inc(i); A.WorkspaceIn := Argv[i];
    end
    else if Token = '--workspace-out' then
    begin
      if i = High(Argv) then begin ErrMsg := '--workspace-out needs a path'; Exit; end;
      Inc(i); A.WorkspaceOut := Argv[i];
    end
    else if Token = '--cwd' then
    begin
      if i = High(Argv) then begin ErrMsg := '--cwd needs a path'; Exit; end;
      Inc(i); A.Cwd := Argv[i];
    end
    else if Token = '--home' then
    begin
      if i = High(Argv) then begin ErrMsg := '--home needs a path'; Exit; end;
      Inc(i); A.HomeOverride := Argv[i];
    end
    else if Token = '--keep-home' then
    begin
      A.KeepHome := True;
    end
    else
    begin
      { Everything we don't recognise is forwarded to `pasclaw agent`
        verbatim, including any value that follows. Agent's argv
        parser handles its own validation. }
      A.Forwarded.Add(Token);
    end;
    Inc(i);
  end;

  if A.Description = '' then
  begin
    ErrMsg := '-d / --describe is required (see -h for usage)';
    Exit;
  end;

  Result := True;
end;

function ResolveHome(const A: TBuildArgs; out IsTemp: Boolean): string;
{ Pick the PASCLAW_HOME we'll run under.

   Priority:
    1. --home <dir>                        (operator override)
    2. existing PASCLAW_HOME env var       (cog already sets one)
    3. fresh tempdir                       (default; cleaned on exit
                                            unless --keep-home) }
var
  Env: string;
begin
  IsTemp := False;
  if A.HomeOverride <> '' then
  begin
    Result := A.HomeOverride;
    Exit;
  end;
  Env := GetEnvironmentVariable('PASCLAW_HOME');
  if Env <> '' then
  begin
    Result := Env;
    Exit;
  end;
  Result := JoinPath(GetTempDir(False),
                     'pasclaw_build_' + IntToStr(GetProcessID) + '_' +
                     IntToStr(Random(MaxInt)));
  IsTemp := True;
end;

procedure RemoveTree(const Path: string);
{ Best-effort rm -rf. Survives transient lock failures by ignoring
  errors -- the OS reclaims the tempdir on next boot if we miss
  anything. }
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
        RemoveTree(Child)
      else
        DeleteFile(Child);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(Path);
end;

function GetFileSize(const Path: string): Int64;
var
  SR: TSearchRec;
begin
  Result := -1;
  if FindFirst(Path, faAnyFile, SR) = 0 then
  begin
    Result := SR.Size;
    FindClose(SR);
  end;
end;

function BuildForwardedArgv(const A: TBuildArgs;
                            out Argv: TStringList): Boolean;
{ Construct the argv pasclaw agent will see. Always inject -q
  (machine-friendly stdout), -m (the description), and
  --max-iterations (the operator's choice or our default 50). Then
  append whatever flags survived our parser. }
begin
  Result := True;
  Argv := TStringList.Create;
  Argv.Add('-q');
  Argv.Add('-m');
  Argv.Add(A.Description);
  Argv.Add('--max-iterations');
  Argv.Add(IntToStr(A.MaxIters));
  Argv.AddStrings(A.Forwarded);
end;

function ToDynArray(L: TStringList): TArray<string>;
var
  i: Integer;
begin
  SetLength(Result, L.Count);
  for i := 0 to L.Count - 1 do Result[i] := L[i];
end;

function Cmd_Build_Run(const Argv: array of string): Integer;
const
  ExcludeFromZip: array[0..3] of string = (
    '.git',          { surrounding repo metadata if /workspace is a clone }
    '.DS_Store',     { macOS finder noise }
    'Thumbs.db',     { Windows explorer noise }
    'kb.db-journal'  { SQLite WAL/journal -- transient, regenerated }
  );
var
  A: TBuildArgs;
  ErrMsg, Home, Cwd, SavedHomeEnv, SavedCwd: string;
  AgentArgv: TStringList;
  Argv_: TArray<string>;
  HomeIsTemp: Boolean;
  Bytes: Int64;
  Rc: Integer;
begin
  Result := 1;
  Randomize;
  InitArgs(A);
  try
    if not ParseArgs(Argv, A, ErrMsg) then
    begin
      PrintErr('build: ' + ErrMsg);
      Exit(2);
    end;
    if A.HelpRequested then
    begin
      PrintHelp;
      Exit(0);
    end;

    Home := ResolveHome(A, HomeIsTemp);
    if not ForceDirectories(Home) then
    begin
      PrintErr('build: cannot create home dir: ' + Home);
      Exit(1);
    end;

    SavedHomeEnv := GetEnvironmentVariable('PASCLAW_HOME');
    SavedCwd     := GetCurrentDir;
    SetEnv('PASCLAW_HOME', Home);
    LogInfo('build: PASCLAW_HOME=%s (temp=%s)',
            [Home, BoolToStr(HomeIsTemp, True)]);

    try
      { 1. Unzip in. }
      if A.WorkspaceIn <> '' then
      begin
        if not FileExists(A.WorkspaceIn) then
        begin
          PrintErr('build: workspace-in not found: ' + A.WorkspaceIn);
          Exit(1);
        end;
        Bytes := GetFileSize(A.WorkspaceIn);
        if Bytes > PASCLAW_WORKSPACE_ZIP_CAP then
        begin
          PrintErr(Format('build: workspace-in is %d bytes (> %d cap); ' +
                          'split by session or skill',
                          [Bytes, PASCLAW_WORKSPACE_ZIP_CAP]));
          Exit(1);
        end;
        LogInfo('build: unpacking %s (%d bytes) -> %s',
                [A.WorkspaceIn, Bytes, Home]);
        if not ExtractZipToDir(A.WorkspaceIn, Home, ErrMsg) then
        begin
          PrintErr('build: unzip failed: ' + ErrMsg);
          Exit(1);
        end;
      end;

      { 2. cwd. }
      Cwd := A.Cwd;
      if Cwd = '' then
        Cwd := JoinPath(Home, 'workspace');
      if not ForceDirectories(Cwd) then
      begin
        PrintErr('build: cannot create cwd: ' + Cwd);
        Exit(1);
      end;
      if not SetCurrentDir(Cwd) then
      begin
        PrintErr('build: SetCurrentDir failed: ' + Cwd);
        Exit(1);
      end;
      LogInfo('build: cwd=%s', [Cwd]);

      { 3. Run the agent. Its stdout becomes our stdout under -q --
        Replicate (and any subprocess.run caller) captures that. }
      if not BuildForwardedArgv(A, AgentArgv) then
      begin
        PrintErr('build: failed to build agent argv');
        Exit(1);
      end;
      try
        Argv_ := ToDynArray(AgentArgv);
        Rc := Cmd_Agent_Run(Argv_);
      finally
        AgentArgv.Free;
      end;
      if Rc <> 0 then
        LogWarn('build: agent exited with status %d', [Rc]);

      { 4. Zip out. Failure to pack is logged but doesn't override
        the agent's exit code -- the operator can still inspect
        --home for state if --keep-home was set. }
      if A.WorkspaceOut <> '' then
      begin
        SetCurrentDir(SavedCwd);
        LogInfo('build: zipping %s -> %s', [Home, A.WorkspaceOut]);
        if not PackDirToZip(Home, A.WorkspaceOut, ExcludeFromZip, ErrMsg) then
        begin
          PrintErr('build: zip failed: ' + ErrMsg);
          if Rc = 0 then Rc := 1;
        end
        else
        begin
          Bytes := GetFileSize(A.WorkspaceOut);
          LogInfo('build: wrote workspace.zip (%d bytes)', [Bytes]);
        end;
      end;

      Result := Rc;
    finally
      SetCurrentDir(SavedCwd);
      SetEnv('PASCLAW_HOME', SavedHomeEnv);
      if HomeIsTemp and (not A.KeepHome) then
        RemoveTree(Home);
    end;
  finally
    A.Forwarded.Free;
  end;
end;

end.
