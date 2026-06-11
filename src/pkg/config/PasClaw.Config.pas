{
  PasClaw.Config - build-time version constants, on-disk config struct,
  and helpers for resolving the PasClaw home directory.
  Mirrors pkg/config in picoclaw.
}
unit PasClaw.Config;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Stream.Reliability;

const
  (* Single source of truth for the product version is VersionFallback below;
     it gets bumped at release time and both compilers see the same value.
     FPC additionally honors a PASCLAW_VERSION environment variable at
     compile time (used by `make` to inject the short git SHA into
     development builds) -- if set it overrides VersionFallback at runtime;
     if empty the fallback wins. Delphi has no env-var equivalent, so
     Delphi builds always report VersionFallback. *)
  {$IFDEF FPC}
  VersionRaw = {$I %PASCLAW_VERSION%};
  {$ELSE}
  VersionRaw = '';
  {$ENDIF}
  VersionFallback = '0.1.0-dev';

  EnvHome   = 'PASCLAW_HOME';
  EnvConfig = 'PASCLAW_CONFIG';

type
  TGatewayConfig = record
    LogLevel: string;
    BindAddr: string;
    Port:     Integer;
  end;

  (*  TSandboxPolicy - opt-in workspace + shell hardening.

      RestrictToWorkspace
        When True, fs_read / fs_write / fs_list / fs_edit_hashline /
        fs_grep operations refuse paths outside Workspace, and the
        shell tool refuses commands whose absolute-path references
        leave Workspace. AllowReadOutsideWorkspace softens the read
        side (handy for letting an agent pull dependencies from
        /usr/include while still locking down writes).

      Workspace
        Absolute path of the directory the model may operate inside.
        Empty string means "use the current working directory at the
        time tools are configured" -- handy for invoking
        `pasclaw agent` from a project root.

      AllowReadPaths / AllowWritePaths
        Glob-style patterns (NOT full regex, just '*' and '?')
        listing extra paths the model may touch beyond Workspace.
        Picoclaw uses regex; we use globs to avoid pulling in a
        regex dependency and because globs cover the common cases
        (/tmp/*, ~/.cache/agent/*, /usr/share/* ).

      CustomShellDeny
        Substrings appended to the built-in shell denylist. Each
        match is checked case-insensitively against the command
        string. Use this to block project-specific commands the
        built-in list misses.

      ShellDenyEnabled
        Master switch for the shell denylist. Default True. Set
        False only for trusted automation; doing so re-enables
        `sudo`, `rm -rf`, `dd`, `mkfs`, command-substitution,
        `curl | sh`, and every other pattern in the list.

      BlockPrivateNetworks
        When True (default), web_fetch refuses URLs whose host
        resolves to a private / loopback / link-local IPv4
        address. Protects against the cloud-metadata SSRF (e.g.
        169.254.169.254 on AWS / GCP / Azure), against probes
        of internal LAN services (RFC1918 ranges), and against
        localhost service enumeration. See
        PasClaw.Net.SSRF for the full blocklist.
        Flip to False only when you actually need the model to
        reach private addresses (local dev mode, intranet
        scraping) and have weighed the credentials-leak risk.   *)
  TSandboxPolicy = record
    RestrictToWorkspace:       Boolean;
    AllowReadOutsideWorkspace: Boolean;
    Workspace:                 string;
    AllowReadPaths:            array of string;
    AllowWritePaths:           array of string;
    CustomShellDeny:           array of string;
    ShellDenyEnabled:          Boolean;
    BlockPrivateNetworks:      Boolean;
  end;

  TProviderConfig = record
    Name:    string;   { e.g. "anthropic", "openai" }
    Kind:    string;   { provider type id }
    APIBase: string;
    APIKey:  string;
    Model:   string;
  end;

  TMCPServer = record
    Name:    string;
    Cmd:     string;
    Args:    string;
    Env:     string;
    Enabled: Boolean;
  end;

  TCronEntry = record
    Id:            string;
    Spec:          string;   { cron expression }
    Skill:         string;
    Args:          string;
    Enabled:       Boolean;
    ChannelKind:   string;   { 'discord' | 'slack' | 'teams' | 'webhook' | 'line' | 'whatsapp' | '' }
    ChannelTarget: string;   { webhook URL, LINE userId, WhatsApp phone, etc. }
  end;

  TSkillEntry = record
    Name:    string;
    Source:  string;   { builtin | path | url }
    Enabled: Boolean;
  end;

  (* Named outbound channel for the send_message model tool (and,
     prospectively, anything else that wants operator-blessed posting
     targets). The model addresses channels strictly BY NAME -- the
     kind/target stay in config.json under operator control, so a
     prompt-injected model can't exfiltrate to an arbitrary webhook
     URL it made up; it can only post to endpoints the operator
     pre-declared. Kinds mirror `pasclaw post`: discord | slack |
     teams | webhook | line | whatsapp. *)
  TChannelEntry = record
    Name:   string;   { handle the model uses, e.g. "team-alerts" }
    Kind:   string;   { discord | slack | teams | webhook | line | whatsapp }
    Target: string;   { webhook URL / LINE to-id / WhatsApp phone number }
  end;

  (* TSubagentSpec - declaration of a named subagent the parent agent
     can fan out to via the `spawn` tool. Each spec is a focused
     "specialist" -- its own system prompt, an allowlist of tools
     inherited from the parent's registry, an optional model
     override, and an iteration cap. The spawned subagent runs as a
     standalone RunToolLoop call (not a separate TPasClawAgent) so it
     piggybacks on the parent's provider + fallback chain without
     paying the MCP / skill / registry-rebuild cost.

       Name         caller-facing name (lowercase, kebab-case)
       Description  one-line summary surfaced to the parent model
                    in the `spawn` tool's description so it can pick
                    the right specialist
       SystemPrompt the subagent's specialisation prompt -- replaces
                    the parent's prompt for this child turn
       Tools        names of parent-registry tools the subagent is
                    allowed to call. Empty means "no tools" (a
                    prompt-driven specialist). 'spawn' is always
                    excluded -- no nested sub-subagents in v1.
       Model        empty = inherit parent's model. Cross-provider
                    model names go through the fallback chain (same
                    as the parent's loop).
       MaxIter      iteration cap for the subagent's tool loop. 0
                    means default (4). Keep this tight -- the
                    subagent should produce a focused answer, not
                    nest into a long conversation. *)
  TSubagentSpec = record
    Name:          string;
    Description:   string;
    SystemPrompt:  string;
    Tools:         array of string;
    Model:         string;
    MaxIter:       Integer;
  end;
  { Named-type alias for dcc64 strict-array compatibility -- assigning
    Cfg.Subagents into a `TSubagentSpecArray` parameter (which
    PasClaw.Agent.Subagent.RegisterSpawnTool / TSpawnTool.Create take)
    used to E2010 because TConfig.Subagents was declared as an inline
    `array of TSubagentSpec`. Same pattern as TLLMProviderArray
    (PR #104) and TStringArray / TUInt32Array (PR #106). Owning the
    alias here means callers in higher layers pick it up by importing
    PasClaw.Config -- they don't have to re-declare. }
  TSubagentSpecArray = array of TSubagentSpec;

  (* TWebSearchConfig - web_search tool provider selection.
       Provider:   'duckduckgo' (default, no key) | 'brave' | 'tavily' |
                   'searxng'    | 'perplexity'
       APIKey:     fallback if no $PASCLAW_<KIND>_API_KEY env var.
       BaseURL:    instance host for 'searxng' (no default -- must be
                   set since SearXNG is self-hosted). Ignored by the
                   other providers.
       MaxResults: cap on hits per query; the tool caps further at 25
                   so a runaway model arg can't pull megabytes. *)
  TWebSearchConfig = record
    Provider:   string;
    APIKey:     string;
    BaseURL:    string;
    MaxResults: Integer;
  end;

  (* TAutoRouterConfig -- task-difficulty router (UltraCode-Shim
     shape). When Enabled and EasyProvider names a configured
     provider, the agent classifies each user message as
     easy / abstain / hard and routes the easy ones to
     EasyProvider for this turn; everything else stays on the
     primary. The existing Cfg.Fallbacks chain still applies on
     error -- the router only picks which provider gets called
     FIRST.
       Enabled:        master switch, default False.
       EasyProvider:   name of a configured provider (must appear
                       in Cfg.Providers[].Name). Operators picking
                       a fallback during onboarding land here.
       EasyModel:      optional model override on EasyProvider;
                       empty = use that provider's catalog default
                       (resolved by NewProviderFromConfig).
       EasyMaxTokens:  messages above this token estimate are
                       never routed easy. Default 500. Operators
                       working on prose-heavy projects can raise
                       this; coding-heavy work usually wants the
                       default. *)
  TAutoRouterConfig = record
    Enabled:       Boolean;
    EasyProvider:  string;
    EasyModel:     string;
    EasyMaxTokens: Integer;
  end;

  (* TPromptCacheConfig -- provider-side prompt caching.
       Enabled: gate; when False, no cache_control breakpoints are
                emitted and no prompt_cache_key is sent. Default True.
       TTL:     "" (default 5m) | "1h" (extended; Anthropic only).
                Other strings pass through verbatim on Anthropic; OpenAI
                ignores this field (auto-managed cache TTL).
     Cache keying for OpenAI's prompt_cache_key is automatic -- Cmd.Agent
     hands the persistent session id down through TChatOptions.CacheKey
     so each conversation gets its own cache bucket. *)
  TPromptCacheConfig = record
    Enabled: Boolean;
    TTL:     string;
  end;

  (* TStreamReliabilityConfig is declared in PasClaw.Stream.Reliability
     -- this unit re-exports nothing, just folds the record into
     TConfig as the persisted operator-facing shape. See the
     unit comment in PasClaw.Stream.Reliability for the four
     knobs and their semantics. Operators tune via config.json
     under "stream_reliability": {...} OR via the well-known
     env vars (UC_EMPTY_RETRY_ATTEMPTS, UC_EMPTY_RETRY_BACKOFF_MS,
     UC_STREAM_IDLE_TIMEOUT_SEC, UC_TOOL_CALL_REPAIR); env wins
     over config.json. *)

  (* Anthropic-only: register Anthropic's server-side web tools
     (web_search_20260209 / web_fetch_20260209) in the request's
     tools array. Claude runs the queries / fetches on Anthropic's
     side and stitches the results into the final response -- no
     round-trip through PasClaw's tool loop, no SearXNG / curl on
     the operator's box.

     Off by default. Only the Anthropic provider honours these;
     OpenAI / Gemini / others ignore them. When one of these is on,
     the Anthropic builder also drops any user-registered tool whose
     name collides (e.g. the local web_search tool) to avoid a
     duplicate-name 400 from the Messages API.

     MaxUses bounds how many times Claude may call the tool per turn;
     0 means "let Anthropic apply its default". See:
     https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview *)
  TAnthropicServerToolsConfig = record
    WebSearch:        Boolean;
    WebSearchMaxUses: Integer;
    WebFetch:         Boolean;
    WebFetchMaxUses:  Integer;
  end;

  (* OpenAI Chat Completions: opt-in server-side web search.
     Emits "web_search_options": {} as a top-level request field
     when WebSearch is True. Only OpenAI's search-capable models
     honour the field -- currently `gpt-5-search-api` (and the
     deprecated `gpt-4o-search-preview` / `gpt-4o-mini-search-preview`,
     shutdown 2026-07-23). The operator must set Cfg.DefaultModel
     (or per-call model) to one of those; on `gpt-4o` and friends
     OpenAI silently ignores the field.

     Off by default. Third-party OpenAI-compatible endpoints
     (Groq, OpenRouter, Together, vLLM, Ollama) do NOT recognise
     web_search_options -- flipping this on while pointed at one
     of them is harmless but pointless.

     Unlike Anthropic's tools-array entry, this is a top-level
     parameter -- it does NOT collide with a user-defined
     `web_search` function tool. Both can be active at once.

     See: https://developers.openai.com/api/docs/guides/tools-web-search *)
  TOpenAIServerToolsConfig = record
    WebSearch: Boolean;
  end;

  (* Gemini: opt-in server-side Google search grounding.
     Emits a `google_search` entry inside the top-level `tools`
     array with an empty config object as its value, when
     GoogleSearch is True. Gemini executes the search server-side
     and returns grounded text; no local web_search tool runs.

     Model gating happens at the Gemini provider's BuildRequest
     boundary (IsGemini3OrLater), so default-on is safe across
     the model matrix:
       Gemini 3.x+        always emitted; combines with
                          functionDeclarations on the same request.
       Gemini 2.x         emitted only when no local tools are
                          registered. Mixing google_search with
                          functionDeclarations 400s on 2.x; the
                          provider silently suppresses the search
                          this turn to preserve the user's tools.
                          With no local tools, the bare
                          google_search request works.
       Gemini 1.5 / 1.0   `google_search` is the wrong wire shape
                          (1.x used `google_search_retrieval`,
                          which we don't emit). Bare google_search
                          requests 400. Operators on 1.x should
                          set google_search: false in config.json
                          or move to a 2.x+ model. The catalog
                          default is gemini-3.5-flash so the
                          common path "just works".

     On-by-default. Most operators picking Gemini want grounding;
     leaving it off would hide a free capability. Operators who
     embed a custom function tool named "google_search" (rare --
     the name collides with the Anthropic/OpenAI patterns) will
     hit a duplicate-name 400 on Gemini and should disable this. *)
  TGeminiServerToolsConfig = record
    GoogleSearch: Boolean;
  end;

  TConfig = class
  public
    DefaultProvider: string;
    DefaultModel:    string;
    { Provider names (matching TProviderConfig.Name) to try after
      DefaultProvider when the primary returns a retryable error
      (HTTP 429 / 5xx, network/TLS failure). Walked in order. Empty
      array (default) means no fallback -- primary failure surfaces
      directly. Configured via `pasclaw auth fallback openai gemini`
      or by editing config.json's "fallbacks": ["openai","gemini"]. }
    Fallbacks:  array of string;
    Gateway:    TGatewayConfig;
    Sandbox:    TSandboxPolicy;
    Providers:  array of TProviderConfig;
    MCPServers: array of TMCPServer;
    Crons:      array of TCronEntry;
    Skills:     array of TSkillEntry;
    Subagents:  TSubagentSpecArray;  { see comment on the type alias }
    WebSearch:  TWebSearchConfig;
    PromptCache: TPromptCacheConfig;
    (* Sender allowlist -- canonical PasClaw.Identity strings or
       wildcards ("slack:U123", "telegram:*", "*"). Channels call
       PasClaw.Identity.IsAllowedSender(Identity, AllowSenders)
       before invoking the agent; empty array = no gate (matches
       picoclaw's pkg/channels/base.go IsAllowedSender semantics).
       Configure via "allow_senders": [...] in config.json. *)
    AllowSenders: array of string;
    (* Off-by-default: when True, Cmd.Agent.NewBuiltinRegistry
       registers vault_search and vault_get for the model. The
       onboarding flow asks the user to opt in (default yes).
       Operators who skip onboarding can flip this directly in
       config.json or re-run `pasclaw onboard`. *)
    VaultToolsEnabled: Boolean;
    (* Off-by-default: when True, Cmd.Agent / Cmd.Gateway / Cmd.Serve
       register the web_fetch tool. Picoclaw doesn't ship a web_fetch
       -- its model fetches arbitrary URLs through shell + curl -- so
       PasClaw's default posture mirrors that. Flip this on for
       deployments where curl isn't available (sandboxed containers,
       constrained shells), or where the operator wants the tracked
       web_fetch path with its size cap / save_to convenience. *)
    WebFetchEnabled:   Boolean;
    (* On-by-default: when True, memory_search uses a hybrid keyword
       (FTS5 BM25) + vector (sqlite-vec ANN) index over
       workspace/memory/ files, fused via Reciprocal Rank Fusion.
       Mirrors picoclaw/nanobot's hybrid memory store.

       The vector half runs locally -- an ONNX-Runtime'd embedding
       model (e.g. all-MiniLM-L6-v2 / bge-small) embeds query text
       and indexed chunks at write time. No outbound API calls;
       embeddings never leave the host.

       Provisioning is deferred until first use. Onboarding records
       the operator's preference here; the runtime path (download
       ONNX Runtime DLL, embedding model weights, sqlite-vec
       extension) lives in PasClaw.Memory.Vector (follow-up PR).
       When False, memory_search degrades to FTS5-only (the
       current behaviour on main) -- operators who don't want
       300+MB of model weights on disk can flip this in
       config.json or answer 'n' at onboarding. *)
    VectorSearchEnabled: Boolean;
    (* Render markdown the model emits as ANSI-styled text in the
       terminal (PasClaw.Markdown.Render). On by default -- terminal
       surfaces (pasclaw agent, pasclaw tui) call into it; serve /
       gateway leave it off because they return JSON to clients
       where ANSI escapes would be wrong. Flip in config.json or
       via --no-render-markdown on the agent command. picoclaw
       doesn't render markdown at all and emits raw stars / hashes;
       nanobot gets it for free via Python's rich library. *)
    RenderMarkdown:    Boolean;
    (* Cap on per-tool-result bytes that enter the LLM context window.
       When > 0, RunToolLoop diverts overlong tool outputs into the
       process-lifetime PasClaw.Tools.OutputCache and replaces the
       in-context body with a head + tail snippet plus a handle the
       model can dereference via `tool_output_get`. Default 0 = off
       (legacy verbatim behaviour). Operators flip it on in
       config.json under "tool_output_cap" -- 8192 is a reasonable
       starting cap (≈ 2K tokens). *)
    ToolOutputCap:     Integer;
    (* Persist per-session usage counters (tokens, turns, tool calls,
       truncation savings) into the session JSON so /v1/stats can
       aggregate across sessions for the gateway / web UI. Default
       False (opt-in via onboarding) -- when off, the tool-loop
       hooks short-circuit and the schema diff vs. pre-feature
       sessions is zero. The TUI's /stats overlay is independent of
       this flag (it keeps an in-memory accumulator), so flipping
       it off doesn't disable the in-process view. *)
    StatsCollectionEnabled: Boolean;
    (* Per-edit checkpoints + `/undo`. When True, fs_write and
       fs_edit_hashline snapshot the pre-edit bytes of every file they
       touch into workspace/checkpoints/<session-id>/turn-NNNN/ before
       writing; the TUI's /undo command rewinds N turns by restoring
       those captures. Off by default because it can be heavy -- a
       turn that overwrites a 5 MB generated file copies the whole 5 MB
       per turn. KeepLast caps how many turn dirs survive (older auto-
       pruned). 0 means default (32). Opt in via `pasclaw onboard` or
       by flipping checkpoints_enabled in config.json. *)
    CheckpointsEnabled:    Boolean;
    CheckpointsKeepLast:   Integer;
    (* On-by-default: scan tool output / recalled memory / stored
       skill descriptions for prompt-injection patterns and annotate
       hits with a warning banner (PasClaw.Promptware). A lowercase
       substring scan over bytes already in memory -- effectively
       free. "promptware_enabled": false opts out. *)
    PromptwareEnabled:     Boolean;
    (* Off-by-default: when True AND the caller passes a task hint to
       BuildSystemPrompt, the MEMORY section injects only the
       sections of MEMORY.md / daily notes that lexically overlap the
       task, instead of the whole files (PasClaw.Agent.Orient). Whole-
       file injection stays the default because slicing changes what
       the model sees -- operators opt in via "orient_task_aware":
       true once their MEMORY.md outgrows the always-inject budget. *)
    OrientTaskAware:       Boolean;
    (* Named outbound channels for the send_message model tool.
       Empty (default) = tool not registered. Configured via
       config.json: "channels": [{"name":"team-alerts",
       "kind":"slack","target":"https://hooks.slack.com/..."}]. *)
    Channels:   array of TChannelEntry;
    AutoRouter:           TAutoRouterConfig;
    AnthropicServerTools: TAnthropicServerToolsConfig;
    OpenAIServerTools:    TOpenAIServerToolsConfig;
    GeminiServerTools:    TGeminiServerToolsConfig;
    StreamReliability:    TStreamReliabilityConfig;
    constructor Create;
    function  ToJSON: string;
    procedure FromJSON(const S: string);
  end;

function GetHome: string;
function GetConfigPath: string;
function LoadConfig: TConfig;
procedure SaveConfig(C: TConfig);
function FormatVersion: string;
function FormatBuildInfo: string;

(* Fold the operator's prompt_cache config into a TChatOptions that
   was just initialised from DefaultChatOptions. Call this at every
   config-backed site that builds chat options (CLI, channels, gateway,
   TUI, embedder TPasClawAgent) so `prompt_cache.enabled: false` in
   config.json reliably turns caching off on every code path -- not
   just `pasclaw agent`. (Codex P2 on PR #118: opt-out was only wired
   through Cmd.Agent.BuildLoopConfig.) Library-level DefaultChatOptions
   stays default-on so embedders who never build a TConfig still get
   the feature; passing a TPromptCacheConfig from a loaded TConfig is
   what makes operator-disable stick. *)
procedure ApplyPromptCacheConfig(var Opts: TChatOptions; const PC: TPromptCacheConfig);

implementation

uses
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Promptware;   { LoadConfig propagates promptware_enabled --
                          see the comment inside LoadConfig }

procedure ApplyPromptCacheConfig(var Opts: TChatOptions; const PC: TPromptCacheConfig);
begin
  Opts.CacheEnabled := PC.Enabled;
  Opts.CacheTTL     := PC.TTL;
end;

constructor TConfig.Create;
begin
  inherited Create;
  DefaultProvider := 'anthropic';
  DefaultModel    := 'claude-opus-4-7';
  Gateway.LogLevel := 'info';
  Gateway.BindAddr := '127.0.0.1';
  Gateway.Port     := 8088;
  { Sandbox defaults: workspace boundary OFF for backwards compat
    (existing configs do not have a sandbox section), shell denylist
    ON because it's a strict safety upgrade over the previous
    six-substring check and no legitimate use ever passed it. Flip
    RestrictToWorkspace to True in config.json to lock the FS tools
    down to a chosen directory. }
  Sandbox.RestrictToWorkspace       := False;
  Sandbox.AllowReadOutsideWorkspace := False;
  Sandbox.Workspace                 := '';
  Sandbox.ShellDenyEnabled          := True;
  Sandbox.BlockPrivateNetworks      := True;
  WebSearch.Provider   := '';   { empty = duckduckgo fallback }
  WebSearch.APIKey     := '';
  WebSearch.BaseURL    := '';
  WebSearch.MaxResults := 5;
  PromptCache.Enabled  := True;  { default-on; see TPromptCacheConfig comment }
  PromptCache.TTL      := '';    { default 5m via empty }
  VaultToolsEnabled    := False; { off by default; onboarding asks to opt in }
  WebFetchEnabled      := False; { off by default; the model uses shell+curl }
  RenderMarkdown       := True;  { on by default for terminal surfaces; cmd/serve flips off }
  ToolOutputCap        := 0;     { off by default; operators opt in. See TConfig.ToolOutputCap. }
  StatsCollectionEnabled := False; { opt-in via onboarding; see TConfig.StatsCollectionEnabled. }
  CheckpointsEnabled     := False; { opt-in via onboarding; see TConfig.CheckpointsEnabled. }
  CheckpointsKeepLast    := 0;     { 0 means default (32) inside PasClaw.Checkpoints. }
  PromptwareEnabled      := True;  { on by default -- substring scan, effectively free. }
  OrientTaskAware        := False; { opt-in; whole-file MEMORY injection is the contract. }
  SetLength(Channels, 0);          { no channels -> send_message tool not registered. }
  AutoRouter.Enabled        := False;  { opt-in via onboarding; see TAutoRouterConfig. }
  AutoRouter.EasyProvider   := '';
  AutoRouter.EasyModel      := '';
  AutoRouter.EasyMaxTokens  := 500;
  VectorSearchEnabled  := True;  { on by default; onboarding asks (default Y) -- see TConfig comment }
  AnthropicServerTools.WebSearch        := False;
  AnthropicServerTools.WebSearchMaxUses := 0;
  AnthropicServerTools.WebFetch         := False;
  AnthropicServerTools.WebFetchMaxUses  := 0;
  { Default-on: OpenAI's web_search_options is silently ignored on
    every non-search-capable model (gpt-4o, gpt-4o-mini, etc.) and
    on third-party OpenAI-compatible endpoints (Groq, OpenRouter,
    vLLM, Ollama), so leaving it on costs nothing there. Operators
    who pick gpt-5-search-api as their model get server-side search
    "for free" with no extra config step. Flip to False in
    config.json to suppress emitting the field entirely. }
  OpenAIServerTools.WebSearch           := True;
  { Default-on for the same reason as OpenAI's web_search: most
    Gemini operators want grounding and the catalog default model
    (gemini-3.5-flash) accepts the field. See the type comment for
    the model-compat caveat. }
  GeminiServerTools.GoogleSearch        := True;
  { Stream reliability defaults match the UltraCode-Shim shipping
    config -- conservative enough that operators on healthy
    backends never notice, aggressive enough to recover the
    common brownout cases (Together / OpenRouter route hiccups,
    DeepSeek thinking-token overflow). }
  StreamReliability.EmptyRetryAttempts    := 2;
  StreamReliability.EmptyRetryBackoffMs   := 750;
  StreamReliability.StreamIdleTimeoutMs   := 150 * 1000;
  StreamReliability.ToolCallRepairEnabled := True;
end;

function ProviderToJSON(const P: TProviderConfig): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr('name',     P.Name);
  Result.PutStr('kind',     P.Kind);
  Result.PutStr('api_base', P.APIBase);
  Result.PutStr('api_key',  P.APIKey);
  Result.PutStr('model',    P.Model);
end;

function MCPToJSON(const M: TMCPServer): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr ('name',    M.Name);
  Result.PutStr ('cmd',     M.Cmd);
  Result.PutStr ('args',    M.Args);
  Result.PutStr ('env',     M.Env);
  Result.PutBool('enabled', M.Enabled);
end;

function CronToJSON(const C: TCronEntry): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr ('id',      C.Id);
  Result.PutStr ('spec',    C.Spec);
  Result.PutStr ('skill',   C.Skill);
  Result.PutStr ('args',    C.Args);
  Result.PutBool('enabled', C.Enabled);
  if C.ChannelKind   <> '' then Result.PutStr('channel_kind',   C.ChannelKind);
  if C.ChannelTarget <> '' then Result.PutStr('channel_target', C.ChannelTarget);
end;

function SkillToJSON(const S: TSkillEntry): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr ('name',    S.Name);
  Result.PutStr ('source',  S.Source);
  Result.PutBool('enabled', S.Enabled);
end;

function SubagentToJSON(const S: TSubagentSpec): TJsonObject;
var
  ToolsArr: TJsonArray;
  i: Integer;
begin
  Result := TJsonObject.Create;
  Result.PutStr('name',          S.Name);
  Result.PutStr('description',   S.Description);
  Result.PutStr('system_prompt', S.SystemPrompt);
  if Length(S.Tools) > 0 then
  begin
    ToolsArr := TJsonArray.Create;
    for i := 0 to High(S.Tools) do
      ToolsArr.AddStr(S.Tools[i]);
    Result.PutArray('tools', ToolsArr);
  end;
  if S.Model <> '' then Result.PutStr('model', S.Model);
  if S.MaxIter > 0 then Result.PutInt('max_iterations', S.MaxIter);
end;

function TConfig.ToJSON: string;
var
  Root, Gw, Tmp: TJsonObject;
  Arr, FallbacksArr: TJsonArray;
  i: Integer;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('default_provider', DefaultProvider);
    Root.PutStr('default_model',    DefaultModel);
    if Length(Fallbacks) > 0 then
    begin
      FallbacksArr := TJsonArray.Create;
      for i := 0 to High(Fallbacks) do
        FallbacksArr.AddStr(Fallbacks[i]);
      Root.PutArray('fallbacks', FallbacksArr);  { takes ownership; sets FallbacksArr := nil }
    end;

    Gw := TJsonObject.Create;
    Gw.PutStr ('log_level', Gateway.LogLevel);
    Gw.PutStr ('bind_addr', Gateway.BindAddr);
    Gw.PutInt ('port',      Gateway.Port);
    Root.PutObject('gateway', Gw);

    Tmp := TJsonObject.Create;
    Tmp.PutBool('restrict_to_workspace',        Sandbox.RestrictToWorkspace);
    Tmp.PutBool('allow_read_outside_workspace', Sandbox.AllowReadOutsideWorkspace);
    Tmp.PutStr ('workspace',                    Sandbox.Workspace);
    Tmp.PutBool('shell_deny_enabled',           Sandbox.ShellDenyEnabled);
    Tmp.PutBool('block_private_networks',       Sandbox.BlockPrivateNetworks);
    Arr := TJsonArray.Create;
    for i := 0 to High(Sandbox.AllowReadPaths)  do Arr.AddStr(Sandbox.AllowReadPaths[i]);
    Tmp.PutArray('allow_read_paths',  Arr);
    Arr := TJsonArray.Create;
    for i := 0 to High(Sandbox.AllowWritePaths) do Arr.AddStr(Sandbox.AllowWritePaths[i]);
    Tmp.PutArray('allow_write_paths', Arr);
    Arr := TJsonArray.Create;
    for i := 0 to High(Sandbox.CustomShellDeny) do Arr.AddStr(Sandbox.CustomShellDeny[i]);
    Tmp.PutArray('custom_shell_deny', Arr);
    Root.PutObject('sandbox', Tmp);

    if (WebSearch.Provider <> '') or (WebSearch.APIKey <> '')
       or (WebSearch.BaseURL <> '') or (WebSearch.MaxResults <> 5) then
    begin
      Tmp := TJsonObject.Create;
      Tmp.PutStr('provider',    WebSearch.Provider);
      Tmp.PutStr('api_key',     WebSearch.APIKey);
      Tmp.PutStr('base_url',    WebSearch.BaseURL);
      Tmp.PutInt('max_results', WebSearch.MaxResults);
      Root.PutObject('web_search', Tmp);
    end;

    { Only emit prompt_cache when non-default -- keeps stock configs
      tidy. Reading back: missing object => defaults (enabled, 5m). }
    if (not PromptCache.Enabled) or (PromptCache.TTL <> '') then
    begin
      Tmp := TJsonObject.Create;
      Tmp.PutBool('enabled', PromptCache.Enabled);
      Tmp.PutStr ('ttl',     PromptCache.TTL);
      Root.PutObject('prompt_cache', Tmp);
    end;

    if Length(AllowSenders) > 0 then
    begin
      Arr := TJsonArray.Create;
      for i := 0 to High(AllowSenders) do Arr.AddStr(AllowSenders[i]);
      Root.PutArray('allow_senders', Arr);
    end;

    { Off-by-default -- only serialise when True so stock configs stay tidy. }
    if VaultToolsEnabled then
      Root.PutBool('vault_tools_enabled', True);
    if WebFetchEnabled then
      Root.PutBool('web_fetch_enabled', True);
    { RenderMarkdown defaults to True; emit only when operator
      explicitly disabled it so they can flip it back via config.json
      and we round-trip correctly. }
    if not RenderMarkdown then
      Root.PutBool('render_markdown', False);
    { Same round-trip rule as RenderMarkdown -- default is True, only
      emit on the explicit-off path so 'memory_search: false' sticks
      across SaveConfig + LoadConfig. }
    if not VectorSearchEnabled then
      Root.PutBool('vector_search_enabled', False);
    { Tool output cap: emit only when an operator has explicitly
      opted in. 0 (off) is the default; suppressing it from the
      JSON keeps fresh config files clean. }
    if ToolOutputCap > 0 then
      Root.PutInt('tool_output_cap', ToolOutputCap);
    if StatsCollectionEnabled then
      Root.PutBool('stats_collection_enabled', True);
    if CheckpointsEnabled then
      Root.PutBool('checkpoints_enabled', True);
    if CheckpointsKeepLast > 0 then
      Root.PutInt('checkpoints_keep_last', CheckpointsKeepLast);
    { Default True -- emit only the explicit-off so it round-trips
      (same rule as render_markdown / vector_search_enabled). }
    if not PromptwareEnabled then
      Root.PutBool('promptware_enabled', False);
    { Default False -- emit only the explicit-on. }
    if OrientTaskAware then
      Root.PutBool('orient_task_aware', True);
    if AutoRouter.Enabled
       or (AutoRouter.EasyProvider <> '')
       or (AutoRouter.EasyModel <> '')
       or (AutoRouter.EasyMaxTokens <> 500) then
    begin
      Tmp := TJsonObject.Create;
      try
        Tmp.PutBool('enabled',         AutoRouter.Enabled);
        Tmp.PutStr ('easy_provider',   AutoRouter.EasyProvider);
        Tmp.PutStr ('easy_model',      AutoRouter.EasyModel);
        Tmp.PutInt ('easy_max_tokens', AutoRouter.EasyMaxTokens);
        Root.PutObject('auto_router', Tmp);
      except
        Tmp.Free; raise;
      end;
    end;
    if AnthropicServerTools.WebSearch
       or AnthropicServerTools.WebFetch
       or (AnthropicServerTools.WebSearchMaxUses > 0)
       or (AnthropicServerTools.WebFetchMaxUses > 0) then
    begin
      Tmp := TJsonObject.Create;
      if AnthropicServerTools.WebSearch then Tmp.PutBool('web_search', True);
      if AnthropicServerTools.WebSearchMaxUses > 0 then
        Tmp.PutInt('web_search_max_uses', AnthropicServerTools.WebSearchMaxUses);
      if AnthropicServerTools.WebFetch then Tmp.PutBool('web_fetch', True);
      if AnthropicServerTools.WebFetchMaxUses > 0 then
        Tmp.PutInt('web_fetch_max_uses', AnthropicServerTools.WebFetchMaxUses);
      Root.PutObject('anthropic_server_tools', Tmp);
    end;
    { Always emit -- the default flipped to True in #146, so an
      operator who sets web_search: false in config.json needs that
      setting to round-trip. Skipping the emit when False would let
      the default win on the next load. }
    Tmp := TJsonObject.Create;
    Tmp.PutBool('web_search', OpenAIServerTools.WebSearch);
    Root.PutObject('openai_server_tools', Tmp);

    { Same round-trip rule as the OpenAI block: the default is True,
      so we must emit unconditionally -- otherwise `google_search:
      false` in config.json silently reverts on the next load. }
    Tmp := TJsonObject.Create;
    Tmp.PutBool('google_search', GeminiServerTools.GoogleSearch);
    Root.PutObject('gemini_server_tools', Tmp);

    { Emit stream_reliability only when at least one knob differs
      from the defaults -- keeps stock configs tidy. The reader
      below initialises each field from the live default before
      overlaying JSON values so missing keys round-trip cleanly. }
    if (StreamReliability.EmptyRetryAttempts    <> 2)         or
       (StreamReliability.EmptyRetryBackoffMs   <> 750)       or
       (StreamReliability.StreamIdleTimeoutMs   <> 150 * 1000) or
       (not StreamReliability.ToolCallRepairEnabled)          then
    begin
      Tmp := TJsonObject.Create;
      Tmp.PutInt ('empty_retry_attempts',     StreamReliability.EmptyRetryAttempts);
      Tmp.PutInt ('empty_retry_backoff_ms',   StreamReliability.EmptyRetryBackoffMs);
      Tmp.PutInt ('stream_idle_timeout_ms',   StreamReliability.StreamIdleTimeoutMs);
      Tmp.PutBool('tool_call_repair_enabled', StreamReliability.ToolCallRepairEnabled);
      Root.PutObject('stream_reliability', Tmp);
    end;

    Arr := TJsonArray.Create;
    for i := 0 to High(Providers) do
    begin
      Tmp := ProviderToJSON(Providers[i]);
      Arr.AddObject(Tmp);
    end;
    Root.PutArray('providers', Arr);

    Arr := TJsonArray.Create;
    for i := 0 to High(MCPServers) do
    begin
      Tmp := MCPToJSON(MCPServers[i]);
      Arr.AddObject(Tmp);
    end;
    Root.PutArray('mcp_servers', Arr);

    Arr := TJsonArray.Create;
    for i := 0 to High(Crons) do
    begin
      Tmp := CronToJSON(Crons[i]);
      Arr.AddObject(Tmp);
    end;
    Root.PutArray('crons', Arr);

    if Length(Channels) > 0 then
    begin
      Arr := TJsonArray.Create;
      for i := 0 to High(Channels) do
      begin
        Tmp := TJsonObject.Create;
        Tmp.PutStr('name',   Channels[i].Name);
        Tmp.PutStr('kind',   Channels[i].Kind);
        Tmp.PutStr('target', Channels[i].Target);
        Arr.AddObject(Tmp);
      end;
      Root.PutArray('channels', Arr);
    end;

    Arr := TJsonArray.Create;
    for i := 0 to High(Skills) do
    begin
      Tmp := SkillToJSON(Skills[i]);
      Arr.AddObject(Tmp);
    end;
    Root.PutArray('skills', Arr);

    if Length(Subagents) > 0 then
    begin
      Arr := TJsonArray.Create;
      for i := 0 to High(Subagents) do
      begin
        Tmp := SubagentToJSON(Subagents[i]);
        Arr.AddObject(Tmp);
      end;
      Root.PutArray('subagents', Arr);
    end;

    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

procedure TConfig.FromJSON(const S: string);
var
  Root, Obj, Item: TJsonObject;
  Arr, ToolsArr: TJsonArray;
  i, j: Integer;
begin
  if Trim(S) = '' then Exit;
  Root := TJsonObject.Parse(S);
  if Root = nil then Exit;
  try
    DefaultProvider := Root.GetStr('default_provider', DefaultProvider);
    DefaultModel    := Root.GetStr('default_model',    DefaultModel);
    if Root.Has('fallbacks') then
    begin
      Arr := Root.ChildArray('fallbacks');
      if Arr <> nil then
      try
        SetLength(Fallbacks, Arr.Count);
        for i := 0 to Arr.Count - 1 do
          Fallbacks[i] := Arr.ItemStr(i);
      finally
        Arr.Free;
      end;
    end;

    Obj := Root.ChildObject('gateway');
    if Obj <> nil then
    try
      Gateway.LogLevel := Obj.GetStr('log_level', Gateway.LogLevel);
      Gateway.BindAddr := Obj.GetStr('bind_addr', Gateway.BindAddr);
      Gateway.Port     := Obj.GetInt('port',      Gateway.Port);
    finally
      Obj.Free;
    end;

    Obj := Root.ChildObject('sandbox');
    if Obj <> nil then
    try
      Sandbox.RestrictToWorkspace       := Obj.GetBool('restrict_to_workspace',        Sandbox.RestrictToWorkspace);
      Sandbox.AllowReadOutsideWorkspace := Obj.GetBool('allow_read_outside_workspace', Sandbox.AllowReadOutsideWorkspace);
      Sandbox.Workspace                 := Obj.GetStr ('workspace',                    Sandbox.Workspace);
      Sandbox.ShellDenyEnabled          := Obj.GetBool('shell_deny_enabled',           Sandbox.ShellDenyEnabled);
      Sandbox.BlockPrivateNetworks      := Obj.GetBool('block_private_networks',       Sandbox.BlockPrivateNetworks);
      Arr := Obj.ChildArray('allow_read_paths');
      if Arr <> nil then
      try
        SetLength(Sandbox.AllowReadPaths, Arr.Count);
        for i := 0 to Arr.Count - 1 do Sandbox.AllowReadPaths[i] := Arr.ItemStr(i, '');
      finally
        Arr.Free;
      end;
      Arr := Obj.ChildArray('allow_write_paths');
      if Arr <> nil then
      try
        SetLength(Sandbox.AllowWritePaths, Arr.Count);
        for i := 0 to Arr.Count - 1 do Sandbox.AllowWritePaths[i] := Arr.ItemStr(i, '');
      finally
        Arr.Free;
      end;
      Arr := Obj.ChildArray('custom_shell_deny');
      if Arr <> nil then
      try
        SetLength(Sandbox.CustomShellDeny, Arr.Count);
        for i := 0 to Arr.Count - 1 do Sandbox.CustomShellDeny[i] := Arr.ItemStr(i, '');
      finally
        Arr.Free;
      end;
    finally
      Obj.Free;
    end;

    Obj := Root.ChildObject('web_search');
    if Obj <> nil then
    try
      WebSearch.Provider   := Obj.GetStr('provider',    WebSearch.Provider);
      WebSearch.APIKey     := Obj.GetStr('api_key',     WebSearch.APIKey);
      WebSearch.BaseURL    := Obj.GetStr('base_url',    WebSearch.BaseURL);
      WebSearch.MaxResults := Obj.GetInt('max_results', WebSearch.MaxResults);
    finally
      Obj.Free;
    end;

    Obj := Root.ChildObject('prompt_cache');
    if Obj <> nil then
    try
      PromptCache.Enabled := Obj.GetBool('enabled', PromptCache.Enabled);
      PromptCache.TTL     := Obj.GetStr ('ttl',     PromptCache.TTL);
    finally
      Obj.Free;
    end;

    Arr := Root.ChildArray('allow_senders');
    if Arr <> nil then
    try
      SetLength(AllowSenders, Arr.Count);
      for i := 0 to Arr.Count - 1 do AllowSenders[i] := Arr.ItemStr(i, '');
    finally
      Arr.Free;
    end;

    VaultToolsEnabled   := Root.GetBool('vault_tools_enabled',   VaultToolsEnabled);
    WebFetchEnabled     := Root.GetBool('web_fetch_enabled',     WebFetchEnabled);
    RenderMarkdown      := Root.GetBool('render_markdown',       RenderMarkdown);
    VectorSearchEnabled := Root.GetBool('vector_search_enabled', VectorSearchEnabled);
    ToolOutputCap       := Integer(Root.GetInt('tool_output_cap', ToolOutputCap));
    StatsCollectionEnabled := Root.GetBool('stats_collection_enabled',
                                           StatsCollectionEnabled);
    CheckpointsEnabled  := Root.GetBool('checkpoints_enabled', CheckpointsEnabled);
    CheckpointsKeepLast := Integer(Root.GetInt('checkpoints_keep_last',
                                                CheckpointsKeepLast));
    PromptwareEnabled   := Root.GetBool('promptware_enabled', PromptwareEnabled);
    OrientTaskAware     := Root.GetBool('orient_task_aware',  OrientTaskAware);

    Obj := Root.ChildObject('auto_router');
    if Obj <> nil then
    try
      AutoRouter.Enabled       := Obj.GetBool('enabled',         AutoRouter.Enabled);
      AutoRouter.EasyProvider  := Obj.GetStr ('easy_provider',   AutoRouter.EasyProvider);
      AutoRouter.EasyModel     := Obj.GetStr ('easy_model',      AutoRouter.EasyModel);
      AutoRouter.EasyMaxTokens := Integer(Obj.GetInt('easy_max_tokens',
                                          AutoRouter.EasyMaxTokens));
    finally
      Obj.Free;
    end;

    Obj := Root.ChildObject('anthropic_server_tools');
    if Obj <> nil then
    try
      AnthropicServerTools.WebSearch :=
        Obj.GetBool('web_search', AnthropicServerTools.WebSearch);
      AnthropicServerTools.WebSearchMaxUses :=
        Obj.GetInt('web_search_max_uses', AnthropicServerTools.WebSearchMaxUses);
      AnthropicServerTools.WebFetch :=
        Obj.GetBool('web_fetch', AnthropicServerTools.WebFetch);
      AnthropicServerTools.WebFetchMaxUses :=
        Obj.GetInt('web_fetch_max_uses', AnthropicServerTools.WebFetchMaxUses);
    finally
      Obj.Free;
    end;

    Obj := Root.ChildObject('openai_server_tools');
    if Obj <> nil then
    try
      OpenAIServerTools.WebSearch :=
        Obj.GetBool('web_search', OpenAIServerTools.WebSearch);
    finally
      Obj.Free;
    end;

    Obj := Root.ChildObject('gemini_server_tools');
    if Obj <> nil then
    try
      GeminiServerTools.GoogleSearch :=
        Obj.GetBool('google_search', GeminiServerTools.GoogleSearch);
    finally
      Obj.Free;
    end;

    Obj := Root.ChildObject('stream_reliability');
    if Obj <> nil then
    try
      StreamReliability.EmptyRetryAttempts :=
        Integer(Obj.GetInt('empty_retry_attempts',  StreamReliability.EmptyRetryAttempts));
      StreamReliability.EmptyRetryBackoffMs :=
        Integer(Obj.GetInt('empty_retry_backoff_ms', StreamReliability.EmptyRetryBackoffMs));
      StreamReliability.StreamIdleTimeoutMs :=
        Integer(Obj.GetInt('stream_idle_timeout_ms', StreamReliability.StreamIdleTimeoutMs));
      StreamReliability.ToolCallRepairEnabled :=
        Obj.GetBool('tool_call_repair_enabled',     StreamReliability.ToolCallRepairEnabled);
    finally
      Obj.Free;
    end;

    Arr := Root.ChildArray('providers');
    if Arr <> nil then
    try
      SetLength(Providers, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          Providers[i].Name    := Item.GetStr('name',     '');
          Providers[i].Kind    := Item.GetStr('kind',     '');
          Providers[i].APIBase := Item.GetStr('api_base', '');
          Providers[i].APIKey  := Item.GetStr('api_key',  '');
          Providers[i].Model   := Item.GetStr('model',    '');
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;

    Arr := Root.ChildArray('mcp_servers');
    if Arr <> nil then
    try
      SetLength(MCPServers, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          MCPServers[i].Name    := Item.GetStr ('name',    '');
          MCPServers[i].Cmd     := Item.GetStr ('cmd',     '');
          MCPServers[i].Args    := Item.GetStr ('args',    '');
          MCPServers[i].Env     := Item.GetStr ('env',     '');
          MCPServers[i].Enabled := Item.GetBool('enabled', True);
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;

    Arr := Root.ChildArray('crons');
    if Arr <> nil then
    try
      SetLength(Crons, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          Crons[i].Id            := Item.GetStr ('id',             '');
          Crons[i].Spec          := Item.GetStr ('spec',           '');
          Crons[i].Skill         := Item.GetStr ('skill',          '');
          Crons[i].Args          := Item.GetStr ('args',           '');
          Crons[i].Enabled       := Item.GetBool('enabled',        True);
          Crons[i].ChannelKind   := Item.GetStr ('channel_kind',   '');
          Crons[i].ChannelTarget := Item.GetStr ('channel_target', '');
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;

    Arr := Root.ChildArray('skills');
    if Arr <> nil then
    try
      SetLength(Skills, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          Skills[i].Name    := Item.GetStr ('name',    '');
          Skills[i].Source  := Item.GetStr ('source',  '');
          Skills[i].Enabled := Item.GetBool('enabled', True);
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;

    Arr := Root.ChildArray('channels');
    if Arr <> nil then
    try
      SetLength(Channels, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          Channels[i].Name   := Item.GetStr('name',   '');
          Channels[i].Kind   := Item.GetStr('kind',   '');
          (* Accept "url" as an alias -- the Cmd.Post header has long
             documented channels entries as objects with name/kind/url
             keys, so configs written against that doc shape keep
             working. (Paren-star comment: the literal braces in the
             JSON shape would close a curly-brace comment early.) *)
          Channels[i].Target := Item.GetStr('target', '');
          if Channels[i].Target = '' then
            Channels[i].Target := Item.GetStr('url', '');
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;

    Arr := Root.ChildArray('subagents');
    if Arr <> nil then
    try
      SetLength(Subagents, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          Subagents[i].Name         := Item.GetStr('name',          '');
          Subagents[i].Description  := Item.GetStr('description',   '');
          Subagents[i].SystemPrompt := Item.GetStr('system_prompt', '');
          Subagents[i].Model        := Item.GetStr('model',         '');
          Subagents[i].MaxIter      := Item.GetInt('max_iterations', 0);
          ToolsArr := Item.ChildArray('tools');
          if ToolsArr <> nil then
          try
            SetLength(Subagents[i].Tools, ToolsArr.Count);
            for j := 0 to ToolsArr.Count - 1 do
              Subagents[i].Tools[j] := ToolsArr.ItemStr(j);
          finally
            ToolsArr.Free;
          end;
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
  finally
    Root.Free;
  end;
end;

function GetHome: string;
var
  H: string;
begin
  H := GetEnvironmentVariable(EnvHome);
  if H <> '' then Exit(H);
  Result := JoinPath(HomeDir, '.pasclaw');
end;

function GetConfigPath: string;
var
  Override_: string;
begin
  Override_ := GetEnvironmentVariable(EnvConfig);
  if Override_ <> '' then Exit(Override_);
  Result := JoinPath(GetHome, 'config.json');
end;

function LoadConfig: TConfig;
var
  Path, S: string;
begin
  Result := TConfig.Create;
  Path := GetConfigPath;
  try
    if FileExists(Path) then
    begin
      S := ReadFileText(Path);
      try
        Result.FromJSON(S);
      except
        on E: Exception do
          { Bad config: keep defaults rather than aborting CLI startup. }
          ;
      end;
    end;
  finally
    { Propagate the promptware off-switch here -- LoadConfig is the
      one choke every entry point (CLI, TUI, gateway, serve, tool
      handlers re-loading mid-session) passes through, so the scan
      module's process-global flag can't drift from config.json.
      PasClaw.Promptware is a leaf unit (SysUtils + Logger only);
      keep it that way or this import becomes a cycle. }
    SetPromptwareEnabled(Result.PromptwareEnabled);
  end;
end;

procedure SaveConfig(C: TConfig);
begin
  WriteFileText(GetConfigPath, C.ToJSON);
end;

function FormatVersion: string;
begin
  if VersionRaw = '' then Result := VersionFallback else Result := VersionRaw;
end;

function FormatBuildInfo: string;
{$IFDEF FPC}
const
  FpcVer   = {$I %FPCVERSION%};
  FpcOS    = {$I %FPCTARGETOS%};
  FpcCPU   = {$I %FPCTARGETCPU%};
begin
  Result := Format('pasclaw %s (fpc %s %s/%s)', [FormatVersion, FpcVer, FpcOS, FpcCPU]);
end;
{$ELSE}
begin
  Result := Format('pasclaw %s (delphi)', [FormatVersion]);
end;
{$ENDIF}

end.
