unit PasClaw.Cmd.Plan;
(*
  PasClaw.Cmd.Plan - the `pasclaw plan` subcommand. Companion to
  `pasclaw build`: produces `workspace/PLAN.md` as a deliverable that
  the operator (or a follow-up `pasclaw build`) can consume.

  How it works
  ============

  This unit mirrors `pasclaw build`'s lifecycle (workspace.zip
  handshake + PASCLAW_HOME orchestration) and adds a planner-specific
  layer on top:

    1. Parse plan-specific args (mirrors Cmd.Build's argv surface).
    2. Resolve PASCLAW_HOME + unzip the workspace-in if provided.
    3. If <home>/workspace/PLAN.md exists, read its body for incremental
       update (model gets the existing plan in its system prompt with a
       "revise / extend, don't replace" directive).
    4. Build a planner system-prompt addendum -- a strong directive that
       says "produce a structured plan; call plan_write once; end your
       turn."
    5. Forward to Cmd_Agent_Run with: -q -m <description>
       --mode plan --system <planner directive> --max-iterations N.
    6. The agent runs in pmPlan mode. Read-only tools (fs_read,
       fs_grep, memory_search, etc.) work normally; mutating tools are
       refused at dispatch. The dedicated `plan_write` tool
       (PasClaw.Tools.PlanWrite) is auto-registered when --mode plan is
       set; it's tcReadOnly-tagged so it passes the gate, but only
       writes the one plan-meta file.
    7. The model calls plan_write with the finalized markdown body;
       it lands at <home>/workspace/PLAN.md.
    8. Workspace-out zip (if requested) captures PLAN.md alongside the
       rest of $PASCLAW_HOME, identical to `pasclaw build`.

  Why mirror build's lifecycle rather than call into it
  =====================================================

  Cmd_Build_Run unpacks workspace-in early, runs the agent, then
  packs workspace-out. Cmd.Plan needs to peek at PLAN.md BEFORE the
  agent runs (for the incremental-update directive) and AFTER (to
  verify the model wrote it), which means we need our own lifecycle
  with hooks. Helpers (ResolveHome, SetEnv, etc.) are duplicated as
  internals rather than exposed from Cmd.Build's interface --
  Cmd.Build is heavily used and its public surface is best left
  unchanged.

  Usage
  -----

    pasclaw plan -d "<task>"
                 [--max-iters N]                (default 12)
                 [--workspace-in <zip>]         optional
                 [--workspace-out <zip>]        optional
                 [--cwd <dir>]
                 [--home <dir>]
                 [--keep-home]
                 ... forwarded agent flags (--provider, --model, ...)
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

function Cmd_Plan_Run(const Argv: array of string): Integer;

const
  { Default iteration budget for `pasclaw plan`. Lower than build's 50
    -- planning involves reading code and producing one document; it
    shouldn't take dozens of tool-loop rounds. Calibrated so a
    Sonnet/Opus run on a medium-sized codebase has headroom for ~5
    fs_read + ~3 fs_grep + 1 plan_write before hitting the cap. }
  PASCLAW_PLAN_DEFAULT_MAX_ITERS = 12;

implementation

uses
  SysUtils, Classes,
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Utils,
  PasClaw.Skills.Zip,
  PasClaw.Cmd.Agent,
  PasClaw.Cmd.Build,         { for PASCLAW_WORKSPACE_ZIP_CAP + MakeUniqueTempDir }
  PasClaw.Tools.PlanWrite;

{$IFDEF UNIX}
function libc_setenv(const Name, Value: PAnsiChar; Overwrite: Integer): Integer;
  cdecl; external 'c' name 'setenv';
function libc_unsetenv(const Name: PAnsiChar): Integer;
  cdecl; external 'c' name 'unsetenv';
{$ENDIF}

procedure RemoveTree(const Path: string);
{ Best-effort rm -rf. Mirror of Cmd.Build.RemoveTree -- same SysUtils.
  qualification rationale (Windows unit shadowing). Local copy because
  Cmd.Build keeps it implementation-private. }
var
  SR: SysUtils.TSearchRec;
  Child: string;
begin
  if (Path = '') or (not SysUtils.DirectoryExists(Path)) then
  begin
    if SysUtils.FileExists(Path) then SysUtils.DeleteFile(Path);
    Exit;
  end;
  if SysUtils.FindFirst(JoinPath(Path, '*'),
                        faAnyFile or faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      Child := JoinPath(Path, SR.Name);
      if (SR.Attr and faDirectory) <> 0 then
        RemoveTree(Child)
      else
        SysUtils.DeleteFile(Child);
    until SysUtils.FindNext(SR) <> 0;
  finally
    SysUtils.FindClose(SR);
  end;
  SysUtils.RemoveDir(Path);
end;

function FileSizeOf(const Path: string): Int64;
{ Mirror of Cmd.Build.GetFileSize -- that function is implementation-
  private so we can't share it without expanding Cmd.Build's interface.
  Same code, local copy. }
var
  SR: SysUtils.TSearchRec;
begin
  Result := -1;
  if SysUtils.FindFirst(Path, faAnyFile, SR) = 0 then
  begin
    Result := SR.Size;
    SysUtils.FindClose(SR);
  end;
end;

procedure SetEnvVar(const Name, Value: string);
begin
  {$IFDEF UNIX}
  if Value = '' then
    libc_unsetenv(PAnsiChar(AnsiString(Name)))
  else
    libc_setenv(PAnsiChar(AnsiString(Name)),
                PAnsiChar(AnsiString(Value)), 1);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if Value = '' then
    Windows.SetEnvironmentVariable(PChar(Name), nil)
  else
    Windows.SetEnvironmentVariable(PChar(Name), PChar(Value));
  {$ENDIF}
end;

type
  TPlanArgs = record
    Description:   string;
    MaxIters:      Integer;
    WorkspaceIn:   string;
    WorkspaceOut:  string;
    Cwd:           string;
    HomeOverride:  string;
    KeepHome:      Boolean;
    HelpRequested: Boolean;
    Forwarded:     TStringList;
  end;

procedure InitArgs(out A: TPlanArgs);
begin
  A.Description   := '';
  A.MaxIters      := PASCLAW_PLAN_DEFAULT_MAX_ITERS;
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
  PrintLn('Usage: pasclaw plan -d "<task>" [flags] [agent flags]');
  PrintLn;
  PrintLn('Generate a structured plan as workspace/PLAN.md without');
  PrintLn('changing any project files. Runs the agent in plan mode');
  PrintLn('(read-only tool surface) with a planner directive that');
  PrintLn('produces a markdown document via the plan_write tool.');
  PrintLn;
  PrintLn('Plan structure: ## Goal, ## Files, ## Steps,');
  PrintLn('                ## Open questions, ## Risks');
  PrintLn;
  PrintLn('Plan flags:');
  PrintLn('  -d, --describe <text>      The task to plan (REQUIRED).');
  PrintLn('  --max-iters N              Iteration budget (default 12).');
  PrintLn('  --workspace-in <zip>       Unzip this into PASCLAW_HOME first.');
  PrintLn('  --workspace-out <zip>      Zip PASCLAW_HOME here after the run');
  PrintLn('                             (the zip carries PLAN.md).');
  PrintLn('  --cwd <dir>                cwd for tools (default:');
  PrintLn('                             $PASCLAW_HOME/workspace).');
  PrintLn('  --home <dir>               Override PASCLAW_HOME.');
  PrintLn('  --keep-home                Don''t delete the tempdir on exit.');
  PrintLn;
  PrintLn('Plan mode is forced; --mode is NOT forwarded (use `pasclaw');
  PrintLn('agent --mode plan` for an interactive plan session).');
  PrintLn;
  PrintLn('Output:');
  PrintLn('  <workspace>/PLAN.md  -- markdown plan written by the model.');
  PrintLn('  stdout               -- final agent reply (short confirmation).');
  PrintLn('  stderr               -- progress + workspace.zip size.');
end;

function ParseArgs(const Argv: array of string;
                   var A: TPlanArgs;
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
      if i = High(Argv) then begin ErrMsg := Token + ' needs a value'; Exit; end;
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
    else if (Token = '--mode') or (Token = '--plan') or (Token = '--build') then
    begin
      { plan forces --mode plan; refusing the flag here means an
        operator who passes --mode build by accident gets a clear
        error instead of silently switching the run to build mode. }
      ErrMsg := Token + ' is not allowed in `pasclaw plan` (mode is forced to plan)';
      Exit;
    end
    else
    begin
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

function ResolveHome(const A: TPlanArgs; out IsTemp: Boolean): string;
{ Resolution order matches Cmd.Build:
    1. --home <dir>                  (operator override)
    2. existing PASCLAW_HOME env var (cog already sets one)
    3. fresh tempdir                 (cleaned on exit unless --keep-home) }
var
  Env: string;
begin
  IsTemp := False;
  if A.HomeOverride <> '' then
    Exit(A.HomeOverride);
  Env := GetEnvironmentVariable('PASCLAW_HOME');
  if Env <> '' then
    Exit(Env);
  IsTemp := True;
  Result := MakeUniqueTempDir('pasclaw_plan');
end;

procedure CleanupTempHome(const Home: string);
begin
  try
    if DirectoryExists(Home) then
      RemoveTree(Home);
  except
    on E: Exception do
      LogWarn('plan: cleanup of tempdir failed: %s: %s',
              [E.ClassName, E.Message]);
  end;
end;

function ReadExistingPlanBody: string;
var
  Path: string;
begin
  Result := '';
  Path := ResolvePlanPath;
  if not FileExists(Path) then Exit;
  try
    Result := Trim(ReadFileText(Path));
  except
    on E: Exception do
    begin
      LogWarn('plan: existing PLAN.md unreadable (%s); generating fresh plan',
              [E.Message]);
      Result := '';
    end;
  end;
end;

const
  { The planner directive. Stuffed into --system so it lands at the
    end of the system prompt (BuildSystemPrompt appends UserSys last,
    so it gets the "most authoritative" slot ahead of model defaults
    and skills). Opinionated on structure so plans are comparable
    across runs and a follow-up `pasclaw build --goal` (Phase 3) can
    parse the Goal section cleanly. }
  PlanDirectiveHeader =
    'You are running under `pasclaw plan` -- your deliverable is a ' +
    'markdown plan, NOT actually doing the work. Read the codebase as ' +
    'needed (fs_read, fs_grep, memory_search), then SAVE the plan via ' +
    'the `plan_write` tool with the full markdown as the `content` ' +
    'argument. After plan_write returns, end your turn with a short ' +
    'confirmation -- do NOT restate the plan in your reply.' + sLineBreak + sLineBreak +
    'Plan structure (use these exact headings, in this order):' + sLineBreak +
    '  ## Goal' + sLineBreak +
    '    One paragraph: what success looks like. The first line should' + sLineBreak +
    '    be a single-sentence objective starting with a verb (so a' + sLineBreak +
    '    follow-up `pasclaw build --goal` can parse it cleanly).' + sLineBreak +
    '  ## Files' + sLineBreak +
    '    Bullet list of files that will change, one line each.' + sLineBreak +
    '  ## Steps' + sLineBreak +
    '    Numbered list of concrete actions, in order.' + sLineBreak +
    '  ## Open questions' + sLineBreak +
    '    Anything the operator needs to decide. Omit if none.' + sLineBreak +
    '  ## Risks' + sLineBreak +
    '    Things that could go wrong + mitigation. Omit if none.';

  PlanDirectiveFreshTail =
    sLineBreak + sLineBreak +
    'No existing PLAN.md was found -- write a fresh plan.';

  PlanDirectiveIncrementalTail =
    sLineBreak + sLineBreak +
    'An EXISTING PLAN.md is shown below. Your job is to REVISE / EXTEND ' +
    'it based on the new task description. Keep sections that still ' +
    'apply, drop what no longer fits, add what''s missing. Preserve the ' +
    'overall structure. Output the FULL revised plan via plan_write -- ' +
    'do not output a diff.' + sLineBreak + sLineBreak +
    '=== Existing plan ===' + sLineBreak;

function BuildPlannerDirective(const ExistingPlan: string): string;
begin
  Result := PlanDirectiveHeader;
  if Trim(ExistingPlan) = '' then
    Result := Result + PlanDirectiveFreshTail
  else
    Result := Result + PlanDirectiveIncrementalTail + ExistingPlan;
end;

function ToDynArray(L: TStringList): TArray<string>;
var
  i: Integer;
begin
  SetLength(Result, L.Count);
  for i := 0 to L.Count - 1 do Result[i] := L[i];
end;

function Cmd_Plan_Run(const Argv: array of string): Integer;
var
  A: TPlanArgs;
  ErrMsg, Home, Cwd, Directive, ExistingPlan, PlanPath: string;
  SavedHomeEnv: string;
  AgentArgv: TStringList;
  Argv_: TArray<string>;
  Rc: Integer;
  HomeIsTemp, PlanExisted: Boolean;
  Bytes, FinalSize: Int64;
  PreviousAge, FinalAge: Integer;
begin
  Result := 1;
  InitArgs(A);
  try
    if not ParseArgs(Argv, A, ErrMsg) then
    begin
      PrintErr('plan: ' + ErrMsg);
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
      PrintErr('plan: cannot create home dir: ' + Home);
      Exit(1);
    end;

    SavedHomeEnv := GetEnvironmentVariable('PASCLAW_HOME');
    SetEnvVar('PASCLAW_HOME', Home);
    LogInfo('plan: PASCLAW_HOME=%s (temp=%s)',
            [Home, BoolToStr(HomeIsTemp, True)]);

    try
      { 1. Unzip in. }
      if A.WorkspaceIn <> '' then
      begin
        if not SysUtils.FileExists(A.WorkspaceIn) then
        begin
          PrintErr('plan: workspace-in not found: ' + A.WorkspaceIn);
          Exit(1);
        end;
        Bytes := FileSizeOf(A.WorkspaceIn);
        if Bytes > PASCLAW_WORKSPACE_ZIP_CAP then
        begin
          PrintErr(Format('plan: workspace-in is %d bytes (> %d cap)',
                          [Bytes, PASCLAW_WORKSPACE_ZIP_CAP]));
          Exit(1);
        end;
        LogInfo('plan: unpacking %s (%d bytes) -> %s',
                [A.WorkspaceIn, Bytes, Home]);
        if not ExtractZipToDir(A.WorkspaceIn, Home, ErrMsg) then
        begin
          PrintErr('plan: unzip failed: ' + ErrMsg);
          Exit(1);
        end;
      end;

      { 2. cwd. }
      Cwd := A.Cwd;
      if Cwd = '' then
        Cwd := JoinPath(Home, 'workspace');
      if not ForceDirectories(Cwd) then
      begin
        PrintErr('plan: cannot create cwd: ' + Cwd);
        Exit(1);
      end;
      if not SetCurrentDir(Cwd) then
      begin
        PrintErr('plan: SetCurrentDir failed: ' + Cwd);
        Exit(1);
      end;
      LogInfo('plan: cwd=%s', [Cwd]);

      { 3. Read existing PLAN.md (if any) for incremental update.
        Snapshot its FileAge so we can detect post-run whether the
        model actually rewrote it. }
      ExistingPlan := ReadExistingPlanBody;
      PlanPath := ResolvePlanPath;
      PlanExisted := FileExists(PlanPath);
      PreviousAge := 0;
      if PlanExisted then
        PreviousAge := FileAge(PlanPath);

      Directive := BuildPlannerDirective(ExistingPlan);

      { 4. Run the agent in plan mode with the directive folded into
        --system. plan_write registers automatically because Cmd.Agent
        sees --mode plan and threads EnablePlanWrite=True into
        NewBuiltinRegistry. }
      AgentArgv := TStringList.Create;
      try
        AgentArgv.Add('-q');
        AgentArgv.Add('-m');
        AgentArgv.Add(A.Description);
        AgentArgv.Add('--mode');
        AgentArgv.Add('plan');
        AgentArgv.Add('--system');
        AgentArgv.Add(Directive);
        AgentArgv.Add('--max-iterations');
        AgentArgv.Add(IntToStr(A.MaxIters));
        AgentArgv.AddStrings(A.Forwarded);
        Argv_ := ToDynArray(AgentArgv);
        Rc := Cmd_Agent_Run(Argv_);
      finally
        AgentArgv.Free;
      end;
      if Rc <> 0 then
        LogWarn('plan: agent exited with status %d', [Rc]);

      { 5. Sanity check: did the model actually write PLAN.md? An empty
        run (model decided not to call plan_write) should surface as a
        failure rather than silently produce no artifact. }
      if not FileExists(PlanPath) then
      begin
        PrintErr('plan: model did not call plan_write -- no PLAN.md produced');
        Exit(1);
      end;
      FinalSize := FileSizeOf(PlanPath);
      FinalAge  := FileAge(PlanPath);
      if PlanExisted and (FinalAge = PreviousAge) then
      begin
        { FileAge unchanged -- the model didn't update PLAN.md.
          Surface as failure unless the agent itself reported a
          nonzero exit (in which case the user already sees the
          underlying error). }
        if Rc = 0 then
        begin
          PrintErr('plan: PLAN.md not updated -- model did not call plan_write');
          Exit(1);
        end;
      end;
      LogInfo('plan: PLAN.md at %s (%d bytes)', [PlanPath, FinalSize]);

      { 6. Zip out. PLAN.md is captured by the whole-home pack just
        like every other file under $PASCLAW_HOME. Exclusion list
        matches Cmd.Build's so the two commands produce zips with
        the same shape. }
      if A.WorkspaceOut <> '' then
      begin
        LogInfo('plan: packing %s -> %s', [Home, A.WorkspaceOut]);
        if not PackDirToZip(Home, A.WorkspaceOut,
                            ['.git', '.DS_Store', 'Thumbs.db', 'kb.db-journal'],
                            ErrMsg, '') then
          LogWarn('plan: zip-out failed: %s', [ErrMsg]);
      end;

      Result := Rc;
    finally
      SetEnvVar('PASCLAW_HOME', SavedHomeEnv);
      if HomeIsTemp and (not A.KeepHome) then
        CleanupTempHome(Home);
    end;
  finally
    A.Forwarded.Free;
  end;
end;

end.
