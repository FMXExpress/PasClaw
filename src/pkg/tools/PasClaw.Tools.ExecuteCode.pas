(*
  PasClaw.Tools.ExecuteCode -- execute_code tool. The model writes a
  multi-line bash or PowerShell script body; we materialise it to a
  temp file under $PASCLAW_HOME/tmp/, hand it to the right shell, and
  return the combined output + exit code.

  Why a new tool instead of letting shell_exec take multi-line input?
  Three reasons that keep showing up when you watch a session:

    1. Quote escaping. The model wants to write a for-loop or a
       heredoc; shell_exec wants a single command string. The model
       ends up nesting `bash -c "..."` with escaped quotes inside
       escaped quotes and the script eventually breaks on a stray
       backslash. Materialising the body to a temp file bypasses the
       whole problem -- the script is just the script.

    2. Cross-shell intent. shell_exec is /bin/sh on unix, cmd.exe on
       Windows. The model often wants PowerShell on Windows
       specifically (cmdlets, structured output) and that's awkward
       to express through a sh-prefixed wrapper. execute_code takes
       an explicit `lang` so the model picks bash or powershell and
       we route accordingly.

    3. Inference-round consolidation. Many "fan out then collect"
       patterns (list every *.pas file, grep each for a symbol,
       summarise the hits) take 1 + N + 1 tool calls under shell_exec
       because the model has to issue each grep separately to keep
       the inline command tractable. With execute_code the same
       work is one tool call -- the model writes a 5-line loop and
       reads the aggregated output back. On a 100-file repo that
       saves ~100 inference rounds.

  Safety: every check that gates shell_exec also gates execute_code.
  PasClaw.Tools.Sandbox.ShellAllowed runs against the script body
  (substring scan against the denylist; same rules as inline
  commands -- a `rm -rf /` in line 7 of a script body is just as
  bad as the same string in shell_exec's `command` arg). When
  sandbox.restrict_to_workspace is set, the script's cwd is pinned
  to the workspace, same as shell_exec, so relative paths can't
  escape the boundary.

  Output cap: same OutputCache truncation as every other tool.

  Borrowed conceptually from picoclaw's pkg/tools/exec.go execute_code
  (which targets Python). We diverge on language because the typical
  PasClaw operator already has bash or powershell on the box, no extra
  install -- and the inference-round-consolidation win lands regardless
  of script language.
*)
unit PasClaw.Tools.ExecuteCode;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

uses
  SysUtils, Classes,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

procedure RegisterExecuteCodeTool(R: TToolRegistry);

(* Resolve `auto` to the right host-default shell. Exposed so a test
   can pin the contract -- the dispatch table changes if we ever
   add fish or nu support and a silent change would either spawn
   the wrong shell or quietly fall back to bash on a non-bash host. *)
function ResolveExecuteCodeLang(const Requested: string): string;

(* Build the argv the chosen shell should be invoked with for a
   given script file. Returns the executable in the first element
   and any required flags in the rest -- e.g. PowerShell needs
   `-ExecutionPolicy Bypass -File <script>` so a stock Windows box
   doesn't refuse to run an unsigned script. Exposed so tests can
   pin the invocation contract without needing to spawn anything. *)
function BuildExecuteCodeArgv(const Lang, ScriptPath: string;
                              out Argv: TStringArray): Boolean;

(* Pick the PowerShell binary to spawn. Prefers `pwsh` (PowerShell
   7+, cross-platform via dotnet) when it's on PATH; falls back to
   `powershell` (Windows PowerShell 5.1, in-box on every supported
   Windows version) on Windows when pwsh isn't installed. On unix
   without pwsh returns `pwsh` anyway so the spawn fails with a
   clean "command not found" -- inventing a unix-side fallback
   would just delay the failure to a less actionable error.

   Exposed so a regression test can pin the lookup contract --
   Codex P2 on PR #199 caught the original implementation
   hardcoding pwsh and silently breaking on stock Windows. *)
function ResolvePowerShellExe: string;

(* True when Arg must be wrapped in `"..."` for `cmd /C` or `/bin/sh -c`
   not to mis-parse it. Bareword-safe tokens (no whitespace, no shell
   metacharacters) pass through unquoted. Exposed so a unit test can
   pin the regression for the "'\"powershell\"' is not recognized"
   cmd.exe bug without spawning anything. *)
function ArgvNeedsQuoting(const Arg: string): Boolean;

(* The tool handler itself. Exposed (rather than only registered)
   so a regression test can drive it without standing up a full
   agent + provider. Same calling convention as every other
   TToolHandler: ArgsJSON in, Result string out, ErrMsg out for
   failures. *)
function Tool_ExecuteCode(const ArgsJSON: string; out ErrMsg: string): string;

implementation

uses
  DateUtils,    { MilliSecondsBetween / EncodeDate -- the FPC+Delphi-portable
                  way to get a millisecond timestamp. GetTickCount64 is FPC
                  RTL only; Delphi dcc64 errors with E2003 unless we pull
                  in System.SysUtils.GetTickCount64 explicitly, which is
                  itself a Windows-only wrapper. MilliSecondsBetween skips
                  the platform mess. }
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Config,
  PasClaw.Platform,
  PasClaw.Utils,
  PasClaw.Tools.Sandbox,
  PasClaw.Tools.RPC,
  PasClaw.Shell.Backend;   { route the spawn through the active
                             shell backend so docker sessions
                             execute the script inside the
                             container rather than on the host }

type
  (* Per-registry execute_code handler. RegisterExecuteCodeTool
     creates one of these and registers its Execute method (a
     TToolHandlerObj) instead of the unit-level Tool_ExecuteCode
     function. That way each registry's execute_code carries a
     pointer to ITS registry -- when a subagent's filtered
     registry registers execute_code, the runner that hangs off
     it dispatches RPC callbacks to the SUBAGENT's registry, not
     the parent's full surface. Codex P1 on PR #206. *)
  TExecuteCodeRunner = class
  private
    FRegistry: TToolRegistry;
  public
    constructor Create(Registry: TToolRegistry);
    function Execute(const ArgsJSON: string; out ErrMsg: string): string;
  end;

var
  { Anchored here so the runners outlive the registries that
    registered them -- a registry's tool list holds the
    method-of-object reference and would dangle if the runner
    were freed at registry teardown. Cleared in unit
    finalization. Small (one runner per registry that registered
    execute_code), per-process. }
  GRunners: TList = nil;

constructor TExecuteCodeRunner.Create(Registry: TToolRegistry);
begin
  inherited Create;
  FRegistry := Registry;
end;

function ParseStringArg(const ArgsJSON, Field: string; out V: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  V := '';
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      if not Obj.Has(Field) then Exit;
      V := Obj.GetStr(Field, '');
      Result := V <> '';
    finally
      Obj.Free;
    end;
  except
    Result := False;
  end;
end;

function ParseStringArgOptional(const ArgsJSON, Field, Default_: string): string;
var
  Obj: TJsonObject;
begin
  Result := Default_;
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      if Obj.Has(Field) then Result := Obj.GetStr(Field, Default_);
    finally
      Obj.Free;
    end;
  except
    { keep default }
  end;
end;

function HostDefaultLang: string;
begin
  {$IFDEF MSWINDOWS}
  Result := 'powershell';
  {$ELSE}
  Result := 'bash';
  {$ENDIF}
end;

function AutoLang: string;
{ Resolve 'auto'/'' to a shell that actually exists where the script will
  RUN. Normally that's the host default, but when a non-local shell backend
  (docker -> Linux container) is active the script runs in the container,
  not on the host. PowerShell isn't in the debian image, so a Windows
  host's "powershell" default fails with 'sh: powershell: not found'
  (exit 127). Default to bash in that case. (Explicit lang=powershell is
  still honoured -- and still fails clearly if the env lacks it.) }
var
  B: IShellBackend;
begin
  B := GetActiveShellBackend;
  if (B <> nil) and (B.Name <> 'local') then
    Result := 'bash'
  else
    Result := HostDefaultLang;
end;

function ResolveExecuteCodeLang(const Requested: string): string;
var
  L: string;
begin
  L := LowerCase(Trim(Requested));
  if (L = '') or (L = 'auto') then Exit(AutoLang);
  { 'sh' is a common ask from models that want maximum portability
    -- accept it but route to bash. /bin/sh is dash on Debian /
    Ubuntu which is missing common bashisms; pinning to bash is
    the less surprising default. Operators who genuinely want a
    POSIX-strict shell can run `bash --posix ...` inside their
    code. }
  if (L = 'bash') or (L = 'sh') then Exit('bash');
  if (L = 'powershell') or (L = 'pwsh') or (L = 'ps') then
    Exit('powershell');
  Result := AutoLang;
end;

function FindOnPath(const Exe: string): Boolean;
{ Best-effort PATH lookup. FileSearch returns '' when no match. On
  Windows we also try the .exe-suffixed name because that's what
  PATH actually contains; on unix the plain name is canonical. }
{$IFDEF MSWINDOWS}
var
  WithExt: string;
{$ENDIF}
begin
  if FileSearch(Exe, GetEnvironmentVariable('PATH')) <> '' then Exit(True);
  {$IFDEF MSWINDOWS}
  WithExt := Exe;
  if Pos('.', WithExt) = 0 then WithExt := WithExt + '.exe';
  if FileSearch(WithExt, GetEnvironmentVariable('PATH')) <> '' then Exit(True);
  {$ENDIF}
  Result := False;
end;

function ResolvePowerShellExe: string;
begin
  if FindOnPath('pwsh') then Exit('pwsh');
  {$IFDEF MSWINDOWS}
  { Windows PowerShell 5.1 ships in-box on every supported Windows
    version, so this fallback is essentially guaranteed to spawn.
    Codex P2 on PR #199: hardcoding `pwsh` here was a silent break
    on stock Windows where 7+ is an optional install. }
  Exit('powershell');
  {$ELSE}
  { On unix without pwsh, return `pwsh` anyway so RunOneShot's
    spawn surfaces a clean "pwsh: command not found" rather than us
    spawning some unrelated binary the operator happens to have. }
  Exit('pwsh');
  {$ENDIF}
end;

function BuildExecuteCodeArgv(const Lang, ScriptPath: string;
                              out Argv: TStringArray): Boolean;
begin
  Argv := nil;
  if Lang = 'bash' then
  begin
    SetLength(Argv, 2);
    Argv[0] := 'bash';
    Argv[1] := ScriptPath;
    Exit(True);
  end;
  if Lang = 'powershell' then
  begin
    { -ExecutionPolicy Bypass: a default Windows install refuses to
      run unsigned .ps1 files. The model can't sign the script it
      just generated, so Bypass for this invocation is the only
      thing that works. -NoProfile keeps the operator's
      $PROFILE.ps1 out of the picture so the script behaves the
      same regardless of whose box it ran on. -File runs the
      script and exits.

      Executable name comes from ResolvePowerShellExe: pwsh when
      it's on PATH (preferred on unix and on Windows boxes with
      PowerShell 7 installed), `powershell` otherwise (Windows
      PowerShell 5.1 fallback for stock Windows). Don't hardcode
      `pwsh` here -- stock Windows ships only 5.1 and the spawn
      would fail. }
    SetLength(Argv, 6);
    Argv[0] := ResolvePowerShellExe;
    Argv[1] := '-NoProfile';
    Argv[2] := '-ExecutionPolicy';
    Argv[3] := 'Bypass';
    Argv[4] := '-File';
    Argv[5] := ScriptPath;
    Exit(True);
  end;
  Result := False;
end;

function ScriptExtension(const Lang: string): string;
begin
  if Lang = 'powershell' then Result := '.ps1' else Result := '.sh';
end;

function ArgvNeedsQuoting(const Arg: string): Boolean;
{ True when Arg must be wrapped in quotes for `cmd /C` or `sh -c`
  not to mis-parse it. Bareword-safe tokens (no whitespace, no
  shell metacharacters) can pass through unquoted, which matters
  on Windows where quoting the executable name itself breaks
  cmd.exe's command lookup (`'"powershell"' is not recognized`).

  The metacharacter set covers what either shell treats specially:
  whitespace + shell-operator chars + quote chars themselves.
  Conservative: false positives just produce unnecessary quoting,
  not incorrect parsing. }
var
  i: Integer;
begin
  if Arg = '' then Exit(True);    { empty arg needs explicit "" }
  for i := 1 to Length(Arg) do
    case Arg[i] of
      ' ', #9, #10, #13,
      '"', '''',
      '&', '|', '<', '>', '^',
      '(', ')',
      '*', '?', ';',
      '$', '`':
        Exit(True);
    end;
  Result := False;
end;

function MakeTempScript(const Lang, Code: string; out Path: string;
                       out ErrMsg: string): Boolean;
{ Materialise the model's script body to disk under
  $PASCLAW_HOME/tmp/exec-<unique>.<ext>. Caller is responsible for
  deleting it; we do that in the finally block of Tool_ExecuteCode. }
var
  Dir: string;
  Sl: TStringList;
begin
  Result := False;
  Path   := '';
  ErrMsg := '';
  Dir := JoinPath(GetHome, 'tmp');
  if not DirectoryExists(Dir) then
    if not ForceDirectories(Dir) then
    begin
      ErrMsg := 'execute_code: failed to create temp dir ' + Dir;
      Exit;
    end;
  { MilliSecondsBetween(Now, 1970-01-01) + Random gives enough
    uniqueness for a single-process tool that runs sequentially.
    No locking needed because the registry serialises tool
    dispatch. Same pattern as PasClaw.Skills.GitHub.UniqueSuffix;
    avoids the FPC-only GetTickCount64 that Delphi dcc64 refuses
    to resolve. }
  Path := JoinPath(Dir,
                   Format('exec-%d-%d%s',
                          [Int64(MilliSecondsBetween(Now, EncodeDate(1970, 1, 1))),
                           Random(1000000),
                           ScriptExtension(Lang)]));
  Sl := TStringList.Create;
  try
    { LF line endings, always. TStringList.SaveToFile defaults to the host
      line ending -- CRLF on Windows -- but with the docker backend the
      script runs in a Linux container where bash treats the trailing \r as
      part of the last token ("ls -la\r" -> "invalid option", "-maxdepth
      2\r" -> "not a positive integer"). LF is correct for bash and
      accepted by PowerShell, so force it unconditionally. }
    Sl.LineBreak := #10;
    Sl.Text := Code;
    try
      Sl.SaveToFile(Path);
    except
      on E: Exception do
      begin
        ErrMsg := 'execute_code: failed writing script: ' + E.Message;
        Exit;
      end;
    end;
  finally
    Sl.Free;
  end;
  Result := True;
end;

function Tool_ExecuteCodeImpl(Registry: TToolRegistry;
                              const ArgsJSON: string;
                              out ErrMsg: string): string;
{ The real handler. Takes the registry explicitly so the wrapper
  (TExecuteCodeRunner.Execute or the registry-less Tool_ExecuteCode
  legacy entry) can hand in the right one. Registry-aware lets
  per-call RPC servers bind to the correct registry, satisfying
  Codex P1 (subagent allowlist enforcement).

  Per-call RPC server lifecycle is the second half of the
  Codex-P2 fix: each invocation gets its own server, on its own
  kernel-allocated port, with its own info file, and tells the
  spawned script where to find it via the PASCLAW_TOOL_RPC_INFO
  env var. No global state means two concurrent execute_codes
  (parent + subagent, or two parallel tool calls) can't trample
  each other's bindings. }
var
  Lang, Code, ResolvedLang, ScriptPath, RunScriptPath, Reason, WorkDir, Cmd, Out_: string;
  Argv: TStringArray;
  ExitCode, i: Integer;
  Server: TToolRPCServer;
  ExtraEnv: TStringList;
  InfoPath: string;
begin
  ErrMsg := '';
  Result := '';

  if not ParseStringArg(ArgsJSON, 'code', Code) then
  begin
    ErrMsg := 'missing required argument: code';
    Exit;
  end;
  Lang         := ParseStringArgOptional(ArgsJSON, 'lang', 'auto');
  ResolvedLang := ResolveExecuteCodeLang(Lang);

  if not ShellAllowed(Code, Reason) then
  begin
    ErrMsg := Reason;
    Exit;
  end;

  { Per-call RPC server: bound to THIS registry only, info file
    on a path no other concurrent execute_code call can pick. If
    the bind fails for any reason (port exhaustion, locked-down
    sandbox) the script still runs -- it just can't make
    `pasclaw __tool` callbacks. Registry-less callers (standalone
    test harnesses) skip the server entirely; there'd be nothing
    to dispatch to. }
  Server   := nil;
  ExtraEnv := nil;
  if Registry <> nil then
    try
      InfoPath := MakePerCallInfoPath;
      Server   := TToolRPCServer.Create(Registry, InfoPath);
      Server.Start;
      ExtraEnv := TStringList.Create;
      { The script runs in the active backend's namespace, so the env
        value must be the path IT sees. Identity on the local backend
        and on POSIX docker; mapped on Windows docker. }
      ExtraEnv.Add('PASCLAW_TOOL_RPC_INFO=' +
                   HostToContainerPathViaBackend(InfoPath));
    except
      on E: Exception do
      begin
        LogWarn('execute_code: tool-rpc unavailable: %s', [E.Message]);
        if Server <> nil then begin Server.Free; Server := nil; end;
        if ExtraEnv <> nil then begin ExtraEnv.Free; ExtraEnv := nil; end;
      end;
    end;

  try
    if not MakeTempScript(ResolvedLang, Code, ScriptPath, ErrMsg) then Exit;
    try
      { The temp file is written/deleted at the HOST path (ScriptPath),
        but the command that runs it must reference the path the active
        backend sees. Identity on the local backend and on POSIX docker
        (same-path bind mount); on Windows docker the host C:\...\tmp\
        script is mapped to its /pasclaw/tmp mount point -- otherwise
        `bash C:\...\script` would not exist inside the Linux container. }
      RunScriptPath := HostToContainerPathViaBackend(ScriptPath);
      if not BuildExecuteCodeArgv(ResolvedLang, RunScriptPath, Argv) then
      begin
        ErrMsg := 'execute_code: unsupported lang "' + Lang + '"';
        Exit;
      end;

      { Compose the spawn command. RunOneShotWithEnv wants a single
        command string it can hand to /bin/sh -c (or cmd /c on
        Windows) -- we don't have a direct argv-vector API.

        Quote each argument that contains whitespace or shell
        special chars; leave bareword-safe tokens (the executable
        name like `bash` / `pwsh` / `powershell`) unquoted. Earlier
        revisions unconditionally wrapped every element in `"..."`
        -- on Windows that produced `cmd /C ""powershell" "-File"
        "C:\..\.ps1""` which cmd.exe's parser misreads as a request
        for a program literally named `"powershell"` (with quotes),
        failing with "'\"powershell\"' is not recognized". The
        script path under $PASCLAW_HOME/tmp/ does still need
        quoting on hosts where the user profile name has spaces. }
      Cmd := '';
      for i := 0 to High(Argv) do
      begin
        if Cmd <> '' then Cmd := Cmd + ' ';
        if ArgvNeedsQuoting(Argv[i]) then
          Cmd := Cmd + '"' + StringReplace(Argv[i], '"', '\"', [rfReplaceAll]) + '"'
        else
          Cmd := Cmd + Argv[i];
      end;

      if RestrictionActive then
        WorkDir := CurrentWorkspace
      else
        WorkDir := '';
      LogDebug('execute_code (lang=%s cwd=%s rpc=%s): %s',
               [ResolvedLang, WorkDir,
                BoolToStr(Server <> nil, True), ScriptPath]);
      ExitCode := RunOneShotWithEnvViaBackend(GetCurrentSessionId, Cmd, WorkDir,
                                              ExtraEnv, Out_);
      Result := Format('exit=%d'#10'%s', [ExitCode, Out_]);
    finally
      if (ScriptPath <> '') and FileExists(ScriptPath) then
        DeleteFile(ScriptPath);
    end;
  finally
    { Tear the RPC server down before returning so the info file
      goes away and the port is released. A late RPC call from a
      script that backgrounded itself past the parent loop's
      window will see the file gone and surface a clean
      "tool-rpc info file is missing" error. }
    if Server   <> nil then Server.Free;
    if ExtraEnv <> nil then ExtraEnv.Free;
  end;
end;

function TExecuteCodeRunner.Execute(const ArgsJSON: string;
                                    out ErrMsg: string): string;
begin
  Result := Tool_ExecuteCodeImpl(FRegistry, ArgsJSON, ErrMsg);
end;

function Tool_ExecuteCode(const ArgsJSON: string; out ErrMsg: string): string;
{ Legacy entry kept for the existing execute_code_tests harness
  -- those tests don't have a registry to bind so they run
  execute_code without tool-RPC. Production callers go through
  TExecuteCodeRunner.Execute via the registry. }
begin
  Result := Tool_ExecuteCodeImpl(nil, ArgsJSON, ErrMsg);
end;

procedure RegisterExecuteCodeTool(R: TToolRegistry);
var
  T: TTool;
  Runner: TExecuteCodeRunner;
begin
  { Per-registry runner: each TToolRegistry that registers
    execute_code gets its own runner instance carrying a pointer
    to THAT registry. When the model calls execute_code through a
    subagent's filtered registry, the runner that fires sees the
    subagent's tools -- not the parent's. RPC dispatch from the
    spawned script lands in the same restricted registry.
    (Codex P1 on PR #206.)

    Runner outlives the registry; GRunners keeps them alive until
    unit finalization. Memory cost is one tiny object per
    registry-with-execute_code per process; negligible. }
  if GRunners = nil then GRunners := TList.Create;
  Runner := TExecuteCodeRunner.Create(R);
  GRunners.Add(Runner);

  T.Name        := 'execute_code';
  T.Description := 'Run a multi-line bash or PowerShell script. Use when ' +
                   'you need a loop, heredoc, or fan-out that would be ' +
                   'awkward to express as a single shell_exec command. ' +
                   'Script body is written to a temp file then executed; ' +
                   'returns combined stdout+stderr and exit code. Subject ' +
                   'to the same sandbox + denylist as shell_exec. ' +
                   'INSIDE the script you can call back into any of your ' +
                   'other tools by running `pasclaw __tool <name> ''<json-args>''` ' +
                   '-- the call hits the same registry you''re using now. ' +
                   'Use this to fan out: e.g. list files, then memory_search ' +
                   'each, then read_file the top hits, all in one script.';
  T.Schema      :=
    '{"type":"object",' +
     '"properties":{' +
       '"code":{"type":"string","description":"Multi-line script body. ' +
              'No need to escape newlines, quotes, or heredocs -- the body ' +
              'is materialised to a temp file before execution."},' +
       '"lang":{"type":"string",' +
              '"description":"bash | powershell | auto (default: auto -- ' +
              'picks bash on unix / macOS, PowerShell on Windows).",' +
              '"enum":["bash","sh","powershell","pwsh","auto"]}},' +
     '"required":["code"]}';
  T.Handler     := nil;
  T.HandlerObj  := Runner.Execute;
  T.IsCore      := True;
  T.Category    := tcMutating;  { runs arbitrary code; mutating by default }
  R.Register(T);
end;

procedure FreeRunners;
var
  i: Integer;
begin
  if GRunners = nil then Exit;
  for i := 0 to GRunners.Count - 1 do
    TExecuteCodeRunner(GRunners[i]).Free;
  GRunners.Free;
  GRunners := nil;
end;

{ Empty initialization is intentional. Delphi dcc64 errors with
  E2029 "Declaration expected but 'FINALIZATION' found" when a
  unit has a bare finalization section -- the initialization
  keyword is required as a header even when there's no startup
  work. FPC mode delphi is more permissive and accepts the bare
  finalization, which is why this only surfaced under dcc64. }
initialization

finalization
  FreeRunners;

end.
