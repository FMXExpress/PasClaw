(*
  Gateway - starts the HTTP gateway, and optionally the Telegram channel
  alongside it. Blocks until SIGINT / Ctrl-C, then shuts down cleanly.

    pasclaw gateway                                 # just the HTTP API
    pasclaw gateway --telegram --token <BOT_TOKEN>  # API + Telegram bot
    pasclaw gateway --addr 0.0.0.0 --port 8088      # listen on all ifaces

  The HTTP API is documented in src/pkg/gateway/PasClaw.Gateway.Server.pas.
*)
unit PasClaw.Cmd.Gateway;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Gateway_Run(const Argv: array of string): Integer;

implementation

uses
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
  PasClaw.Tools.WebSearch,
  PasClaw.Search.Factory,
  PasClaw.Tools.WebFetch,
  PasClaw.Tools.MemoryFetch,
  PasClaw.Tools.Vault,
  PasClaw.Tools.OutputCache,
  PasClaw.Tools.Sandbox,
  PasClaw.Shell.Backend,    { TShellBackendKind + StartShellSession /
                              SetCurrentSessionId / CloseShellSession --
                              one container per gateway process }
  PasClaw.Shell.Backend.Factory,  { InstallShellBackend }
  PasClaw.Session.Store,    { NewSessionId for the shell session id }
  PasClaw.MCP.Bridge,
  PasClaw.Skills.Loader,
  PasClaw.Skills.Manage,
  PasClaw.Skills.Disclosure,
  PasClaw.Cron.Scheduler,
  PasClaw.Stream.Reliability,
  PasClaw.Agent.SubagentBg,   { RegisterSubagentTools -- spawn on the gateway loop }
  PasClaw.Gateway.Server,
  PasClaw.Channels.Telegram,
  PasClaw.Channels.LINE,
  PasClaw.Channels.WhatsApp,
  PasClaw.Channels.Matrix,
  PasClaw.Channels.IRC,
  PasClaw.Channels.Email;

