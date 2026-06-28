(*
  SampleConfigured — configure PasClaw entirely in code, no config.json.

  A *reference* sample: it touches every configurable surface the component
  exposes, so you can see how to express in code anything `pasclaw onboard`
  (or a hand-edited config.json) would set. The two enablers are:

    1. LoadConfigFromDisk := False  -> start from clean TConfig defaults,
       ignoring ~/.pasclaw/config.json (no disk dependency).
    2. Config : TConfig             -> the live config (never nil after
       Create); mutate ANY field before the first Chat/Run.

  Most of these are shown set to a value near their default just to document
  the field — flip them to taste. Build (FPC):

    cd samples/component-console
    make configured

  Runtime:
    export ANTHROPIC_API_KEY=sk-ant-...
    export GROQ_API_KEY=gsk-...        # optional: enables the fallback + router
    ./build/SampleConfigured
*)
program SampleConfigured;

{$APPTYPE CONSOLE}
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Config,          { TConfig + every nested config record }
  PasClaw.Shell.Backend,   { TShellBackendKind: sbLocal / sbDocker }
  PasClaw.Agent,           { TPasClawAgent + the On* event types }
  PasClaw.Tools;           { TWebSearchTool / TWebFetchTool / TFileSystemTool }

type
  { The component's four callbacks are `of object`, so they need methods. }
  TDemoHandlers = class
    procedure OnText(Sender: TObject; const Text: string);
    procedure OnToolCall(Sender: TObject; const Name, ArgsJSON: string);
    procedure OnToolResult(Sender: TObject; const Name, ResultText, Err: string);
    procedure OnError(Sender: TObject; const Msg: string);
  end;

procedure TDemoHandlers.OnText(Sender: TObject; const Text: string);
begin Write(Text); end;

procedure TDemoHandlers.OnToolCall(Sender: TObject; const Name, ArgsJSON: string);
begin WriteLn('  > tool ', Name); end;

procedure TDemoHandlers.OnToolResult(Sender: TObject; const Name, ResultText, Err: string);
begin if Err <> '' then WriteLn('  ! ', Name, ': ', Err); end;

procedure TDemoHandlers.OnError(Sender: TObject; const Msg: string);
begin WriteLn('  ERROR: ', Msg); end;

var
  Agent:   TPasClawAgent;
  C:       TConfig;
  H:       TDemoHandlers;
  ApiKey, GroqKey: string;
  n: Integer;
begin
  ApiKey := GetEnvironmentVariable('ANTHROPIC_API_KEY');
  if ApiKey = '' then
  begin
    WriteLn('ANTHROPIC_API_KEY not set — export it and re-run.');
    Halt(2);
  end;
  GroqKey := GetEnvironmentVariable('GROQ_API_KEY');

  H     := TDemoHandlers.Create;
  Agent := TPasClawAgent.Create('claude-opus-4-7');   { sets Model }
  try
    { ===== Component-level properties ===== }
    Agent.LoadConfigFromDisk := False;   { start from defaults, no disk }
    Agent.ProviderName       := '';      { '' = use Config.DefaultProvider }
    Agent.SystemPrompt       := 'You are a concise Free Pascal expert.';
    Agent.MaxIterations      := 25;      { tool-loop cap for this agent }
    Agent.UseTools           := True;    { register the built-in tool set }
    Agent.UseMCP             := True;    { connect configured MCP servers }
    Agent.UseHashline        := True;    { hashline fs_read/fs_edit format }
    Agent.OnText             := H.OnText;
    Agent.OnToolCall         := H.OnToolCall;
    Agent.OnToolResult       := H.OnToolResult;
    Agent.OnError            := H.OnError;

    { ===== Primary provider (sets Providers[]/DefaultProvider/DefaultModel) ===== }
    Agent.SetProvider('anthropic', ApiKey, 'claude-opus-4-7');

    C := Agent.Config;

    { ===== Top-level feature toggles (TConfig scalars) ===== }
    C.MCPProgressiveDisclosure := True;   { lazy-reveal MCP tools via tool_search }
    C.VaultToolsEnabled        := True;   { vault_search / vault_get }
    C.WebFetchEnabled          := True;   { web_fetch + memory_fetch }
    C.CronToolEnabled          := False;  { let the model schedule crons }
    C.RelayWaitTimeoutMs       := 0;      { 0 = built-in default (5 min) }
    C.VectorSearchEnabled      := True;   { hybrid (FTS+vector) memory_search }
    C.RenderMarkdown           := True;   { ANSI-render the reply in a terminal }
    C.ToolOutputCap            := 8192;   { divert oversized tool output to cache }
    C.StatsCollectionEnabled   := True;   { persist per-session usage counters }
    C.CheckpointsEnabled       := True;   { per-edit snapshots for /undo }
    C.CheckpointsKeepLast      := 32;     { 0 = default (32) }
    C.MemoryDistillEnabled     := True;   { distil durable facts each turn }
    C.MemoryFactsBudget        := 2000;   { byte budget for the facts block }
    C.PromptwareEnabled        := True;   { prompt-injection scan banner }
    C.OrientTaskAware          := True;   { task-aware MEMORY slicing + plan preamble }
    C.CondenseReversible       := False;  { reversible condensation (CCR) }
    C.HashlineEnabled          := True;   { gates fs_edit_hashline + fs_read format }
    C.ShellBackend             := sbLocal;{ sbLocal | sbDocker }
    { C.Profile is a persisted profile selector for the disk path; leave '' here. }

    { ===== Sandbox policy ===== }
    C.Sandbox.RestrictToWorkspace       := False; { lock fs/shell to Workspace }
    C.Sandbox.AllowReadOutsideWorkspace := False; { soften reads under restriction }
    C.Sandbox.Workspace                 := GetCurrentDir; { '' = cwd at tool-config time }
    C.Sandbox.ShellDenyEnabled          := True;  { built-in shell denylist }
    C.Sandbox.BlockPrivateNetworks      := True;  { SSRF guard for web_fetch }
    SetLength(C.Sandbox.AllowReadPaths, 1);  C.Sandbox.AllowReadPaths[0]  := '/usr/include/*';
    SetLength(C.Sandbox.AllowWritePaths, 1); C.Sandbox.AllowWritePaths[0] := '/tmp/*';
    SetLength(C.Sandbox.CustomShellDeny, 1); C.Sandbox.CustomShellDeny[0] := 'terraform destroy';

    { ===== Gateway (only relevant for TPasClawServer; shown for completeness) ===== }
    C.Gateway.LogLevel := 'info';
    C.Gateway.BindAddr := '127.0.0.1';
    C.Gateway.Port     := 8088;
    C.Gateway.Token    := '';   { '' = no bearer auth }

    { ===== OpenTelemetry diagnostics ===== }
    C.Diagnostics.Otel.Enabled     := False;
    C.Diagnostics.Otel.Endpoint    := 'http://localhost:4318';
    C.Diagnostics.Otel.Protocol    := 'http/json';
    C.Diagnostics.Otel.ServiceName := 'pasclaw-embed';
    C.Diagnostics.Otel.SampleRate  := 1.0;
    C.Diagnostics.Otel.Traces      := True;
    C.Diagnostics.Otel.Metrics     := False;
    C.Diagnostics.Otel.Logs        := False;
    SetLength(C.Diagnostics.Otel.Headers, 1);
    C.Diagnostics.Otel.Headers[0].Name  := 'x-honeycomb-team';
    C.Diagnostics.Otel.Headers[0].Value := '';

    { ===== Heartbeat (proactive periodic wake-up) ===== }
    C.Heartbeat.Enabled      := False;
    C.Heartbeat.IntervalMins := 30;
    C.Heartbeat.ContentPath  := '';   { '' = <home>/workspace/heartbeat.md }
    C.Heartbeat.Channel      := '';   { named channel to post to; '' = log-only }

    { ===== Docker shell-backend options (used when ShellBackend = sbDocker) ===== }
    C.ShellBackendDocker.Image      := 'debian:bookworm-slim';
    C.ShellBackendDocker.Network    := 'bridge';   { bridge | host | none }
    C.ShellBackendDocker.User       := '';
    C.ShellBackendDocker.Privileged := False;

    { ===== web_search tool provider =====
      NOTE: the registered web_search tool resolves its provider by calling
      LoadConfig itself (~/.pasclaw/config.json + $PASCLAW_<KIND>_API_KEY env)
      on each invocation -- it does NOT read Agent.Config. So in this no-disk
      sample these fields are reference-only; to actually switch web_search to
      Brave/Tavily, set them in config.json or the env, not here. }
    C.WebSearch.Provider   := 'duckduckgo';  { duckduckgo|brave|tavily|searxng|perplexity }
    C.WebSearch.APIKey     := '';
    C.WebSearch.BaseURL    := '';            { required only for self-hosted searxng }
    C.WebSearch.MaxResults := 10;

    { ===== Provider-side prompt caching ===== }
    C.PromptCache.Enabled := True;
    C.PromptCache.TTL     := '';   { '' = 5m; '1h' = extended (Anthropic) }

    { ===== Stream reliability ===== }
    C.StreamReliability.EmptyRetryAttempts    := 2;
    C.StreamReliability.EmptyRetryBackoffMs   := 750;
    C.StreamReliability.StreamIdleTimeoutMs   := 150000;
    C.StreamReliability.ToolCallRepairEnabled := True;

    { ===== Provider-native server tools ===== }
    C.AnthropicServerTools.WebSearch        := False;
    C.AnthropicServerTools.WebSearchMaxUses := 5;
    C.AnthropicServerTools.WebFetch         := False;
    C.AnthropicServerTools.WebFetchMaxUses  := 5;
    C.OpenAIServerTools.WebSearch           := False;
    C.GeminiServerTools.GoogleSearch        := True;

    { ===== Self-improving (agent-authored) skills ===== }
    C.SelfImprovingSkills.SelfManage            := False;
    C.SelfImprovingSkills.ProgressiveDisclosure := False;
    C.SelfImprovingSkills.AutoApprove           := False;
    SetLength(C.SelfImprovingSkills.GuardDeny, 1);
    C.SelfImprovingSkills.GuardDeny[0]          := 'rm -rf /';
    C.SelfImprovingSkills.Distiller.Enabled      := False;
    C.SelfImprovingSkills.Distiller.MinToolCalls := 5;
    C.SelfImprovingSkills.Distiller.Model        := '';   { '' = the turn's model }

    { ===== Arrays: one example entry each ===== }
    { Cheap fallback provider + task-difficulty router (only with a key).
      The Fallbacks chain IS honoured by the embedded component (ResolveFallbacks
      is wired into ChatHistory) -- it retries 'groq' when the primary errors.
      The AutoRouter, however, is applied only by the `pasclaw agent` CLI
      (PasClaw.Agent.AutoRouter.RouteProvider); TPasClawAgent.Run does NOT route,
      so the fields below are reference-only for an embedder -- Run always uses
      the primary provider even for "easy" prompts. }
    if GroqKey <> '' then
    begin
      n := Length(C.Providers);
      SetLength(C.Providers, n + 1);
      C.Providers[n].Name   := 'groq';
      C.Providers[n].Kind   := 'groq';
      C.Providers[n].APIKey := GroqKey;
      C.Providers[n].Model  := 'llama-3.3-70b-versatile';
      SetLength(C.Fallbacks, 1);
      C.Fallbacks[0] := 'groq';        { used: retry chain on primary error }
      C.AutoRouter.Enabled       := True;  { CLI-only -- see note above }
      C.AutoRouter.EasyProvider  := 'groq';
      C.AutoRouter.EasyModel     := '';     { '' = that provider's default }
      C.AutoRouter.EasyMaxTokens := 500;
    end;

    { An MCP server (disabled here so the sample doesn't try to spawn it). }
    SetLength(C.MCPServers, 1);
    C.MCPServers[0].Name    := 'fs';
    C.MCPServers[0].Cmd     := 'npx';
    C.MCPServers[0].Args    := '-y @modelcontextprotocol/server-filesystem .';
    C.MCPServers[0].Env     := '';
    C.MCPServers[0].Enabled := False;

    { A named subagent the model can fan out to via the spawn tool. }
    SetLength(C.Subagents, 1);
    C.Subagents[0].Name         := 'researcher';
    C.Subagents[0].Description  := 'Read-only code/document researcher.';
    C.Subagents[0].SystemPrompt := 'Investigate and report; do not modify files.';
    SetLength(C.Subagents[0].Tools, 2);
    C.Subagents[0].Tools[0] := 'fs_read';
    C.Subagents[0].Tools[1] := 'fs_grep';
    C.Subagents[0].Model    := '';   { '' = inherit parent model }
    C.Subagents[0].MaxIter  := 4;

    { A named outbound channel for the send_message tool. }
    SetLength(C.Channels, 1);
    C.Channels[0].Name   := 'team-alerts';
    C.Channels[0].Kind   := 'slack';
    C.Channels[0].Target := 'https://hooks.slack.com/services/XXX/YYY/ZZZ';

    { A scheduled job (runs an installed skill on a cron spec). }
    SetLength(C.Crons, 1);
    C.Crons[0].Id      := 'daily-standup';
    C.Crons[0].Spec    := '0 9 * * *';
    C.Crons[0].Skill   := 'standup';
    C.Crons[0].Enabled := False;

    { A skill registration. }
    SetLength(C.Skills, 1);
    C.Skills[0].Name    := 'hello';
    C.Skills[0].Source  := 'builtin';
    C.Skills[0].Enabled := True;

    { Sender allowlist for channel-driven runs (empty = no gate). }
    SetLength(C.AllowSenders, 1);
    C.AllowSenders[0] := 'slack:U123';

    { ===== Custom + built-in tools ===== }
    Agent.RegisterTool(TWebSearchTool.Create);
    Agent.RegisterTool(TWebFetchTool.Create);
    Agent.RegisterTool(TFileSystemTool.Create);

    WriteLn('configured ', Length(C.Providers), ' provider(s); default=',
            C.DefaultProvider, '/', C.DefaultModel, ' — running…');
    WriteLn;
    try
      WriteLn(Agent.Run('In one sentence, what is Free Pascal?'));
    except
      on E: EPasClawRun do
        WriteLn('agent error: ', E.Message);
    end;
  finally
    Agent.Free;
    H.Free;
  end;
end.
