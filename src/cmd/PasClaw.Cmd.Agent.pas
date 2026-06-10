{
  Agent -- chat with the assistant.

  Two modes:
    pasclaw agent -m "single query"   one-shot
    pasclaw agent                     interactive

  Always wires the built-in tools registry (fs_read, fs_write, fs_list,
  shell_exec). Falls back to an offline preview if no provider is configured.
}
unit PasClaw.Cmd.Agent;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Agent_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, Classes,
  PasClaw.Config, PasClaw.Utils, PasClaw.CliUI, PasClaw.Logger,
  PasClaw.Providers.Types,
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
  PasClaw.Tools.Vault,
  PasClaw.Tools.OutputCache,
  PasClaw.Tools.ToolLoop,
  PasClaw.Agent.Compact,
  PasClaw.MCP.Bridge,
  PasClaw.Skills.Loader,
  PasClaw.Agent.Prompt,
  PasClaw.Agent.Subagent,
  PasClaw.Agent.SubagentBg,
  PasClaw.Agent.AutoRouter,
  PasClaw.Session.Store,
  PasClaw.Tools.Sandbox,
  PasClaw.Identity,
  PasClaw.Agent.Steering,
  PasClaw.Markdown.Render;

type
  TAgentArgs = record
    Message:       string;
    Model:         string;
    Provider:      string;
    SystemPrompt:  string;
    Thinking:      string;
    MaxTokens:     Integer;
    MaxIterations: Integer;
    NoTools:       Boolean;
    NoMCP:         Boolean;
    NoHashline:    Boolean;
    { Session id to resume. Empty (the default) = interactive mode
      auto-allocates a fresh id and persists from turn 1, so a Ctrl-C
      / crash never drops the conversation. Non-empty AND existing on
      disk = load history + system-prompt override from
      workspace/sessions/<id>.json. Non-empty AND missing on disk =
      create that session id with empty history (so a script can
      pre-seed an id like "daily-2026-06-01"). RunSingleTurn (one-shot
      -m) ignores this -- single turns aren't worth persisting. }
    Session:       string;
  end;

  TLoopHandlers = class
    procedure OnToolCall(const Name, ArgsJSON: string);
    procedure OnToolResult(const Name, ResultText, Err: string);
  end;

procedure TLoopHandlers.OnToolCall(const Name, ArgsJSON: string);
begin
  PrintLn(Ansi.Magenta + '› tool ' + Name + Ansi.Reset + ' ' + Copy(ArgsJSON, 1, 200));
end;

procedure TLoopHandlers.OnToolResult(const Name, ResultText, Err: string);
var
  Preview: string;
begin
  if Err <> '' then
    PrintLn(Ansi.Red + '  ✗ ' + Err + Ansi.Reset)
  else
  begin
    Preview := ResultText;
    if Length(Preview) > 200 then Preview := Copy(Preview, 1, 200) + '…';
    PrintLn(Ansi.Dim + '  ✓ ' + Preview + Ansi.Reset);
  end;
end;

function DefaultAgentArgs: TAgentArgs;
begin
  Result.Message       := '';
  Result.Model         := '';
  Result.Provider      := '';
  Result.SystemPrompt  := '';
  Result.Thinking      := '';
  Result.MaxTokens     := 8192;   { see DefaultChatOptions in PasClaw.Providers.Types -- same rationale }
  Result.MaxIterations := 8;
  Result.NoTools       := False;
  Result.NoMCP         := False;
  Result.NoHashline    := False;
end;

function ParseArgs(const Argv: array of string; var A: TAgentArgs): Boolean;
var
  i: Integer;
begin
  Result := True;
  A := DefaultAgentArgs;
  i := 0;
  while i <= High(Argv) do
  begin
    if (Argv[i] = '-m') or (Argv[i] = '--message') then
    begin
      if i = High(Argv) then Exit(False);
      A.Message := Argv[i + 1]; Inc(i, 2); Continue;
    end;
    if Argv[i] = '--model'    then begin if i = High(Argv) then Exit(False); A.Model := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--provider' then begin if i = High(Argv) then Exit(False); A.Provider := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--system'   then begin if i = High(Argv) then Exit(False); A.SystemPrompt := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--thinking' then begin if i = High(Argv) then Exit(False); A.Thinking := Argv[i + 1]; Inc(i, 2); Continue; end;
    if Argv[i] = '--max-tokens'     then begin if i = High(Argv) then Exit(False); A.MaxTokens     := StrToIntDef(Argv[i + 1], A.MaxTokens);     Inc(i, 2); Continue; end;
    if Argv[i] = '--max-iterations' then begin if i = High(Argv) then Exit(False); A.MaxIterations := StrToIntDef(Argv[i + 1], A.MaxIterations); Inc(i, 2); Continue; end;
    if Argv[i] = '--no-tools'    then begin A.NoTools    := True; Inc(i); Continue; end;
    if Argv[i] = '--no-mcp'      then begin A.NoMCP      := True; Inc(i); Continue; end;
    if Argv[i] = '--no-hashline' then begin A.NoHashline := True; Inc(i); Continue; end;
    if Argv[i] = '--session'     then begin if i = High(Argv) then Exit(False); A.Session := Argv[i + 1]; Inc(i, 2); Continue; end;
    Inc(i);
  end;
end;

function PickProvider(Cfg: TConfig; const A: TAgentArgs;
                      out Provider: ILLMProvider; out Err: string): Boolean;
var
  Name: string;
begin
  if A.Provider <> '' then Name := A.Provider else Name := Cfg.DefaultProvider;
  if Name = '' then
  begin
    Err := 'no provider configured';
    Exit(False);
  end;
  Result := NewProviderFromConfig(Cfg, Name, Provider, Err);
end;

function NewBuiltinRegistry(UseHashline: Boolean = True;
                            EnableVault: Boolean = False;
                            EnableWebSearch: Boolean = False;
                            EnableWebFetch: Boolean = False;
                            EnableOutputCache: Boolean = False): TToolRegistry;
var
  Skills: TSkillSpecArray;
begin
  Result := TToolRegistry.Create;
  RegisterFSTools(Result, UseHashline);
  RegisterShellTool(Result);
  RegisterExecuteCodeTool(Result);
  RegisterMemoryTools(Result);
  RegisterSessionSearchTool(Result);
  { web_search registers only when a real provider is configured
    (Brave / Tavily / Perplexity / Gemini key, or SearXNG base URL).
    Callers compute the flag via PasClaw.Search.Factory's
    HasConfiguredWebSearchProvider and pass it here. The DDG scrape
    fallback is intentionally hidden from the model because DDG's
    bot-detection wall refuses non-browser TLS fingerprints in 2026. }
  if EnableWebSearch then RegisterWebSearchTool(Result)
  else                    LogWebSearchSkipOnce;
  { web_fetch is opt-in (Cfg.WebFetchEnabled). Off by default
    because picoclaw's model fetches URLs via shell+curl and we
    don't want to silently divert that traffic. Operators on
    container/sandboxed deploys without curl can flip this in
    config.json. }
  if EnableWebFetch then RegisterWebFetchTool(Result);
  { memory_fetch piggybacks on the same WebFetch enable: it uses
    the same HTTP machinery + SSRF gate, and an operator who's
    declined to enable URL fetching shouldn't get a second tool
    that also fetches URLs. }
  if EnableWebFetch then RegisterMemoryFetchTool(Result);
  { Vault tools register only when explicitly enabled -- callers pass
    Cfg.VaultToolsEnabled. Off-by-default per the onboarding opt-in
    flow; flipping the config flag (or re-running `pasclaw onboard`)
    is the way to turn it on. }
  if EnableVault then RegisterVaultTools(Result);
  { tool_output_get gets registered alongside the rest when the
    operator has flipped on Cfg.ToolOutputCap. The tool's only
    useful while truncation is active, so the flag gates both. }
  if EnableOutputCache then RegisterOutputCacheTool(Result);
  Skills := LoadSkillManifests(GetHome);
  RegisterSkills(Result, Skills);
end;

{ When the operator declared subagents in config.json, install the
  `spawn` tool into the registry -- once MCP tools have already been
  bridged in so subagents can include them in their allowlist.
  Returns the created spawn tool so the caller can `Free` it during
  cleanup; nil when no subagents are configured. }
function MaybeRegisterSpawnTool(Cfg: TConfig; Provider: ILLMProvider;
                                 Reg: TToolRegistry; const Model: string): TSpawnTool;
var
  Ctx: TSubagentContext;
begin
  Result := nil;
  if (Reg = nil) or (Length(Cfg.Subagents) = 0) then Exit;
  Ctx.Provider       := Provider;
  Ctx.Fallbacks      := ResolveFallbacks(Cfg);
  Ctx.ParentRegistry := Reg;
  Ctx.DefaultModel   := Model;
  Ctx.PromptCache    := Cfg.PromptCache;
  Result := RegisterSpawnTool(Reg, Ctx, Cfg.Subagents);
end;

function MaybeRegisterBackgroundSpawnTools(Cfg: TConfig; Provider: ILLMProvider;
                                            Reg: TToolRegistry;
                                            const Model: string)
                                            : TBackgroundSpawnCoordinator;
var
  Ctx: TSubagentContext;
begin
  Result := nil;
  if (Reg = nil) or (Length(Cfg.Subagents) = 0) then Exit;
  Ctx.Provider       := Provider;
  Ctx.Fallbacks      := ResolveFallbacks(Cfg);
  Ctx.ParentRegistry := Reg;
  Ctx.DefaultModel   := Model;
  Ctx.PromptCache    := Cfg.PromptCache;
  Result := RegisterBackgroundSpawnTools(Reg, Ctx, Cfg.Subagents);
end;

function ConnectMCP(Cfg: TConfig; Reg: TToolRegistry; NoMCP: Boolean): TMCPClientList;
begin
  SetLength(Result, 0);
  if NoMCP then Exit;
  if Reg = nil then Exit;
  Result := ConnectMCPServers(Cfg, Reg);
end;

function BuildLoopConfig(const Cfg: TConfig;
                         Provider: ILLMProvider; Reg: TToolRegistry;
                         const Model: string; const A: TAgentArgs;
                         Handlers: TLoopHandlers): TToolLoopConfig;
begin
  Result.Provider      := Provider;
  Result.Registry      := Reg;
  Result.Model         := Model;
  Result.MaxIterations := A.MaxIterations;
  Result.Parallel := True;
  Result.Fallbacks     := ResolveFallbacks(Cfg);
  Result.Options       := DefaultChatOptions;
  { ToolsEnabled tracks the registry we are about to hand RunToolLoop
    so the system prompt stays in sync with what the model can
    actually call. Reg is nil when --no-tools is set (RunBuilder
    passes nil; see Run* call sites above) -- deriving from the
    registry, not from A.NoTools, also handles the case where future
    callers nil out Reg for other reasons. }
  Result.Options.SystemPrompt  := BuildSystemPrompt(Cfg, A.SystemPrompt, Reg <> nil);
  Result.Options.ThinkingLevel := A.Thinking;
  if A.MaxTokens > 0 then Result.Options.MaxTokens := A.MaxTokens;
  { Prompt caching threads through TChatOptions so each provider
    builder can decide what to emit (Anthropic: cache_control on
    system + last tool; OpenAI: prompt_cache_key). CacheKey is set
    per-turn in RunInteractive (it's the persistent session id);
    RunSingleTurn leaves it empty since one-shots aren't worth
    keying. }
  ApplyPromptCacheConfig(Result.Options, Cfg.PromptCache);
  { Identity for the CLI path. $USER on POSIX, %USERNAME% on Windows;
    falls back to 'local' so the canonical id is never empty. Channels
    + gateway override this with their platform-specific sender. }
  Result.Identity := MakeIdentity('cli',
    GetEnvironmentVariable({$IFDEF MSWINDOWS}'USERNAME'{$ELSE}'USER'{$ENDIF}));
  if Result.Identity.UserId = '' then Result.Identity.UserId := 'local';
  Result.OnText        := nil;
  Result.OnToolCall    := Handlers.OnToolCall;
  Result.OnToolResult  := Handlers.OnToolResult;
  { Conversation-history compaction: on by default with picoclaw-ish
    defaults (80K-token threshold, last 8 turns preserved). The tool
    loop only pays the cost of a summariser round when the running
    history actually trips the threshold, so short conversations
    are unaffected. Channels that thread their own RunToolLoop
    config can opt in the same way. }
  Result.CompactEnabled := True;
  Result.CompactOpts    := DefaultCompactOptions;
  { Forward the tool-output truncation cap (per-tool-result bytes)
    from config. 0 = off (legacy verbatim behaviour); when an
    operator sets it, RunToolLoop diverts oversize results to the
    OutputCache and replaces them with head+tail+handle. The
    `tool_output_get` tool is registered alongside the other core
    tools in RegisterFSTools' caller (Cmd.Agent / Cmd.TUI). }
  Result.ToolOutputCap := Cfg.ToolOutputCap;
  { Stream-reliability: same default-shape pattern -- forwarded as
    a struct copy so the loop's primary Provider.Chat call goes
    through ChatWithEmptyRetry. Loop-side fallback walk is
    unaffected; this only catches the empty-turn brownout shape. }
  Result.StreamReliability := Cfg.StreamReliability;
end;

{ One-line per-turn token summary. Cache fields only appear when
  non-zero so a non-Anthropic / cache-disabled run stays clean.
  cache_w = cache_creation (a one-time write cost -- 25% premium on
  Anthropic but only on the first turn); cache_r = cache_read
  (the win -- 90% discount on Anthropic, 50% on OpenAI). }
function FormatTokenLine(const U: TUsageInfo; Iterations: Integer): string;
begin
  Result := Format('  [tokens in=%d out=%d', [U.InputTokens, U.OutputTokens]);
  if U.CacheReadTokens    > 0 then Result := Result + Format(' cache_r=%d', [U.CacheReadTokens]);
  if U.CacheCreatedTokens > 0 then Result := Result + Format(' cache_w=%d', [U.CacheCreatedTokens]);
  Result := Result + Format(', iters=%d]', [Iterations]);
end;

(* Total prompt tokens the model actually saw, summed across cached
   and uncached portions. Anthropic reports input_tokens EXCLUDING
   cached/written tokens (those are separate fields), so a Reads +
   InputTokens denominator is needed for a correct hit-rate. OpenAI
   reports cached_tokens as a SUBSET of prompt_tokens -- InputTokens
   alone is the right denominator. We distinguish by provider name
   because cache_creation_tokens can be zero on a pure-read turn,
   so "presence of CacheCreatedTokens" isn't a reliable Anthropic
   marker. Codex P2 on PR #118. *)
function TotalPromptTokens(const U: TUsageInfo; const ProviderName: string): Int64;
begin
  if ProviderName = 'anthropic' then
    Result := Int64(U.InputTokens) + U.CacheReadTokens + U.CacheCreatedTokens
  else
    Result := U.InputTokens;
end;

function MaybeRender(const Cfg: TConfig; const S: string): string; inline;
{ Wraps the LLM's output in PasClaw.Markdown.Render when the
  operator hasn't turned it off (Cfg.RenderMarkdown, default True).
  Markdown rendering targets terminal surfaces -- pasclaw agent and
  pasclaw tui -- and is opt-out for operators who pipe the output
  through other tools that want the raw markdown. }
begin
  if Cfg.RenderMarkdown then Result := RenderMarkdown(S)
  else                       Result := S;
end;

procedure RunSingleTurn(const Cfg: TConfig; const A: TAgentArgs; const Prompt: string);
var
  Provider: ILLMProvider;
  Err: string;
  Msgs: array of TMessage;
  Reg: TToolRegistry;
  Handlers: TLoopHandlers;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
  Model: string;
  MCPClients: TMCPClientList;
  Spawn: TSpawnTool;
  BgCoord: TBackgroundSpawnCoordinator;
begin
  if not PickProvider(Cfg, A, Provider, Err) then
  begin
    PrintLn(Ansi.Yellow + '(offline preview -- ' + Err + ')' + Ansi.Reset);
    PrintLn('You: ' + Prompt);
    PrintLn('Assistant: <provider not configured; run `pasclaw onboard`>');
    Exit;
  end;

  { Resolve the effective model BEFORE registering the spawn tool.
    MaybeRegisterSpawnTool captures Model into the TSubagentContext
    by value; if we hand it an empty string the child subagent loop
    will fall back to the provider's GetDefaultModel instead of the
    user's --model selection. RunInteractive already does this in the
    right order -- fixing the asymmetry here. (Codex P2 on PR #107.) }
  if A.Model <> '' then Model := A.Model else Model := Cfg.DefaultModel;

  Reg := nil;
  if not A.NoTools then
    Reg := NewBuiltinRegistry(not A.NoHashline, Cfg.VaultToolsEnabled,
                              HasConfiguredWebSearchProvider(Cfg),
                              Cfg.WebFetchEnabled,
                              Cfg.ToolOutputCap > 0);
  MCPClients := ConnectMCP(Cfg, Reg, A.NoMCP);
  Spawn := MaybeRegisterSpawnTool(Cfg, Provider, Reg, Model);
  BgCoord := MaybeRegisterBackgroundSpawnTools(Cfg, Provider, Reg, Model);
  Handlers := TLoopHandlers.Create;
  try
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, Prompt);

    LoopCfg := BuildLoopConfig(Cfg, Provider, Reg, Model, A, Handlers);

    PrintLn(Ansi.Cyan + 'assistant' + Ansi.Reset + ' (' + Provider.GetName + '/' + Model + '):');
    if RunToolLoop(LoopCfg, Msgs, Loop) then
      PrintLn(MaybeRender(Cfg, Loop.Content))
    else
      PrintLn('(loop failed)');
    if Loop.TotalUsage.InputTokens + Loop.TotalUsage.OutputTokens > 0 then
      PrintLn(Ansi.Dim + FormatTokenLine(Loop.TotalUsage, Loop.Iterations) + Ansi.Reset);
  finally
    Handlers.Free;
    FreeMCPClients(MCPClients);
    if Spawn <> nil then Spawn.Free;
    Reg.Free;
  end;
end;

procedure RunInteractive(const Cfg: TConfig; const A: TAgentArgs);
var
  Line: string;
  Provider: ILLMProvider;
  Err: string;
  Msgs: TMessageArray;
  Reg: TToolRegistry;
  Handlers: TLoopHandlers;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
  Model: string;
  Offline: Boolean;
  i: Integer;
  Names: TStringArray;
  MCPClients: TMCPClientList;
  Spawn: TSpawnTool;
  BgCoord: TBackgroundSpawnCoordinator;
  SystemPromptOverride: string;   { tracks the compacted system prompt across turns }
  WorkingStateBlock: string;       { per-turn prefix from Session.Meta.WorkingState }
  ThinkingOn: Boolean;             { toggled by /think; cleared each turn after sending }
  { Auto-router state. PrimaryProvider keeps the originally-picked
    provider so we can restore after a routed turn, and so the
    routed turn can prepend it to the fallback list. EasyProvider
    is built lazily on first need, cached for the rest of the
    session. PrimaryFallbacks remembers the fallback chain we'd
    use on a non-routed turn so we can swap it out for the routed
    chain ("original primary + original fallbacks") and back. }
  PrimaryProvider:   ILLMProvider;
  EasyProvider:      ILLMProvider;
  PrimaryFallbacks:  TLLMProviderArray;
  RoutedProviderNm:  string;
  RoutedModelOverride: string;
  RoutedThisTurn:    Boolean;
  CompactOptsLocal: TCompactOptions;
  CompactedLiveOpts: TChatOptions;
  Session: TSession;               { always non-nil in interactive mode }
  TotalCacheRead, TotalCacheWrite, TotalPrompt: Int64;   { cumulative across turns for /status }

  procedure PersistSession;
  var j: Integer;
  begin
    if Session = nil then Exit;
    SetLength(Session.Messages, Length(Msgs));
    for j := 0 to High(Msgs) do Session.Messages[j] := Msgs[j];
    Session.Meta.SystemPromptOverride := SystemPromptOverride;
    Session.Meta.Model := Model;
    if Provider <> nil then Session.Meta.Provider := Provider.GetName;
    Session.AutoTitle;
    Session.Touch;
    Session.Save;
  end;

begin
  SystemPromptOverride := '';
  Session := nil;
  TotalCacheRead  := 0;
  TotalCacheWrite := 0;
  TotalPrompt     := 0;
  Offline := not PickProvider(Cfg, A, Provider, Err);
  if Offline then
    PrintLn(Ansi.Yellow + '(offline preview -- ' + Err + ')' + Ansi.Reset);
  PrimaryProvider     := Provider;
  EasyProvider        := nil;       { lazy }
  RoutedThisTurn      := False;
  RoutedProviderNm    := '';
  RoutedModelOverride := '';
  PrintLn(Ansi.Dim + 'PasClaw interactive chat. /help for commands, /quit to exit.' + Ansi.Reset);

  if A.Model <> '' then Model := A.Model else Model := Cfg.DefaultModel;
  Reg := nil;
  if not A.NoTools then
    Reg := NewBuiltinRegistry(not A.NoHashline, Cfg.VaultToolsEnabled,
                              HasConfiguredWebSearchProvider(Cfg),
                              Cfg.WebFetchEnabled,
                              Cfg.ToolOutputCap > 0);
  MCPClients := ConnectMCP(Cfg, Reg, A.NoMCP);
  Spawn := MaybeRegisterSpawnTool(Cfg, Provider, Reg, Model);
  BgCoord := MaybeRegisterBackgroundSpawnTools(Cfg, Provider, Reg, Model);
  Handlers := TLoopHandlers.Create;
  try
    SetLength(Msgs, 0);
    ThinkingOn := False;

    { Persistence is on by default in interactive mode -- a passed
      --session resumes that id (or starts fresh under it when the
      file doesn't exist), an empty --session auto-allocates a new
      id so the conversation survives Ctrl-C / crash regardless.
      Codex P1 on PR #117: making this opt-in defeated the whole
      "history survives restarts" point. }
    Session := TSession.Create(A.Session);
    if Session.MetaExists then
    begin
      SetLength(Msgs, Length(Session.Messages));
      for i := 0 to High(Session.Messages) do Msgs[i] := Session.Messages[i];
      SystemPromptOverride := Session.Meta.SystemPromptOverride;
      PrintLn(Ansi.Dim + '(resumed session ' + Session.Meta.Id +
              ' -- ' + IntToStr(Length(Msgs)) + ' messages)' + Ansi.Reset);
    end
    else
      PrintLn(Ansi.Dim + '(new session ' + Session.Meta.Id +
              ' -- pasclaw resume ' + Session.Meta.Id + ' to continue later)' + Ansi.Reset);

    while True do
    begin
      Print(Ansi.Bold + '> ' + Ansi.Reset);
      if EOF then Break;
      ReadLn(Line);
      Line := Trim(Line);
      if (Line = '/quit') or (Line = '/exit') then Break;
      if (Line = '/reset') or (Line = '/new') then
      begin
        SetLength(Msgs, 0);
        SystemPromptOverride := '';   { drop the compacted summary too }
        { /new starts a brand-new session id so the existing one
          stays on disk for resume; /reset keeps the current session
          but clears its messages in place. Distinction matches
          openclaw and nanobot semantics. }
        if Line = '/new' then
        begin
          { Old session's queue might have leftover pending steering
            messages -- drop them before re-keying so the fresh session
            doesn't pick up the previous conversation's interrupts. }
          ClearSteering(Session.Meta.Id);
          Session.Free;
          Session := TSession.Create('');   { fresh id }
          PrintLn(Ansi.Dim + '(new session ' + Session.Meta.Id + ')' + Ansi.Reset);
        end
        else
        begin
          ClearSteering(Session.Meta.Id);
          PersistSession;   { writes empty Msgs + cleared override }
          PrintLn(Ansi.Dim + '(history cleared)' + Ansi.Reset);
        end;
        Continue;
      end;
      if Copy(Line, 1, 7) = '/steer ' then
      begin
        { Same-process steering -- handy for testing, but the real
          win is `pasclaw steer <id> "..."` from another terminal
          while a long loop is mid-execution. }
        if PushSteering(Session.Meta.Id, Copy(Line, 8, MaxInt)) then
          PrintLn(Ansi.Dim + '(queued; injects at top of next iteration)' + Ansi.Reset)
        else
          PrintLn(Ansi.Red + '(steer push failed)' + Ansi.Reset);
        Continue;
      end;
      if Line = '/tools' then
      begin
        if Reg = nil then
          PrintLn('(tools disabled -- restart without --no-tools)')
        else
        begin
          Names := Reg.Names;
          for i := 0 to High(Names) do PrintLn('  ' + Names[i]);
        end;
        Continue;
      end;
      if (Line = '/help') or (Line = '/?') then
      begin
        PrintLn('  /help        show this list');
        PrintLn('  /status      model + provider + message count + thinking state');
        PrintLn('  /new         clear conversation history (alias: /reset)');
        PrintLn('  /reset       clear conversation history');
        PrintLn('  /compact     force a one-shot summariser pass on the history now');
        PrintLn('  /think       toggle extended thinking on the next turn (if the provider supports it)');
        PrintLn('  /tools       list registered tools');
        PrintLn('  /steer <msg> queue a mid-loop steering message for the NEXT iteration');
        PrintLn('  /quit        exit (alias: /exit)');
        Continue;
      end;
      if Line = '/status' then
      begin
        if Provider <> nil then
          PrintLn('  provider:  ' + Provider.GetName)
        else
          PrintLn('  provider:  (offline)');
        PrintLn('  model:     ' + Model);
        PrintLn('  messages:  ' + IntToStr(Length(Msgs)));
        if Reg <> nil then
          PrintLn('  tools:     ' + IntToStr(Reg.Count))
        else
          PrintLn('  tools:     (disabled)');
        if ThinkingOn then
          PrintLn('  thinking:  on (next turn)')
        else
          PrintLn('  thinking:  off');
        if SystemPromptOverride <> '' then
          PrintLn('  compacted: yes (summary in system prompt)')
        else
          PrintLn('  compacted: no');
        if Cfg.PromptCache.Enabled then
        begin
          if TotalPrompt > 0 then
            PrintLn(Format('  cache:     on, %d read / %d written (%d%% hit on prompt so far)',
                           [TotalCacheRead, TotalCacheWrite,
                            (TotalCacheRead * 100) div TotalPrompt]))
          else
            PrintLn('  cache:     on, no turns yet');
        end
        else
          PrintLn('  cache:     off (prompt_cache.enabled=false in config)');
        if Session <> nil then
        begin
          i := PendingSteeringCount(Session.Meta.Id);
          if i > 0 then
            PrintLn('  steering:  ' + IntToStr(i) + ' pending (folded at next iteration)')
          else
            PrintLn('  steering:  none queued');
        end;
        Continue;
      end;
      if Line = '/think' then
      begin
        if (Provider <> nil) and (not Provider.SupportsThinking) then
        begin
          PrintLn(Ansi.Yellow + 'provider ' + Provider.GetName +
                  ' does not support extended thinking -- flag ignored.' + Ansi.Reset);
          Continue;
        end;
        ThinkingOn := not ThinkingOn;
        if ThinkingOn then
          PrintLn(Ansi.Dim + '(thinking on for next turn)' + Ansi.Reset)
        else
          PrintLn(Ansi.Dim + '(thinking off)' + Ansi.Reset);
        Continue;
      end;
      if Line = '/compact' then
      begin
        if Length(Msgs) = 0 then
        begin
          PrintLn(Ansi.Dim + '(no history to compact)' + Ansi.Reset);
          Continue;
        end;
        if Offline then
        begin
          PrintLn(Ansi.Yellow + '/compact needs a configured provider to summarise.' + Ansi.Reset);
          Continue;
        end;
        CompactOptsLocal := DefaultCompactOptions;
        CompactOptsLocal.ThresholdTokens := 1;  { force the slice }
        CompactedLiveOpts := DefaultChatOptions;
        ApplyPromptCacheConfig(CompactedLiveOpts, Cfg.PromptCache);
        if SystemPromptOverride <> '' then
          CompactedLiveOpts.SystemPrompt := SystemPromptOverride;
        Msgs := CompactMessages(Provider, Model, Msgs,
                                 CompactedLiveOpts, CompactOptsLocal);
        SystemPromptOverride := CompactedLiveOpts.SystemPrompt;
        { Persist the compacted state immediately -- otherwise a
          /quit or Ctrl-C before the next LLM turn loses the
          summary and resume replays the full transcript. Codex P2
          on PR #117. }
        PersistSession;
        PrintLn(Ansi.Dim + '(history compacted; summary folded into system prompt)' + Ansi.Reset);
        Continue;
      end;
      if Line = '' then Continue;

      SetLength(Msgs, Length(Msgs) + 1);
      Msgs[High(Msgs)] := MakeMessage(mrUser, Line);

      if Offline then
      begin
        PrintLn(Ansi.Cyan + 'assistant' + Ansi.Reset + ' (offline): I would respond once a provider is configured.');
        SetLength(Msgs, Length(Msgs) + 1);
        Msgs[High(Msgs)] := MakeMessage(mrAssistant, '(no response -- offline)');
        Continue;
      end;

      LoopCfg := BuildLoopConfig(Cfg, Provider, Reg, Model, A, Handlers);
      { After the first compaction the summary lives in
        LiveOptions.SystemPrompt inside RunToolLoop and gets returned
        via Loop.FinalSystemPrompt. We override here so the next turn
        ships the summary back to the provider; without it
        BuildSystemPrompt rebuilds the original prompt and the
        compacted summary leaks out of the conversation. }
      if SystemPromptOverride <> '' then
        LoopCfg.Options.SystemPrompt := SystemPromptOverride;
      { Working-state snapshot from prior turns goes BEFORE the
        compacted summary (or the freshly-built default system
        prompt) so the model sees structured edit/shell/error
        context at the top of every turn. Empty string when the
        snapshot is empty -- pre-feature sessions stay verbatim. }
      WorkingStateBlock := FormatWorkingStateBlock(Session.Meta);
      if WorkingStateBlock <> '' then
        LoopCfg.Options.SystemPrompt :=
          WorkingStateBlock + sLineBreak + LoopCfg.Options.SystemPrompt;
      { Anchor OpenAI's prompt_cache_key to the persistent session
        id so the cache bucket lines up across turns of THIS chat
        (not someone else's parallel session that happens to share a
        prefix). Anthropic ignores the field; OpenAI uses it to pin
        prefix routing on the back-end. }
      if Session <> nil then
      begin
        LoopCfg.Options.CacheKey := Session.Meta.Id;
        { Steering queue key -- RunToolLoop drains it at iteration
          top and folds pending messages into history as
          "[user steering] ..." system notes. The other terminal's
          `pasclaw steer <session-id> "..."` writes to the same
          file the loop is about to read. }
        LoopCfg.SteeringKey := Session.Meta.Id;
        { Background subagents: bind the coordinator to this session
          on first turn (idempotent re-binds are cheap), and let
          RunToolLoop fold finished results into the system prompt
          via the same channel steering uses. }
        if BgCoord <> nil then
        begin
          BgCoord.SetKey(Session.Meta.Id);
          LoopCfg.BackgroundDrainKey := Session.Meta.Id;
        end;
      end;
      { /think: apply ThinkingLevel for this turn, then clear so
        subsequent turns reset (matches the OpenClaw /think model --
        single-turn extended thinking). The user can /think again
        to keep it on. }
      if ThinkingOn then
      begin
        LoopCfg.Options.ThinkingLevel := 'medium';
        ThinkingOn := False;
      end;

      { Auto-router: classify the latest user message and, if it
        looks easy enough, swap LoopCfg.Provider to the cheap
        fallback for this turn. Keeps the primary on the fallback
        list as the first retry target so a routing-fooled turn
        falls back cleanly without operator intervention. See
        PasClaw.Agent.AutoRouter for the heuristic. }
      RoutedThisTurn := False;
      if Reg <> nil then Names := Reg.Names else Names := nil;
      if (not Offline) and (PrimaryProvider <> nil) then
        if RouteProvider(Cfg, Line,
                         Names,
                         RoutedProviderNm, RoutedModelOverride) then
        begin
          { Lazy-build the easy provider on first routing. Cached
            for the rest of the session so we don't pay the
            construction cost per routed turn. If the build fails
            (catalog drift, missing key) we log once and stay on
            the primary -- never crash mid-turn for a router
            misconfiguration. }
          if EasyProvider = nil then
            if not NewProviderFromConfig(Cfg, RoutedProviderNm,
                                         EasyProvider, Err) then
            begin
              LogWarn('auto-router: easy provider "%s" unresolvable: %s',
                      [RoutedProviderNm, Err]);
              EasyProvider := nil;
            end;
          if EasyProvider <> nil then
          begin
            PrimaryFallbacks := LoopCfg.Fallbacks;
            LoopCfg.Provider := EasyProvider;
            { Prepend the original primary to the fallback chain
              so a failed routed call drops cleanly back to the
              provider the operator would have used anyway. }
            SetLength(LoopCfg.Fallbacks, Length(PrimaryFallbacks) + 1);
            LoopCfg.Fallbacks[0] := PrimaryProvider;
            for i := 0 to High(PrimaryFallbacks) do
              LoopCfg.Fallbacks[i + 1] := PrimaryFallbacks[i];
            { RouteProvider resolved the model for us (explicit
              EasyModel -> per-provider stored Model -> catalog
              default) and refused to route if none of those
              produced a value -- so RoutedModelOverride is
              guaranteed non-empty when we're here. Overriding
              LoopCfg.Model is mandatory: BuildLoopConfig set it
              to the primary's model and passing claude-* to a
              Groq endpoint (etc.) just fails. Codex P2 #203. }
            LoopCfg.Model := RoutedModelOverride;
            RoutedThisTurn := True;
            PrintLn(Ansi.Dim + '(routed -> ' + RoutedProviderNm + ')' + Ansi.Reset);
          end;
        end;

      if RunToolLoop(LoopCfg, Msgs, Loop) then
      begin
        if RoutedThisTurn then
          PrintLn(Ansi.Cyan + 'assistant' + Ansi.Reset + ' (' +
                  RoutedProviderNm + '/' + RoutedModelOverride +
                  ', auto-routed):')
        else
          PrintLn(Ansi.Cyan + 'assistant' + Ansi.Reset + ' (' + Provider.GetName + '/' + Model + '):');
        PrintLn(MaybeRender(Cfg, Loop.Content));
        if Loop.TotalUsage.InputTokens + Loop.TotalUsage.OutputTokens > 0 then
        begin
          { Surface aggregate usage across every provider call in the
            turn (incl. tool-using rounds), not just the final reply.
            Codex P2 on PR #118. }
          PrintLn(Ansi.Dim + FormatTokenLine(Loop.TotalUsage, Loop.Iterations) + Ansi.Reset);
          Inc(TotalPrompt,     TotalPromptTokens(Loop.TotalUsage, Provider.GetName));
          Inc(TotalCacheRead,  Loop.TotalUsage.CacheReadTokens);
          Inc(TotalCacheWrite, Loop.TotalUsage.CacheCreatedTokens);
        end;
        if Cfg.StatsCollectionEnabled and (Session <> nil) then
          AccumulateTurnStats(Session.Meta,
                              Loop.TotalUsage.InputTokens,
                              Loop.TotalUsage.OutputTokens,
                              Loop.TotalUsage.CacheReadTokens,
                              Loop.TotalUsage.CacheCreatedTokens,
                              Loop.ToolCallsDispatched,
                              Loop.TruncatedBytesSaved);

        { Pick up the compacted history from RunToolLoop so the next
          interactive turn starts from the summarised state, not the
          full pre-compaction transcript (Codex PR #87 P2). If
          compaction didn't fire this turn, Loop.FinalMessages mirrors
          Msgs + new assistant/tool entries -- same growth path as
          before. If it DID fire, Msgs shrinks to the compacted view
          and SystemPromptOverride below preserves the summary across
          subsequent BuildLoopConfig calls. }
        if Length(Loop.FinalMessages) > 0 then
        begin
          SetLength(Msgs, Length(Loop.FinalMessages) + 1);
          for i := 0 to High(Loop.FinalMessages) do
            Msgs[i] := Loop.FinalMessages[i];
          Msgs[High(Msgs)] := MakeMessage(mrAssistant, Loop.Content);
        end
        else
        begin
          SetLength(Msgs, Length(Msgs) + 1);
          Msgs[High(Msgs)] := MakeMessage(mrAssistant, Loop.Content);
        end;
        SystemPromptOverride := Loop.FinalSystemPrompt;
        { Strip the per-turn working-state prefix we prepended in
          BuildLoopConfig -- if compaction didn't fire, the prefix
          comes back verbatim and persisting it would re-prepend
          on every subsequent turn, accumulating stale snapshots.
          When compaction DID fire, the summariser may have
          rewritten the whole prompt; in that case the prefix
          comparison fails and we keep the compacted text as-is.
          Codex P2 on PR #180. }
        if WorkingStateBlock <> '' then
        begin
          if (Length(SystemPromptOverride) >
              Length(WorkingStateBlock) + Length(sLineBreak))
             and (Copy(SystemPromptOverride, 1,
                       Length(WorkingStateBlock) + Length(sLineBreak)) =
                  WorkingStateBlock + sLineBreak) then
            SystemPromptOverride := Copy(SystemPromptOverride,
              Length(WorkingStateBlock) + Length(sLineBreak) + 1,
              MaxInt);
        end;

        { Refresh the working-state snapshot from this turn's final
          history (fs_write/fs_edit paths, shell commands, tool
          errors). Updates Session.Meta.WorkingState in place;
          PersistSession below writes it out so a /quit-then-resume
          picks up the same context next time. }
        if Length(Loop.FinalMessages) > 0 then
          UpdateWorkingStateAfterTurn(Session.Meta, Loop.FinalMessages);

        { Persist after every successful turn -- crash / Ctrl-C in
          the middle of the NEXT user prompt only loses what they
          were typing, not the existing conversation. }
        PersistSession;
      end;
    end;
  finally
    Handlers.Free;
    FreeMCPClients(MCPClients);
    if Spawn <> nil then Spawn.Free;
    Reg.Free;
    if Session <> nil then Session.Free;
  end;
end;

function Cmd_Agent_Run(const Argv: array of string): Integer;
var
  A: TAgentArgs;
  Cfg: TConfig;
begin
  if not ParseArgs(Argv, A) then
  begin
    PrintLnErr('usage: pasclaw agent [-m "msg"] [--model M] [--provider P] [--system S]');
    PrintLnErr('                     [--thinking low|medium|high] [--max-tokens N]');
    PrintLnErr('                     [--max-iterations N] [--no-tools]');
    Exit(1);
  end;

  Cfg := LoadConfig;
  ConfigureSandbox(Cfg.Sandbox, '');
  try
    if A.Message <> '' then RunSingleTurn(Cfg, A, A.Message)
    else                    RunInteractive(Cfg, A);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
