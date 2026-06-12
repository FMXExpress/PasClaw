(*
  TUI - full-terminal interactive chat front-end.

    pasclaw tui [--provider P] [--model M]
*)
unit PasClaw.Cmd.TUI;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_TUI_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Factory,
  PasClaw.Tools.Registry,
  PasClaw.Tools.FS,
  PasClaw.Tools.Shell,
  PasClaw.Tools.ExecuteCode,
  PasClaw.Tools.Memory,
  PasClaw.Tools.KB,
  PasClaw.Tools.SessionSearch,
  PasClaw.Tools.SendMessage,
  PasClaw.Tools.WebSearch,
  PasClaw.Search.Factory,
  PasClaw.Tools.WebFetch,
  PasClaw.Tools.MemoryFetch,
  PasClaw.Tools.OutputCache,
  PasClaw.Tools.Sandbox,
  PasClaw.Shell.Backend,           { StartShellSession / SetCurrentSessionId
                                     -- same session-lifecycle hooks as Cmd.Agent }
  PasClaw.Shell.Backend.Factory,   { InstallShellBackend }
  PasClaw.MCP.Bridge,
  PasClaw.Skills.Loader,
  PasClaw.Agent.Subagent,
  PasClaw.Agent.SubagentBg,
  PasClaw.TUI;

type
  TTUIArgs = record
    Model:           string;
    Provider:        string;
    Session:         string;
    Theme:           string;
    NoMCP:           Boolean;
    NoTools:         Boolean;
    NoHashline:      Boolean;
    BackendOverride: string;
  end;

function ParseArgs(const Argv: array of string; var A: TTUIArgs): Boolean;
var
  i: Integer;
begin
  Result := True;
  A.Model := ''; A.Provider := ''; A.Session := ''; A.Theme := '';
  A.NoMCP := False; A.NoTools := False; A.NoHashline := False;
  A.BackendOverride := '';
  i := 0;
  while i <= High(Argv) do
  begin
    if Argv[i] = '--model'        then begin if i = High(Argv) then Exit(False); A.Model    := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--provider'     then begin if i = High(Argv) then Exit(False); A.Provider := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--session'      then begin if i = High(Argv) then Exit(False); A.Session  := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--backend'      then begin if i = High(Argv) then Exit(False); A.BackendOverride := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--theme'        then begin if i = High(Argv) then Exit(False); A.Theme    := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--no-mcp'       then begin A.NoMCP      := True; Inc(i); Continue; end;
    if Argv[i] = '--no-tools'     then begin A.NoTools    := True; Inc(i); Continue; end;
    if Argv[i] = '--no-hashline'  then begin A.NoHashline := True; Inc(i); Continue; end;
    Inc(i);
  end;
end;

function Cmd_TUI_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  A: TTUIArgs;
  Provider: ILLMProvider;
  Err: string;
  Reg: TToolRegistry;
  MCPClients: TMCPClientList;
  Skills: TSkillSpecArray;
  Model, Name: string;
  TUIInst: TTUI;
  SubCtx: TSubagentContext;
  Spawn: TSpawnTool;
  BgCoord: TBackgroundSpawnCoordinator;
  KindSelected: TShellBackendKind;
  BackendDesc: string;
