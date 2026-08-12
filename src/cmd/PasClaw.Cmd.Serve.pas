(*
  serve - Start the OpenAI-compatible API server.

    pasclaw serve                         # default bind/port from config
    pasclaw serve --addr 0.0.0.0 --port 8088
    pasclaw serve --no-tools              # disable built-in tool registry
    pasclaw serve --no-mcp                # skip MCP server discovery
    pasclaw serve --debug                 # log every request + response body
    pasclaw serve --max-iter 40           # raise the tool-loop cap (default 25)
    pasclaw serve --no-hashline           # raw fs_read; skip fs_edit_hashline + fs_grep
    pasclaw serve --mcp-port 8089         # also expose MCP on its own port
                                          # (default: mounted on /mcp on the
                                          # main port -- alongside /v1)
    pasclaw serve --mcp-allow-write       # let MCP clients call mutating
                                          # tools too (fs_write, shell, ...).
                                          # OFF by default -- a foreign MCP
                                          # host calling fs_write on the
                                          # operator's box is exactly the
                                          # bad outcome sandbox exists for.

  Exposes POST /v1/chat/completions on the configured port. Any client
  that speaks the OpenAI Chat Completions API (openai-python, openai-node,
  LangChain, autogen, LlamaIndex, the OpenAI Cookbook examples, etc.) can
  point at this server by setting:

    base_url = http://<addr>:<port>/v1
    api_key  = anything-nonempty       (the server doesn't enforce auth yet)

  Internally this is the same TGatewayServer the `gateway` subcommand
  uses -- `serve` just trims the surface to the OpenAI endpoints and
  prints copy-pasteable client config.
*)
unit PasClaw.Cmd.Serve;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Serve_Run(const Argv: array of string): Integer;

implementation

uses
  PasClaw.Workspaces,
  SysUtils,
  PasClaw.Config, PasClaw.CliUI, PasClaw.Logger,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Factory,
  PasClaw.Tools.Registry,
  PasClaw.Tools.FS,
  PasClaw.Tools.Shell,
  PasClaw.Tools.ExecuteCode,
  PasClaw.Tools.Memory,
  PasClaw.Tools.KB,
  PasClaw.Tools.DelphiBuild,
  PasClaw.Tools.SessionSearch,
  PasClaw.Tools.SendMessage,
  PasClaw.Tools.Cron,             { cron tool -- gated on cron_tool_enabled }
  PasClaw.Projects.Tools,         { project / task -- the desktop board }
  PasClaw.Tools.WebSearch,
  PasClaw.Search.Factory,
  PasClaw.Tools.WebFetch,
  PasClaw.Tools.MemoryFetch,
  PasClaw.Tools.Vault,
  PasClaw.Tools.OutputCache,
  PasClaw.Tools.Sandbox,
  PasClaw.Shell.Backend,    { TShellBackendKind + StartShellSession /
                              SetCurrentSessionId / CloseShellSession --
                              one container per serve process }
  PasClaw.Shell.Backend.Factory,  { InstallShellBackend }
  PasClaw.Session.Store,    { NewSessionId for the shell session id }
  PasClaw.MCP.Bridge,
  PasClaw.Skills.Loader,
  PasClaw.Tools.DB,
  PasClaw.Skills.Manage,
  PasClaw.Skills.Disclosure,
  PasClaw.Cron.Scheduler,
  PasClaw.Stream.Reliability,
  PasClaw.Agent.SubagentBg,   { RegisterSubagentTools -- spawn on the served loop }
  PasClaw.Gateway.Server;

type
  TServeArgs = record
    Addr:           string;
    Port:           Integer;
    NoMCP:          Boolean;
    NoTools:        Boolean;
    Debug:          Boolean;
    MaxIter:        Integer;
    NoHashline:     Boolean;
    { Inbound MCP server: when MCPPort = 0 (default) the /mcp surface
      is mounted on the main listener at POST /mcp + POST /v1/mcp/rpc.
      When > 0 the gateway spins up a second listener bound to that
      port that serves /mcp ONLY -- useful when a heavy /v1/responses
      streaming load might otherwise compete with MCP requests for
      Indy worker threads. }
    MCPPort:        Integer;
    MCPAllowWrite:  Boolean;
  end;

function ParseServe(const Argv: array of string; const Cfg: TConfig): TServeArgs;
var
  i: Integer;
begin
  Result.Addr          := Cfg.Gateway.BindAddr;
  Result.Port          := Cfg.Gateway.Port;
  Result.NoMCP         := False;
  Result.NoTools       := False;
  Result.Debug         := False;
  Result.MaxIter       := 25;  { matches TGatewayServer.Create default }
  Result.NoHashline    := False;
  Result.MCPPort       := 0;
  Result.MCPAllowWrite := False;
  i := 0;
  while i <= High(Argv) do
  begin
    if Argv[i] = '--addr'         then begin if i < High(Argv) then Result.Addr := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--port'         then begin if i < High(Argv) then Result.Port := StrToIntDef(Argv[i + 1], Result.Port); Inc(i, 2); Continue; end;
    if Argv[i] = '--no-mcp'       then begin Result.NoMCP      := True; Inc(i); Continue; end;
    if Argv[i] = '--no-tools'     then begin Result.NoTools    := True; Inc(i); Continue; end;
    if (Argv[i] = '--debug') or (Argv[i] = '-d') then
                                      begin Result.Debug       := True; Inc(i); Continue; end;
    if Argv[i] = '--max-iter'     then begin if i < High(Argv) then Result.MaxIter := StrToIntDef(Argv[i + 1], Result.MaxIter); Inc(i, 2); Continue; end;
    if Argv[i] = '--no-hashline'  then begin Result.NoHashline := True; Inc(i); Continue; end;
    if Argv[i] = '--mcp-port'     then begin if i < High(Argv) then Result.MCPPort := StrToIntDef(Argv[i + 1], 0); Inc(i, 2); Continue; end;
    if Argv[i] = '--mcp-allow-write' then begin Result.MCPAllowWrite := True; Inc(i); Continue; end;
    Inc(i);
  end;
  if Result.MaxIter < 1 then Result.MaxIter := 1;
end;

{ Handler for a runtime workspace switch: repoint the sandbox at the new
  root. Unit-level, because a nested procedure cannot be assigned to a
  procedure-type variable. }
procedure RepointSandbox(const NewRoot: string);
var
  Cfg: TConfig;
begin
  ForceDirectories(NewRoot);
  Cfg := LoadConfig;
  ConfigureSandbox(Cfg.Sandbox, NewRoot);
end;

function Cmd_Serve_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Args: TServeArgs;
  Provider: ILLMProvider;
  Err: string;
  Reg: TToolRegistry;
  MCPClients: TMCPClientList;
  Server, MCPServer: TGatewayServer;
  Scheduler: TCronScheduler;
  Skills: TSkillSpecArray;
  BaseURL: string;
  KindSelected: TShellBackendKind;
  BackendDesc, ShellSessionId, ProfileName: string;
  pi: Integer;
begin
  { Pre-scan for --profile so LoadConfig sees it. Same shape as
    Cmd.Gateway -- precedence stays CLI > PASCLAW_PROFILE > config.json
    field. PR #291. }
  ProfileName := '';
  for pi := 0 to High(Argv) - 1 do
    if Argv[pi] = '--profile' then
    begin
      ProfileName := Argv[pi + 1];
      Break;
    end;
  Cfg := LoadConfig(ProfileName);
  { Default the working directory to $PASCLAW_HOME/workspace (the operator's
    work area) rather than the launch CWD, so a relative write_file path lands
    somewhere predictable. An explicit sandbox.workspace still wins. }
  if Trim(Cfg.Sandbox.Workspace) <> '' then
    ConfigureSandbox(Cfg.Sandbox, '')
  else
  begin
    { Ensure the default work area exists so shell_exec can start there too. }
    ForceDirectories(IncludeTrailingPathDelimiter(GetHome) + ActiveWorkspaceName);
    ConfigureSandbox(Cfg.Sandbox, IncludeTrailingPathDelimiter(GetHome) + ActiveWorkspaceName);
    { serve mounts the same desktop routes as gateway, so a runtime switch
      must repoint the sandbox here too. }
    OnWorkspaceSwitched := RepointSandbox;
  end;
  ShellSessionId := '';
  Scheduler := nil;   { so the finally is safe if we Exit before starting it }
  try
    Args := ParseServe(Argv, Cfg);
    { Install the active shell backend so shell_exec / execute_code run on
      the backend the operator configured -- including docker. serve uses
      ONE container for the whole process (like the TUI): every /v1 request
      shares it, since the gateway has no per-request session lifecycle.
      That's coarser than per-tenant isolation but it does host the docker
      backend honestly instead of silently falling through to the host.
      Skip entirely when --no-tools (no shell dispatch at all). }
    if not Args.NoTools then
    begin
      try
        InstallShellBackend(Cfg, '', KindSelected, BackendDesc);
      except
        on E: Exception do
        begin
          PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + E.Message);
          Exit(1);
        end;
      end;
      { Lazy docker: allocate this server's single session id and point every
        turn's shell_exec/execute_code at it, but DON'T spawn the container
        now -- TDockerShellBackend.Exec spawns (and health-probes) it on the
        first shell tool call. So serve starts instantly even when Docker is
        down/slow/wedged; only chats that use a shell tool pay the cost, and
        any Docker error surfaces as that tool's result. The finally below
        still tears the container down (no-op if it was never spawned). }
      if KindSelected = sbDocker then
      begin
        ShellSessionId := NewSessionId;
        SetCurrentSessionId(ShellSessionId);
      end;
    end;

    { Stream-reliability env-var overrides. Lets operators tune
      UC_EMPTY_RETRY_ATTEMPTS / UC_EMPTY_RETRY_BACKOFF_MS /
      UC_STREAM_IDLE_TIMEOUT_SEC / UC_TOOL_CALL_REPAIR per-run
      without rewriting config.json. Env wins over config; defaults
      from TConfig.Create win otherwise. }
    Cfg.StreamReliability := LoadStreamReliabilityFromEnv(Cfg.StreamReliability);

    if Args.Debug then
    begin
      SetLogLevel(llDebug);
      LogDebug('serve: --debug enabled (logging every request + body)');
    end;

    Provider := nil;
    if Cfg.DefaultProvider <> '' then
      if not NewDefaultProvider(Cfg, Provider, Err) then
        LogWarn('serve: no provider -- /v1/chat/completions will return 503 (%s)', [Err]);

    Reg := nil;
    if not Args.NoTools then
    begin
      Reg := TToolRegistry.Create;
      RegisterFSTools(Reg, (not Args.NoHashline) and Cfg.HashlineEnabled);
      RegisterShellTool(Reg);
      RegisterExecuteCodeTool(Reg);
      RegisterMemoryTools(Reg);
      RegisterKBTools(Reg);
      RegisterDelphiBuildTool(Reg);   { self-gates on a discovered RAD Studio }
      RegisterSessionSearchTool(Reg);
      if HasConfiguredWebSearchProvider(Cfg) then
        RegisterWebSearchTool(Reg)
      else
        LogWebSearchSkipOnce;
      if Cfg.WebFetchEnabled then RegisterWebFetchTool(Reg);
      if Cfg.WebFetchEnabled then RegisterMemoryFetchTool(Reg);
      { Off by default -- onboarding opt-in flips Cfg.VaultToolsEnabled.
        Without this branch, `pasclaw onboard` could report
        "vault_search / vault_get enabled" but the gateway / serve
        chat surface would still tell the user "no Code Vault tool". }
      if Cfg.VaultToolsEnabled then RegisterVaultTools(Reg);
      { OR-gate: byte cap OR reversible condensation both stash
        handles the model needs tool_output_get to retrieve. }
      if (Cfg.ToolOutputCap > 0) or Cfg.CondenseReversible then
        RegisterOutputCacheTool(Reg);
      { send_message self-gates on Cfg.Channels. Codex P2 on PR #230. }
      RegisterSendMessageTool(Reg);
      { cron tool: opt-in (model-scheduled background jobs). Runs existing
        skills only; the running scheduler picks up its config edits live. }
      if Cfg.CronToolEnabled then RegisterCronTool(Reg);
      { project/task: opt-in, see Cmd.Gateway. }
      if Cfg.DesktopToolsEnabled then RegisterProjectTools(Reg);
      Skills := LoadSkillManifests(GetHome);
      RegisterSkills(Reg, Skills);
      SetDBConfigFromJSON(Cfg.DatabaseJSON);   { db_* connections (inert if no "database" section) }
      RegisterSkillManageTool(Reg, Cfg);
      RegisterSkillDisclosureTools(Reg, Cfg);
      if Length(Skills) > 0 then
        LogInfo('serve: loaded %d skill(s) from workspace/skills/', [Length(Skills)]);
    end;

    SetLength(MCPClients, 0);
    if (not Args.NoMCP) and (Reg <> nil) then
      MCPClients := ConnectMCPServers(Cfg, Reg);

    { Subagents (on by default): register spawn + background spawn tools so the
      served chat loop can fan out to the built-in general-purpose agent (and
      any configured subagents). No-op when subagents are disabled or there is
      no provider. Provider is captured at boot -- a later /v1/config provider
      swap won't repoint the subagent context (acceptable for v1). }
    if Reg <> nil then
      RegisterSubagentTools(Cfg, Provider, Reg, Cfg.DefaultModel);

    { Cron scheduler: serve had none before. Start it when crons exist OR
      the model can add them (cron_tool_enabled), so a cron the model
      schedules actually fires in this process. Codex P2 on PR #310. }
    Scheduler := nil;
    if (Reg <> nil) and ((Length(Cfg.Crons) > 0) or Cfg.CronToolEnabled) then
    begin
      Scheduler := TCronScheduler.Create(Cfg, Reg);
      Scheduler.Start;
    end;

    Server := TGatewayServer.Create(Cfg, Provider, Reg);
    Server.DebugIO := Args.Debug;
    Server.MaxIter := Args.MaxIter;
    Server.SetMCPAllowMutating(Args.MCPAllowWrite);

    { Optional companion listener dedicated to /mcp. When MCPPort is
      0 the main listener already serves /mcp alongside /v1/* on one
      port -- "live alongside the OpenAI-compat API". When non-zero,
      we spin a second TGatewayServer in MCP-only mode on that port
      so heavy /v1/responses streaming load can't compete with MCP
      requests for Indy worker threads. Both listeners share the
      same tool registry so they see exactly the same memory_search
      / kb_search / session_search results -- one source of truth. }
    MCPServer := nil;
    if Args.MCPPort > 0 then
    begin
      MCPServer := TGatewayServer.Create(Cfg, Provider, Reg);
      MCPServer.DebugIO := Args.Debug;
      MCPServer.SetMCPAllowMutating(Args.MCPAllowWrite);
      MCPServer.SetMCPOnly(True);
    end;
    try
      Server.Start(Args.Addr, Args.Port);
      if MCPServer <> nil then
        MCPServer.Start(Args.Addr, Args.MCPPort);

      BaseURL := Format('http://%s:%d/v1', [Args.Addr, Args.Port]);
      PrintLn(Ansi.Bold + 'OpenAI-compatible server up.' + Ansi.Reset);
      PrintLn('  base_url: ' + BaseURL);
      PrintLn('  model:    ' + Cfg.DefaultModel);
      PrintLn(Format('  max-iter: %d', [Args.MaxIter]));
      if MCPServer <> nil then
        PrintLn(Format('  mcp:      http://%s:%d/mcp (dedicated listener)',
                       [Args.Addr, Args.MCPPort]))
      else
        PrintLn(Format('  mcp:      http://%s:%d/mcp (mounted on main port)',
                       [Args.Addr, Args.Port]));
      if Args.MCPAllowWrite then
        PrintLn('            mutating tools EXPOSED to MCP clients (--mcp-allow-write)')
      else
        PrintLn('            read-only tools only -- pass --mcp-allow-write to flip');
      PrintLn;
      PrintLn(Ansi.Dim + '  Example (openai-python):' + Ansi.Reset);
      PrintLn('    client = OpenAI(base_url="' + BaseURL + '", api_key="sk-pasclaw")');
      PrintLn('    client.chat.completions.create(model="' + Cfg.DefaultModel +
              '", messages=[{"role":"user","content":"hi"}])');
      PrintLn;
      PrintLn(Ansi.Dim + '  Example (curl):' + Ansi.Reset);
      PrintLn('    curl ' + BaseURL + '/chat/completions -H "Content-Type: application/json" \');
      PrintLn('         -d ''{"model":"' + Cfg.DefaultModel +
              '","messages":[{"role":"user","content":"hi"}]}''');
      PrintLn;
      PrintLn(Ansi.Bold + 'Relay worker token: ' + Ansi.Reset +
              Ansi.Cyan + Server.RelayToken + Ansi.Reset +
              Ansi.Dim + '   (regenerated each start; unlocks /v1/relay/* only)' + Ansi.Reset);
      PrintLn(Ansi.Dim + 'Press Ctrl-C to stop.' + Ansi.Reset);

      Server.WaitForStop;
    finally
      Server.Stop;
      if MCPServer <> nil then MCPServer.Stop;
      Server.Free;
      if MCPServer <> nil then MCPServer.Free;
      { Stop the cron thread before tearing down the registry it fires
        jobs through (Free -> Destroy joins the thread). }
      if Scheduler <> nil then Scheduler.Free;
      FreeMCPClients(MCPClients);
      if Reg <> nil then Reg.Free;
    end;

    Result := 0;
  finally
    { Tear down the one shell container (no-op for local / unset). }
    if ShellSessionId <> '' then CloseShellSession(ShellSessionId);
    Cfg.Free;
  end;
end;

end.
