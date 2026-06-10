(*
  serve - Start the OpenAI-compatible API server.

    pasclaw serve                         # default bind/port from config
    pasclaw serve --addr 0.0.0.0 --port 8088
    pasclaw serve --no-tools              # disable built-in tool registry
    pasclaw serve --no-mcp                # skip MCP server discovery
    pasclaw serve --debug                 # log every request + response body
    pasclaw serve --max-iter 40           # raise the tool-loop cap (default 25)
    pasclaw serve --no-hashline           # raw fs_read; skip fs_edit_hashline + fs_grep

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
  PasClaw.Tools.SessionSearch,
  PasClaw.Tools.WebSearch,
  PasClaw.Search.Factory,
  PasClaw.Tools.WebFetch,
  PasClaw.Tools.MemoryFetch,
  PasClaw.Tools.Vault,
  PasClaw.Tools.OutputCache,
  PasClaw.Tools.Sandbox,
  PasClaw.MCP.Bridge,
  PasClaw.Skills.Loader,
  PasClaw.Stream.Reliability,
  PasClaw.Gateway.Server;

type
  TServeArgs = record
    Addr:        string;
    Port:        Integer;
    NoMCP:       Boolean;
    NoTools:     Boolean;
    Debug:       Boolean;
    MaxIter:     Integer;
    NoHashline:  Boolean;
  end;

function ParseServe(const Argv: array of string; const Cfg: TConfig): TServeArgs;
var
  i: Integer;
begin
  Result.Addr       := Cfg.Gateway.BindAddr;
  Result.Port       := Cfg.Gateway.Port;
  Result.NoMCP      := False;
  Result.NoTools    := False;
  Result.Debug      := False;
  Result.MaxIter    := 25;  { matches TGatewayServer.Create default }
  Result.NoHashline := False;
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
    Inc(i);
  end;
  if Result.MaxIter < 1 then Result.MaxIter := 1;
end;

function Cmd_Serve_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Args: TServeArgs;
  Provider: ILLMProvider;
  Err: string;
  Reg: TToolRegistry;
  MCPClients: TMCPClientList;
  Server: TGatewayServer;
  Skills: TSkillSpecArray;
  BaseURL: string;
begin
  Cfg := LoadConfig;
  ConfigureSandbox(Cfg.Sandbox, '');
  try
    Args := ParseServe(Argv, Cfg);

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
      RegisterFSTools(Reg, not Args.NoHashline);
      RegisterShellTool(Reg);
      RegisterExecuteCodeTool(Reg);
      RegisterMemoryTools(Reg);
      RegisterKBTools(Reg);
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
      if Cfg.ToolOutputCap > 0 then RegisterOutputCacheTool(Reg);
      Skills := LoadSkillManifests(GetHome);
      RegisterSkills(Reg, Skills);
      if Length(Skills) > 0 then
        LogInfo('serve: loaded %d skill(s) from workspace/skills/', [Length(Skills)]);
    end;

    SetLength(MCPClients, 0);
    if (not Args.NoMCP) and (Reg <> nil) then
      MCPClients := ConnectMCPServers(Cfg, Reg);

    Server := TGatewayServer.Create(Cfg, Provider, Reg);
    Server.DebugIO := Args.Debug;
    Server.MaxIter := Args.MaxIter;
    try
      Server.Start(Args.Addr, Args.Port);

      BaseURL := Format('http://%s:%d/v1', [Args.Addr, Args.Port]);
      PrintLn(Ansi.Bold + 'OpenAI-compatible server up.' + Ansi.Reset);
      PrintLn('  base_url: ' + BaseURL);
      PrintLn('  model:    ' + Cfg.DefaultModel);
      PrintLn(Format('  max-iter: %d', [Args.MaxIter]));
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
      PrintLn(Ansi.Dim + 'Press Ctrl-C to stop.' + Ansi.Reset);

      Server.WaitForStop;
    finally
      Server.Stop;
      Server.Free;
      FreeMCPClients(MCPClients);
      if Reg <> nil then Reg.Free;
    end;

    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