type
  TGwArgs = record
    Addr:        string;
    Port:        Integer;
    Telegram:    Boolean;
    Token:       string;
    Line:        Boolean;
    LineToken:   string;
    LineSecret:  string;
    WhatsApp:    Boolean;
    WAToken:     string;
    WAPhoneId:   string;
    WAVerify:    string;
    WASecret:    string;
    Matrix:      Boolean;
    MatrixHome:  string;
    MatrixToken: string;
    IRC:         Boolean;
    IRCServer:   string;
    IRCPort:     Integer;
    IRCNick:     string;
    IRCChannel:  string;
    IRCPassword: string;
    Email:       Boolean;
    NoMCP:       Boolean;
    NoTools:     Boolean;
    NoHashline:  Boolean;
    { Inbound MCP server. Same shape as Cmd.Serve -- 0 means /mcp is
      mounted on the main listener alongside /v1/*; >0 spawns a
      second listener bound to that port serving /mcp only. Both
      share the gateway's tool registry so memory_search /
      kb_search / session_search are one source of truth. }
    MCPPort:        Integer;
    MCPAllowWrite:  Boolean;
  end;

function ParseGw(const Argv: array of string; const Cfg: TConfig): TGwArgs;
var
  i: Integer;
begin
  Result.Addr       := Cfg.Gateway.BindAddr;
  Result.Port       := Cfg.Gateway.Port;
  Result.Telegram   := False;
  Result.Token      := GetEnvironmentVariable('PASCLAW_TELEGRAM_TOKEN');
  Result.Line       := False;
  Result.LineToken  := GetEnvironmentVariable('PASCLAW_LINE_TOKEN');
  Result.LineSecret := GetEnvironmentVariable('PASCLAW_LINE_SECRET');
  Result.WhatsApp   := False;
  Result.WAToken    := GetEnvironmentVariable('PASCLAW_WHATSAPP_TOKEN');
  Result.WAPhoneId  := GetEnvironmentVariable('PASCLAW_WHATSAPP_PHONE_ID');
  Result.WAVerify   := GetEnvironmentVariable('PASCLAW_WHATSAPP_VERIFY_TOKEN');
  Result.WASecret   := GetEnvironmentVariable('PASCLAW_WHATSAPP_APP_SECRET');
  Result.Matrix     := False;
  Result.MatrixHome := GetEnvironmentVariable('PASCLAW_MATRIX_HOMESERVER');
  Result.MatrixToken := GetEnvironmentVariable('PASCLAW_MATRIX_TOKEN');
  Result.IRC        := False;
  Result.Email      := False;
  Result.IRCServer  := GetEnvironmentVariable('PASCLAW_IRC_SERVER');
  Result.IRCPort    := StrToIntDef(GetEnvironmentVariable('PASCLAW_IRC_PORT'), 6667);
  Result.IRCNick    := GetEnvironmentVariable('PASCLAW_IRC_NICK');
  Result.IRCChannel := GetEnvironmentVariable('PASCLAW_IRC_CHANNEL');
  Result.IRCPassword := GetEnvironmentVariable('PASCLAW_IRC_PASSWORD');
  Result.NoMCP         := False;
  Result.NoTools       := False;
  Result.NoHashline    := False;
  Result.MCPPort       := 0;
  Result.MCPAllowWrite := False;
  i := 0;
  while i <= High(Argv) do
  begin
    if Argv[i] = '--addr'         then begin if i < High(Argv) then Result.Addr     := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--port'         then begin if i < High(Argv) then Result.Port     := StrToIntDef(Argv[i + 1], Result.Port); Inc(i, 2); Continue; end;
    if Argv[i] = '--telegram'     then begin Result.Telegram   := True; Inc(i); Continue; end;
    if Argv[i] = '--token'        then begin if i < High(Argv) then Result.Token    := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--line'         then begin Result.Line       := True; Inc(i); Continue; end;
    if Argv[i] = '--line-token'   then begin if i < High(Argv) then Result.LineToken  := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--line-secret'  then begin if i < High(Argv) then Result.LineSecret := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--whatsapp'         then begin Result.WhatsApp  := True; Inc(i); Continue; end;
    if Argv[i] = '--whatsapp-token'   then begin if i < High(Argv) then Result.WAToken   := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--whatsapp-phone'   then begin if i < High(Argv) then Result.WAPhoneId := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--whatsapp-verify'  then begin if i < High(Argv) then Result.WAVerify  := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--whatsapp-secret'  then begin if i < High(Argv) then Result.WASecret  := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--matrix'          then begin Result.Matrix      := True; Inc(i); Continue; end;
    if Argv[i] = '--matrix-homeserver' then begin if i < High(Argv) then Result.MatrixHome  := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--matrix-token'    then begin if i < High(Argv) then Result.MatrixToken := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--irc'             then begin Result.IRC         := True; Inc(i); Continue; end;
    if Argv[i] = '--irc-server'      then begin if i < High(Argv) then Result.IRCServer   := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--irc-port'        then begin if i < High(Argv) then Result.IRCPort     := StrToIntDef(Argv[i + 1], Result.IRCPort); Inc(i, 2); Continue; end;
    if Argv[i] = '--irc-nick'        then begin if i < High(Argv) then Result.IRCNick     := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--irc-channel'     then begin if i < High(Argv) then Result.IRCChannel  := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--irc-password'    then begin if i < High(Argv) then Result.IRCPassword := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--email'        then begin Result.Email      := True; Inc(i); Continue; end;
    if Argv[i] = '--no-mcp'       then begin Result.NoMCP      := True; Inc(i); Continue; end;
    if Argv[i] = '--no-tools'     then begin Result.NoTools    := True; Inc(i); Continue; end;
    if Argv[i] = '--no-hashline'  then begin Result.NoHashline := True; Inc(i); Continue; end;
    if Argv[i] = '--mcp-port'     then begin if i < High(Argv) then Result.MCPPort := StrToIntDef(Argv[i + 1], 0); Inc(i, 2); Continue; end;
    if Argv[i] = '--mcp-allow-write' then begin Result.MCPAllowWrite := True; Inc(i); Continue; end;
    Inc(i);
  end;
end;

function Cmd_Gateway_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Args: TGwArgs;
  Provider: ILLMProvider;
  Err: string;
  Reg: TToolRegistry;
  MCPClients: TMCPClientList;
  Server, MCPServer: TGatewayServer;
  Telegram: TTelegramChannel;
  Line: TLineBot;
  WhatsApp: TWhatsAppBot;
  Matrix:   TMatrixBot;
  IRC:      TIRCBot;
  Email:    TEmailChannel;
  Scheduler: TCronScheduler;
  Skills: TSkillSpecArray;
  KindSelected: TShellBackendKind;
  BackendDesc, ShellSessionId: string;
  ProfileName: string;
  pi: Integer;
begin
  { Pre-scan for --profile so LoadConfig sees it. Profile selection
    has its own precedence chain (CLI > PASCLAW_PROFILE > config.json
    "profile" field); passing '' here lets LoadConfig fall through to
    the env/config-json layers. PR #291. }
  ProfileName := '';
  for pi := 0 to High(Argv) - 1 do
    if Argv[pi] = '--profile' then
    begin
      ProfileName := Argv[pi + 1];
      Break;
    end;
  Cfg := LoadConfig(ProfileName);
  { Default the working directory to $PASCLAW_HOME/workspace -- the dir the
    web UI Files tab browses -- rather than the launch CWD, so a relative
    write_file("index.html") lands where the operator sees it. An explicit
    sandbox.workspace still wins. }
  if Trim(Cfg.Sandbox.Workspace) <> '' then
    ConfigureSandbox(Cfg.Sandbox, '')
  else
    ConfigureSandbox(Cfg.Sandbox, IncludeTrailingPathDelimiter(GetHome) + 'workspace');
  ShellSessionId := '';
  try
    Args := ParseGw(Argv, Cfg);
    { Install the configured shell backend so shell_exec / execute_code run
      where the operator asked -- including docker. The gateway uses ONE
      container for the whole process (like the TUI): every request /
      channel message shares it, since there's no per-request session
      lifecycle here. That's coarser than per-tenant isolation but it hosts
      the docker backend honestly instead of falling through to the host.
      Skipped under --no-tools (no shell dispatch). }
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
      { Lazy docker (PR #286): allocate the gateway's single session id and
        point shell_exec/execute_code at it, but spawn the container on first
        use (TDockerShellBackend.Exec) instead of here -- the gateway starts
        instantly even when Docker is down/slow, and Docker errors surface on
        the first shell tool call. The finally still tears it down (no-op if
        never spawned). }
      if KindSelected = sbDocker then
      begin
        ShellSessionId := NewSessionId;
        SetCurrentSessionId(ShellSessionId);
      end;
    end;

    { Stream-reliability env-var overrides -- see Cmd.Serve for the
      same shape. Env wins over config; defaults from TConfig.Create
      win otherwise. }
    Cfg.StreamReliability := LoadStreamReliabilityFromEnv(Cfg.StreamReliability);

    Provider := nil;
    if Cfg.DefaultProvider <> '' then
      if not NewDefaultProvider(Cfg, Provider, Err) then
        LogWarn('gateway: no provider -- /v1/chat will return 503 (%s)', [Err]);

    Reg := nil;
    if not Args.NoTools then
    begin
      Reg := TToolRegistry.Create;
      RegisterFSTools(Reg, not Args.NoHashline);
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
        "vault_search / vault_get enabled" but the gateway / web UI
        chat surface would still tell the user "no Code Vault tool". }
      if Cfg.VaultToolsEnabled then RegisterVaultTools(Reg);
      { OR-gate: byte cap OR reversible condensation both stash
        handles the model needs tool_output_get to retrieve. }
      if (Cfg.ToolOutputCap > 0) or Cfg.CondenseReversible then
        RegisterOutputCacheTool(Reg);
      { send_message self-gates on Cfg.Channels. Codex P2 on PR #230. }
      RegisterSendMessageTool(Reg);
      if Cfg.CronToolEnabled then RegisterCronTool(Reg);
      Skills := LoadSkillManifests(GetHome);
      RegisterSkills(Reg, Skills);
      RegisterSkillManageTool(Reg, Cfg);
      RegisterSkillDisclosureTools(Reg, Cfg);
      if Length(Skills) > 0 then
        LogInfo('gateway: loaded %d skill(s) from workspace/skills/', [Length(Skills)]);
    end;

    SetLength(MCPClients, 0);
    if (not Args.NoMCP) and (Reg <> nil) then
      MCPClients := ConnectMCPServers(Cfg, Reg);

    { Subagents (on by default): register spawn + background spawn tools so the
      gateway chat loop (web UI / /v1/chat / OpenAI-compat) can fan out to the
      built-in general-purpose agent (and any configured subagents). No-op when
      disabled or no provider. Provider captured at boot -- a later /v1/config
      provider swap won't repoint the subagent context (acceptable for v1). }
    if Reg <> nil then
      RegisterSubagentTools(Cfg, Provider, Reg, Cfg.DefaultModel);

    { Start the scheduler when there are crons OR the model can add them
      (cron_tool_enabled) -- otherwise an empty-config server with the cron
      tool on would accept an add but never fire it until restart. Codex P2
      on PR #310. }
    Scheduler := nil;
    if (Reg <> nil) and ((Length(Cfg.Crons) > 0) or Cfg.CronToolEnabled) then
    begin
      Scheduler := TCronScheduler.Create(Cfg, Reg);
      Scheduler.Start;
    end;

    Server := TGatewayServer.Create(Cfg, Provider, Reg);
    Server.SetMCPAllowMutating(Args.MCPAllowWrite);
    { Optional /mcp companion listener. See the long-form comment in
      Cmd.Serve for the same wiring -- one source of truth for the
      tool registry, two HTTP listeners when isolation matters. }
    MCPServer := nil;
    if Args.MCPPort > 0 then
    begin
      MCPServer := TGatewayServer.Create(Cfg, Provider, Reg);
      MCPServer.SetMCPAllowMutating(Args.MCPAllowWrite);
      MCPServer.SetMCPOnly(True);
    end;
    Telegram := nil;
    Line     := nil;
    WhatsApp := nil;
    Matrix   := nil;
    IRC      := nil;
    Email    := nil;
    try
      if Args.Line then
      begin
        if (Args.LineToken = '') or (Args.LineSecret = '') then
        begin
          LogError('line: need both --line-token / $PASCLAW_LINE_TOKEN and ' +
                   '--line-secret / $PASCLAW_LINE_SECRET');
          Exit(1);
        end;
        Line := TLineBot.Create(Args.LineToken, Args.LineSecret,
                                Cfg, Provider, Reg);
        Server.MountWebhook('/webhooks/line', Line.HandleWebhook);
      end;

      if Args.WhatsApp then
      begin
        if (Args.WAToken = '') or (Args.WAPhoneId = '') or
           (Args.WAVerify = '') or (Args.WASecret = '') then
        begin
          LogError('whatsapp: need all four -- --whatsapp-token / ' +
                   '$PASCLAW_WHATSAPP_TOKEN, --whatsapp-phone / ' +
                   '$PASCLAW_WHATSAPP_PHONE_ID, --whatsapp-verify / ' +
                   '$PASCLAW_WHATSAPP_VERIFY_TOKEN, --whatsapp-secret / ' +
                   '$PASCLAW_WHATSAPP_APP_SECRET');
          Exit(1);
        end;
        WhatsApp := TWhatsAppBot.Create(Args.WAToken, Args.WAPhoneId,
                                         Args.WAVerify, Args.WASecret,
                                         Cfg, Provider, Reg);
        Server.MountWebhook('/webhooks/whatsapp', WhatsApp.HandleWebhook);
      end;

      if Args.Matrix then
      begin
        if (Args.MatrixHome = '') or (Args.MatrixToken = '') then
        begin
          LogError('matrix: need --matrix-homeserver / $PASCLAW_MATRIX_HOMESERVER ' +
                   'and --matrix-token / $PASCLAW_MATRIX_TOKEN');
          Exit(1);
        end;
        Matrix := TMatrixBot.Create(Args.MatrixHome, Args.MatrixToken,
                                     Cfg, Provider, Reg);
        Matrix.Start;
      end;

      if Args.IRC then
      begin
        if (Args.IRCServer = '') or (Args.IRCNick = '') then
        begin
          LogError('irc: need --irc-server / $PASCLAW_IRC_SERVER and ' +
                   '--irc-nick / $PASCLAW_IRC_NICK');
          Exit(1);
        end;
        IRC := TIRCBot.Create(Args.IRCServer, Args.IRCPort,
                               Args.IRCNick, Args.IRCChannel, Args.IRCPassword,
                               Cfg, Provider, Reg);
        IRC.Start;
      end;

      if Args.Email then
      begin
        Email := TEmailChannel.Create(Cfg, Provider, Reg);
        Email.Spawn;  { runs Email.Run on a dedicated TThread }
      end;

      Server.Start(Args.Addr, Args.Port);
      if MCPServer <> nil then
        MCPServer.Start(Args.Addr, Args.MCPPort);

      PrintLn(Ansi.Bold + 'Gateway up.' + Ansi.Reset);
      PrintLn(Format('  http://%s:%d/v1/health', [Args.Addr, Args.Port]));
      PrintLn(Format('  http://%s:%d/v1/tools',  [Args.Addr, Args.Port]));
      PrintLn(Format('  POST http://%s:%d/v1/chat   {"message":"..."}',
                     [Args.Addr, Args.Port]));
      if MCPServer <> nil then
        PrintLn(Format('  POST http://%s:%d/mcp   (dedicated MCP listener)',
                       [Args.Addr, Args.MCPPort]))
      else
        PrintLn(Format('  POST http://%s:%d/mcp   (alongside /v1/*)',
                       [Args.Addr, Args.Port]));
      if Args.Line then
        PrintLn(Format('  POST http://%s:%d/webhooks/line   (LINE platform)',
                       [Args.Addr, Args.Port]));
      if Args.WhatsApp then
        PrintLn(Format('  ANY http://%s:%d/webhooks/whatsapp   (WhatsApp Cloud)',
                       [Args.Addr, Args.Port]));
      if Args.Matrix then
        PrintLn('  matrix sync ' + Args.MatrixHome + '  (Matrix homeserver)');
      if Args.IRC then
        PrintLn(Format('  irc %s:%d %s joining %s',
                       [Args.IRCServer, Args.IRCPort, Args.IRCNick, Args.IRCChannel]));
      PrintLn('');
      PrintLn(Ansi.Bold + 'Relay worker token: ' + Ansi.Reset +
              Ansi.Cyan + Server.RelayToken + Ansi.Reset +
              Ansi.Dim + '   (regenerated each start; unlocks /v1/relay/* only)' + Ansi.Reset);
      PrintLn(Ansi.Dim + 'Press Ctrl-C to stop.' + Ansi.Reset);

      if Args.Telegram then
      begin
        if Args.Token = '' then
        begin
          LogError('telegram: no token; set PASCLAW_TELEGRAM_TOKEN or pass --token');
          Exit(1);
        end;
        Telegram := TTelegramChannel.Create(Args.Token, Cfg, Provider, Reg);
        { Long-poll runs on the current thread and blocks; for Phase 5 we
          accept that the HTTP listener and Telegram coexist (Indy listens on
          its own threads), so we just call Telegram.Run last. }
        Telegram.Run;
      end
      else
        Server.WaitForStop;
    finally
      if Telegram <> nil then Telegram.Free;
      if Line     <> nil then Line.Free;
      if WhatsApp <> nil then WhatsApp.Free;
      if Matrix   <> nil then begin Matrix.RequestStop; Matrix.WaitForStop; Matrix.Free; end;
      if IRC      <> nil then IRC.Free;
      if Email    <> nil then begin Email.Stop; Email.Free; end;
      Server.Stop;
      if MCPServer <> nil then MCPServer.Stop;
      Server.Free;
      if MCPServer <> nil then MCPServer.Free;
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
