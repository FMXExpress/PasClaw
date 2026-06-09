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

(* The tool handler itself. Exposed (rather than only registered)
   so a regression test can drive it without standing up a full
   agent + provider. Same calling convention as every other
   TToolHandler: ArgsJSON in, Result string out, ErrMsg out for
   failures. *)
function Tool_ExecuteCode(const ArgsJSON: string; out ErrMsg: string): string;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Config,
  PasClaw.Platform,
  PasClaw.Utils,
  PasClaw.Tools.Sandbox;

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

function ResolveExecuteCodeLang(const Requested: string): string;
var
  L: string;
begin
  L := LowerCase(Trim(Requested));
  if (L = '') or (L = 'auto') then Exit(HostDefaultLang);
  { 'sh' is a common ask from models that want maximum portability
    -- accept it but route to bash. /bin/sh is dash on Debian /
    Ubuntu which is missing common bashisms; pinning to bash is
    the less surprising default. Operators who genuinely want a
    POSIX-strict shell can run `bash --posix ...` inside their
    code. }
  if (L = 'bash') or (L = 'sh') then Exit('bash');
  if (L = 'powershell') or (L = 'pwsh') or (L = 'ps') then
    Exit('powershell');
  Result := HostDefaultLang;
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
      script and exits. We prefer `pwsh` (PowerShell 7+, available
      cross-platform via dotnet) when present; `powershell.exe`
      (Windows PowerShell 5.1) is the Windows fallback. The
      executable resolution is done by the platform spawn -- we
      pass `pwsh` here and let PATH lookup fail through to
      `powershell` if needed. }
    SetLength(Argv, 6);
    Argv[0] := 'pwsh';
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
  { GetTickCount64 + Random gives enough uniqueness for a
    single-process tool that runs sequentially. No locking needed
    because the registry serialises tool dispatch. }
  Path := JoinPath(Dir,
                   Format('exec-%d-%d%s',
                          [Int64(GetTickCount64), Random(1000000),
                           ScriptExtension(Lang)]));
  Sl := TStringList.Create;
  try
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

function Tool_ExecuteCode(const ArgsJSON: string; out ErrMsg: string): string;
var
  Lang, Code, ResolvedLang, ScriptPath, Reason, WorkDir, Cmd, Out_: string;
  Argv: TStringArray;
  ExitCode, i: Integer;
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

  { Run the body through the same denylist shell_exec uses. The
    sandbox check is a substring sweep so it catches `rm -rf /` and
    friends regardless of which line of the script they appear on.
    There is no perfect defense against a determined operator-side
    bypass (concat strings at runtime, base64 decode + eval), but
    the floor here matches shell_exec exactly so we don't introduce
    an easier execute_code-only escape hatch. }
  if not ShellAllowed(Code, Reason) then
  begin
    ErrMsg := Reason;
    Exit;
  end;

  if not MakeTempScript(ResolvedLang, Code, ScriptPath, ErrMsg) then Exit;
  try
    if not BuildExecuteCodeArgv(ResolvedLang, ScriptPath, Argv) then
    begin
      ErrMsg := 'execute_code: unsupported lang "' + Lang + '"';
      Exit;
    end;

    { Compose the spawn command. RunOneShot wants a single command
      string it can hand to /bin/sh -c (or cmd /c on Windows) --
      we don't have a direct argv-vector API. Quote each argument
      so spaces or special chars in $PASCLAW_HOME don't fragment
      the script-path argument; the script body itself is in the
      file and isn't touched by this quoting. }
    Cmd := '';
    for i := 0 to High(Argv) do
    begin
      if Cmd <> '' then Cmd := Cmd + ' ';
      Cmd := Cmd + '"' + StringReplace(Argv[i], '"', '\"', [rfReplaceAll]) + '"';
    end;

    if RestrictionActive then
      WorkDir := CurrentWorkspace
    else
      WorkDir := '';
    LogDebug('execute_code (lang=%s cwd=%s): %s',
             [ResolvedLang, WorkDir, ScriptPath]);
    ExitCode := RunOneShot(Cmd, WorkDir, Out_);
    Result := Format('exit=%d'#10'%s', [ExitCode, Out_]);
  finally
    { Best-effort cleanup. If a script self-deleted the temp file
      (rare but possible), DeleteFile returns False; we don't
      surface that to the model since the tool result is already
      successful. }
    if (ScriptPath <> '') and FileExists(ScriptPath) then
      DeleteFile(ScriptPath);
  end;
end;

procedure RegisterExecuteCodeTool(R: TToolRegistry);
var
  T: TTool;
begin
  T.Name        := 'execute_code';
  T.Description := 'Run a multi-line bash or PowerShell script. Use when ' +
                   'you need a loop, heredoc, or fan-out that would be ' +
                   'awkward to express as a single shell_exec command. ' +
                   'Script body is written to a temp file then executed; ' +
                   'returns combined stdout+stderr and exit code. Subject ' +
                   'to the same sandbox + denylist as shell_exec.';
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
  T.Handler     := Tool_ExecuteCode;
  T.IsCore      := True;
  T.Category    := tcMutating;  { runs arbitrary code; mutating by default }
  R.Register(T);
end;

end.