begin
  if not ParseArgs(Argv, A) then Exit(1);
  Cfg := LoadConfig;
  ConfigureSandbox(Cfg.Sandbox, '');
  { Phase 1 docker backend is wired for the agent + heartbeat
    surfaces; TUI's in-process session switching (/new, /load) needs
    a per-switch container handoff that's a Phase 1.5 follow-up.
    Until then, install only the local backend on TUI and refuse a
    docker selection loudly so the operator isn't silently running
    on the host when they thought they had isolation. }
  if (LowerCase(A.BackendOverride) = 'docker')
     or ((A.BackendOverride = '') and (Cfg.ShellBackend = sbDocker)) then
  begin
    PrintLn(Ansi.Yellow + '!' + Ansi.Reset +
            ' TUI does not yet support the docker shell backend.');
    PrintLn('  Use ' + Ansi.Bold + 'pasclaw agent' + Ansi.Reset +
            ' for an interactive docker-backed session, or pass ' +
            Ansi.Bold + '--backend local' + Ansi.Reset + '.');
    Exit(1);
  end;
  try
    InstallShellBackend(Cfg, A.BackendOverride, KindSelected, BackendDesc);
  except
    on E: Exception do
    begin
      PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + E.Message);
      Exit(1);
    end;
  end;
  try
    if A.Provider <> '' then Name := A.Provider else Name := Cfg.DefaultProvider;
    Provider := nil;
    if Name <> '' then
      if not NewProviderFromConfig(Cfg, Name, Provider, Err) then
        LogWarn('tui: provider unavailable (%s)', [Err]);

    Reg := nil;
    if not A.NoTools then
    begin
      Reg := TToolRegistry.Create;
      RegisterFSTools(Reg, not A.NoHashline);
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
      { memory_fetch shares the WebFetch gate -- same HTTP path,
        same SSRF semantics, no point exposing one without the other. }
      if Cfg.WebFetchEnabled then RegisterMemoryFetchTool(Reg);
      { tool_output_get is only useful when the truncation feature is
        on -- otherwise the model sees a tool it'd only call against
        non-existent handles. Pair the registration with the cap. }
      { OR-gate: byte cap OR reversible condensation both stash
        handles the model needs tool_output_get to retrieve. }
      if (Cfg.ToolOutputCap > 0) or Cfg.CondenseReversible then
        RegisterOutputCacheTool(Reg);
      { send_message self-gates on Cfg.Channels being non-empty.
        Codex P2 on PR #230: every chat surface (CLI, TUI, Serve,
        Gateway, embedder) builds its own registry and must register
        this tool independently, otherwise the documented channel-
        notification tool is silently missing on the surface the
        operator actually uses. }
      RegisterSendMessageTool(Reg);
      Skills := LoadSkillManifests(GetHome);
      RegisterSkills(Reg, Skills);
    end;

    SetLength(MCPClients, 0);
    if (Reg <> nil) and (not A.NoMCP) then
      MCPClients := ConnectMCPServers(Cfg, Reg);

    if A.Model <> '' then Model := A.Model else Model := Cfg.DefaultModel;

    { Subagents: register sync `spawn` + the background quartet
      (spawn_background / status / wait / cancel) when config.json
      declares any. Registered AFTER MCP connect -- same ordering
      as Cmd.Agent -- so subagent tool allowlists can include
      MCP-bridged tools. The TUI gets the coordinator reference so
      StartTurn can bind it to the active session each turn. }
    Spawn   := nil;
    BgCoord := nil;
    if (Reg <> nil) and (Provider <> nil) and (Length(Cfg.Subagents) > 0) then
    begin
      SubCtx.Provider       := Provider;
      SubCtx.Fallbacks      := ResolveFallbacks(Cfg);
      SubCtx.ParentRegistry := Reg;
      SubCtx.DefaultModel   := Model;
      SubCtx.PromptCache    := Cfg.PromptCache;
      Spawn   := RegisterSpawnTool(Reg, SubCtx, Cfg.Subagents);
      BgCoord := RegisterBackgroundSpawnTools(Reg, SubCtx, Cfg.Subagents);
    end;

    TUIInst := TTUI.Create(Provider, Reg, Model);
    TUIInst.PromptCacheEnabled := Cfg.PromptCache.Enabled;
    TUIInst.PromptCacheTTL     := Cfg.PromptCache.TTL;
    TUIInst.SessionId          := A.Session;
    TUIInst.ThemeName          := A.Theme;
    TUIInst.RenderMarkdownEnabled := Cfg.RenderMarkdown;
    TUIInst.CheckpointsEnabled    := Cfg.CheckpointsEnabled;
    TUIInst.CheckpointsKeepLast   := Cfg.CheckpointsKeepLast;
    TUIInst.BgCoordinator      := BgCoord;
    try
      TUIInst.Run;
    finally
      TUIInst.Free;
      FreeMCPClients(MCPClients);
      { Spawn owned here (same shape as Cmd.Agent); BgCoord is NOT
        freed here -- PasClaw.Agent.SubagentBg's finalization reaps
        coordinators, and a double-free would race its teardown of
        still-running job threads. }
      if Spawn <> nil then Spawn.Free;
      if Reg <> nil then Reg.Free;
    end;
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
