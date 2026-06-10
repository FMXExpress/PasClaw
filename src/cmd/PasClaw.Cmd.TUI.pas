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
  PasClaw.Tools.SessionSearch,
  PasClaw.Tools.WebSearch,
  PasClaw.Search.Factory,
  PasClaw.Tools.WebFetch,
  PasClaw.Tools.MemoryFetch,
  PasClaw.Tools.OutputCache,
  PasClaw.Tools.Sandbox,
  PasClaw.MCP.Bridge,
  PasClaw.Skills.Loader,
  PasClaw.TUI;

type
  TTUIArgs = record
    Model:       string;
    Provider:    string;
    Session:     string;
    Theme:       string;
    NoMCP:       Boolean;
    NoTools:     Boolean;
    NoHashline:  Boolean;
  end;

function ParseArgs(const Argv: array of string; var A: TTUIArgs): Boolean;
var
  i: Integer;
begin
  Result := True;
  A.Model := ''; A.Provider := ''; A.Session := ''; A.Theme := '';
  A.NoMCP := False; A.NoTools := False; A.NoHashline := False;
  i := 0;
  while i <= High(Argv) do
  begin
    if Argv[i] = '--model'        then begin if i = High(Argv) then Exit(False); A.Model    := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--provider'     then begin if i = High(Argv) then Exit(False); A.Provider := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--session'      then begin if i = High(Argv) then Exit(False); A.Session  := Argv[i + 1]; Inc(i, 2); Continue; end;
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
begin
  if not ParseArgs(Argv, A) then Exit(1);
  Cfg := LoadConfig;
  ConfigureSandbox(Cfg.Sandbox, '');
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
      if Cfg.ToolOutputCap > 0 then RegisterOutputCacheTool(Reg);
      Skills := LoadSkillManifests(GetHome);
      RegisterSkills(Reg, Skills);
    end;

    SetLength(MCPClients, 0);
    if (Reg <> nil) and (not A.NoMCP) then
      MCPClients := ConnectMCPServers(Cfg, Reg);

    if A.Model <> '' then Model := A.Model else Model := Cfg.DefaultModel;
    TUIInst := TTUI.Create(Provider, Reg, Model);
    TUIInst.PromptCacheEnabled := Cfg.PromptCache.Enabled;
    TUIInst.PromptCacheTTL     := Cfg.PromptCache.TTL;
    TUIInst.SessionId          := A.Session;
    TUIInst.ThemeName          := A.Theme;
    TUIInst.RenderMarkdownEnabled := Cfg.RenderMarkdown;
    try
      TUIInst.Run;
    finally
      TUIInst.Free;
      FreeMCPClients(MCPClients);
      if Reg <> nil then Reg.Free;
    end;
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
