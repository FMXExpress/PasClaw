{
  PasClaw.Cmd.Root - root command dispatcher, equivalent to NewPicoclawCommand()
  in cmd/picoclaw/main.go. Each subcommand exposes a CmdSpec record and a
  Run() function; we route argv[1] to the matching command.
}
unit PasClaw.Cmd.Root;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

{ Returns the exit code that would have been returned by the CLI for the
  same `pasclaw Cmd Argv...` invocation. Pure dispatch -- does not touch
  ParamStr, the log level, or any global init -- so embedding callers
  (TPasClawAgent.Execute, tests) can use it without re-reading the host
  process's command line. RunRootCommand below handles CLI-only concerns
  (argv parsing, --no-color stripping, config-driven log level) then
  forwards to DispatchCommand. }
function DispatchCommand(const Cmd: string; const Argv: array of string): Integer;
function RunRootCommand: Integer;

implementation

uses
  SysUtils, Classes,
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Cmd.Onboard,
  PasClaw.Cmd.Agent,
  PasClaw.Cmd.Auth,
  PasClaw.Cmd.Gateway,
  PasClaw.Cmd.Serve,
  PasClaw.Cmd.Status,
  PasClaw.Cmd.Version,
  PasClaw.Cmd.Cron,
  PasClaw.Cmd.Desktop,   { workspace / project -- the desktop board }
  PasClaw.Cmd.MCP,
  PasClaw.Cmd.Migrate,
  PasClaw.Cmd.Skills,
  PasClaw.Cmd.Profile,    (* PR #291: pasclaw profile list/show/use *)
  PasClaw.Cmd.Vault,
  PasClaw.Cmd.Session,
  PasClaw.Cmd.Doctor,
  PasClaw.Cmd.Learn,
  PasClaw.Cmd.Steer,
  PasClaw.Cmd.Model,
  PasClaw.Cmd.Config_,
  PasClaw.Cmd.Update,
  PasClaw.Cmd.Post,
  PasClaw.Cmd.Membench,
  PasClaw.Cmd.Memory,
  PasClaw.Cmd.KB,
  PasClaw.Cmd.ToolRPC,
  PasClaw.Cmd.Export,
  PasClaw.Cmd.Init,         (* Pascal-driven AGENTS.md bootstrap -- complements
                               Cmd.Runbook's tool-driven variant *)
  PasClaw.Cmd.Build,        (* `pasclaw build` -- one-shot multi-iter agent
                               with workspace.zip handshake *)
  PasClaw.Cmd.Plan,         (* `pasclaw plan` -- plan-mode sibling to build,
                               writes workspace/PLAN.md via plan_write *)
  PasClaw.Cmd.Runbook,
  PasClaw.Cmd.Relay,        (* `pasclaw relay` -- worker client polling
                               a remote gateway's /v1/relay/poll *)
  PasClaw.Cmd.Heartbeat,
  PasClaw.Cmd.TUI;

type
  TSubCmd = record
    Name: string;
    Help: string;
    Run:  function(const Argv: array of string): Integer;
  end;

procedure StripGlobalFlags(var Out_: TStringList);
var
  i: Integer;
begin
  i := 0;
  while i < Out_.Count do
  begin
    if (Out_[i] = '--no-color')
      or (Out_[i] = '--no-color=true')
      or (Out_[i] = '--no-color=1')
    then
      Out_.Delete(i)
    else
      Inc(i);
  end;
end;

function ArgvHasQuietFlag: Boolean;
(* Mirrors PasClaw.dpr's IsQuietInvocation so RunRootCommand can
   ask the same question without a cross-module reach. Duplicated
   intentionally -- both call sites need to know "did the user
   pass --quiet anywhere on argv" BEFORE the per-command ParseArgs
   runs. Three lines isn't worth a shared module. *)
var
  i: Integer;
  Arg: string;
begin
  Result := False;
  for i := 1 to ParamCount do
  begin
    Arg := ParamStr(i);
    if (Arg = '--quiet') or (Arg = '-q') then Exit(True);
  end;
end;

function CollectArgs: TStringList;
var
  i: Integer;
begin
  Result := TStringList.Create;
  for i := 1 to ParamCount do Result.Add(ParamStr(i));
end;

function ToArray(L: TStringList; StartIdx: Integer): TArray<string>;
var
  i: Integer;
begin
  SetLength(Result, L.Count - StartIdx);
  for i := StartIdx to L.Count - 1 do
    Result[i - StartIdx] := L[i];
end;

procedure PrintRootHelp;
const
  Use = 'pasclaw [command] [flags]';
  Short = 'PasClaw -- personal AI assistant';
  Long  = 'PasClaw is a lightweight personal AI assistant.';
  Example = 'pasclaw version' + sLineBreak +
            '  pasclaw onboard' + sLineBreak +
            '  pasclaw --no-color status';
var
  Sub, Fl: array of string;
begin
  SetLength(Sub, 35);
  Sub[0]  := 'config       View/edit configuration';
  Sub[1]  := 'onboard      Initialize config & workspace';
  Sub[2]  := 'agent        Chat with the assistant (line-by-line)';
  Sub[3]  := 'tui          Chat in the full-screen TUI';
  Sub[4]  := 'auth         Authenticate with providers';
  Sub[5]  := 'gateway      Start the HTTP gateway + web UI';
  Sub[6]  := 'serve        Start the OpenAI-compatible API server (/v1/chat/completions)';
  Sub[7]  := 'status       Show status';
  Sub[8]  := 'cron         Manage scheduled tasks';
  Sub[9]  := 'mcp          Manage MCP servers';
  Sub[10] := 'migrate      Migrate data from older versions';
  Sub[11] := 'skills       Manage skill extensions';
  Sub[12] := 'vault        Search / fetch pasclaw.dev Code Vault entries';
  Sub[13] := 'model        View or switch the default model';
  Sub[14] := 'post         Send a one-shot message to a channel';
  Sub[15] := 'membench     Benchmark the memory log subsystem';
  Sub[16] := 'session      List/show/delete/export saved sessions';
  Sub[17] := 'resume       Resume a saved session (alias for agent --session)';
  Sub[18] := 'steer        Push a mid-loop follow-up into a running agent';
  Sub[19] := 'update       Self-update PasClaw';
  Sub[20] := 'memory       Provision the hybrid memory_search runtime';
  Sub[21] := 'kb           Manage the knowledgebase (index documents for the agent)';
  Sub[22] := 'learn        Mine sessions for recurring tool failures';
  Sub[23] := 'export       Render memory/skills/sandbox into AGENTS.md / CLAUDE.md / Cursor / Gemini / Zed';
  Sub[24] := 'init         Scan cwd and ask the model for a starter AGENTS.md (one-shot, no tool loop)';
  Sub[25] := 'runbook      Tool-driven variant of init: agent loop probes the repo via execute_code';
  Sub[26] := 'build        One-shot multi-iter agent run with workspace.zip handshake (for cog / CI)';
  Sub[27] := 'plan         Plan-mode sibling to build; writes workspace/PLAN.md via plan_write tool';
  Sub[28] := 'heartbeat    Run the proactive periodic wake-up daemon (off by default; opt in via onboard)';
  Sub[29] := 'relay        Pull-worker for /v1/relay -- forwards jobs through the local provider';
  Sub[30] := 'workspace    List/create/switch workspaces (separate agent worlds)';
  Sub[31] := 'project      List/create/inspect desktop projects and their apps';
  Sub[32] := 'mail         Sync the Mail app''s inbox from IMAP (for cron)';
  Sub[33] := 'version      Show version info';
  Sub[34] := 'doctor       Diagnose this install (config/workspace/memory/...)';

  SetLength(Fl, 2);
  Fl[0] := '--no-color   Disable colored output (also: NO_COLOR env)';
  Fl[1] := '-h, --help   Show this help';

  Print(RenderCommandHelp(Use, Short, Long, Example, Sub, Fl));
end;

function DispatchCommand(const Cmd: string; const Argv: array of string): Integer;
var
  ResumeArgv: array of string;
begin
  if      Cmd = 'config'   then Result := Cmd_Config_Run(Argv)
  else if Cmd = 'onboard'  then Result := Cmd_Onboard_Run(Argv)
  else if Cmd = 'agent'    then Result := Cmd_Agent_Run(Argv)
  else if Cmd = 'auth'     then Result := Cmd_Auth_Run(Argv)
  else if Cmd = 'gateway'  then Result := Cmd_Gateway_Run(Argv)
  else if Cmd = 'serve'    then Result := Cmd_Serve_Run(Argv)
  else if Cmd = 'status'   then Result := Cmd_Status_Run(Argv)
  else if Cmd = 'cron'     then Result := Cmd_Cron_Run(Argv)
  else if Cmd = 'workspace' then Result := Cmd_Workspace_Run(Argv)
  else if Cmd = 'project'  then Result := Cmd_Project_Run(Argv)
  else if Cmd = 'mail'     then Result := Cmd_Mail_Run(Argv)
  else if Cmd = 'mcp'      then Result := Cmd_MCP_Run(Argv)
  else if Cmd = 'migrate'  then Result := Cmd_Migrate_Run(Argv)
  else if Cmd = 'skills'   then Result := Cmd_Skills_Run(Argv)
  else if Cmd = 'profile'  then Result := Cmd_Profile_Run(Argv)
  else if Cmd = 'vault'    then Result := Cmd_Vault_Run(Argv)
  else if Cmd = 'session'  then Result := Cmd_Session_Run(Argv)
  else if Cmd = 'doctor'   then Result := Cmd_Doctor_Run(Argv)
  else if Cmd = 'learn'    then Result := Cmd_Learn_Run(Argv)
  else if Cmd = 'export'   then Result := Cmd_Export_Run(Argv)
  else if Cmd = 'init'     then Result := Cmd_Init_Run(Argv)
  else if Cmd = 'build'    then Result := Cmd_Build_Run(Argv)
  else if Cmd = 'plan'     then Result := Cmd_Plan_Run(Argv)
  else if Cmd = 'runbook'  then Result := Cmd_Runbook_Run(Argv)
  else if Cmd = 'relay'    then Result := Cmd_Relay_Run(Argv)
  { resume <id> is shorthand for `agent --session <id>` -- wire it
    here so `pasclaw resume foo` works as a top-level shortcut. }
  else if Cmd = 'resume'   then
  begin
    if Length(Argv) < 1 then
    begin
      PrintLn('Usage: pasclaw resume <session-id>');
      Result := 1;
    end
    else
    begin
      SetLength(ResumeArgv, 2);
      ResumeArgv[0] := '--session';
      ResumeArgv[1] := Argv[0];
      Result := Cmd_Agent_Run(ResumeArgv);
    end;
  end
  else if Cmd = 'steer'    then Result := Cmd_Steer_Run(Argv)
  else if Cmd = 'model'    then Result := Cmd_Model_Run(Argv)
  else if Cmd = 'post'     then Result := Cmd_Post_Run(Argv)
  else if Cmd = 'membench' then Result := Cmd_Membench_Run(Argv)
  else if Cmd = 'memory'   then Result := Cmd_Memory_Run(Argv)
  else if Cmd = 'kb'       then Result := Cmd_KB_Run(Argv)
  { Internal callback channel for execute_code's tool-RPC. Not
    listed in `pasclaw --help` -- the underscore prefix marks it
    as not-for-humans. See PasClaw.Cmd.ToolRPC for the wire shape. }
  else if Cmd = '__tool'   then Result := Cmd_ToolRPC_Run(Argv)
  else if Cmd = 'tui'      then Result := Cmd_TUI_Run(Argv)
  else if Cmd = 'heartbeat' then Result := Cmd_Heartbeat_Run(Argv)
  else if Cmd = 'update'   then Result := Cmd_Update_Run(Argv)
  else if Cmd = 'version'  then Result := Cmd_Version_Run(Argv)
  else
  begin
    PrintErr(FormatCLIError('unknown command: ' + Cmd, 'pasclaw'));
    Result := 1;
  end;
end;

function RunRootCommand: Integer;
var
  Args: TStringList;
  Cmd: string;
  ArgArr: TArray<string>;
  Cfg: TConfig;
begin
  { Result := 0 removed -- dead write per dcc64 H2077. Every exit
    path assigns Result before returning: Exit(0) for the help
    branch, Result := DispatchCommand(...) for the dispatch
    branch (which itself always assigns Result, including the
    unknown-command else clause). }
  Args := CollectArgs;
  try
    StripGlobalFlags(Args);

    { Apply log level from config (best-effort; ignore on missing file).
      EXCEPT when the user passed --quiet / -q: PasClaw.dpr has already
      clamped the level to llError, and applying the default 'info'
      from config.json here would undo the clamp before LoadConfig /
      ConnectMCP / Search.Factory get a chance to fire their LogInfo
      noise -- which is the entire point of --quiet. (Codex P1 on
      PR #244: the config-driven level was overriding the clamp
      silently and the [info] lines were still appearing in quiet
      one-shot output.) }
    Cfg := LoadConfig;
    try
      if not ArgvHasQuietFlag then
        SetLogLevelFromString(Cfg.Gateway.LogLevel);
    finally
      Cfg.Free;
    end;

    if (Args.Count = 0) or (Args[0] = '-h') or (Args[0] = '--help') or (Args[0] = 'help') then
    begin
      PrintRootHelp;
      Exit(0);
    end;

    Cmd := Args[0];
    ArgArr := ToArray(Args, 1);
    Result := DispatchCommand(Cmd, ArgArr);
  finally
    Args.Free;
  end;
end;

end.
