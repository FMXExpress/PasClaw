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
  PasClaw.Stream.Reliability,
  PasClaw.Shell.Backend;   { TShellBackendKind -- typed enum the
                             ShellBackend field uses. Defining it
                             in the leaf shell unit means
                             PasClaw.Shell.Backend.* impls don't
                             have to use-back into PasClaw.Config. }

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
    { Inbound bearer token gating /v1/* routes. Empty (the default)
      means unauthenticated -- every request reaches its route
      handler with no check. When non-empty, OnCommandGet's auth
      middleware requires `Authorization: Bearer <token>` (or the
      query parameter `?token=<token>`) on every non-exempt route
      and returns 401 otherwise. Exempt routes: `/` (web UI HTML),
      `/v1/health`, `/v1/version`, and every `/webhooks/*` path
      (those carry their own per-channel signature secret).
      Env var $PASCLAW_GATEWAY_TOKEN overrides this at LoadConfig
      time, same precedence shape `OTEL_EXPORTER_OTLP_ENDPOINT`
      uses. Comparisons are constant-time. }
    Token:    string;
  end;

  (*  TOtelHeader -- one header pair for OTLP exports. The
      OpenTelemetry collector spec uses these for auth (Authorization:
      Bearer ..., x-honeycomb-team, etc). Mirrors openclaw's
      diagnostics.otel.headers shape so a config block copy-pastes. *)
  TOtelHeader = record
    Name:  string;
    Value: string;
  end;

  (*  TOtelDiagnosticsConfig -- OTLP/HTTP traces exporter. Off by
      default; turn on by setting diagnostics.otel.enabled=true and
      a valid endpoint, OR by setting OTEL_EXPORTER_OTLP_ENDPOINT in
      the environment (the standard OTel SDK contract -- the env var
      flips Enabled=true on its own).

      Endpoint
        Collector URL. http://localhost:4318 is the OTel Collector
        default. We append /v1/traces when the path is missing.

      Protocol
        Always "http/json" in this release. Reserved for "http/protobuf"
        once we ship a protobuf encoder.

      ServiceName
        resource.service.name attribute on every span. Defaults to
        "pasclaw" -- override per-deployment to distinguish CLI
        sessions from gateway deployments.

      SampleRate
        Bernoulli sampling on trace start, 0.0..1.0. 1.0 = trace
        every turn, 0.0 = trace nothing (effectively off), 0.1 =
        trace ~10%. Sampling is decided at the root span (agent.turn
        or http.server.request); children inherit the parent's
        decision. Default 1.0.

      Headers
        Extra HTTP headers on every OTLP POST. Typically Authorization,
        x-honeycomb-team, etc. The OTEL_EXPORTER_OTLP_HEADERS env var
        ("k1=v1,k2=v2") overrides this when set.

      Traces / Metrics / Logs
        Reserved booleans. Only Traces is wired in this release;
        Metrics and Logs are a follow-up PR. Defaults: traces=true,
        metrics=false, logs=false. *)
  TOtelDiagnosticsConfig = record
    Enabled:     Boolean;
    Endpoint:    string;
    Protocol:    string;
    ServiceName: string;
    SampleRate:  Double;
    Headers:     array of TOtelHeader;
    Traces:      Boolean;
    Metrics:     Boolean;
    Logs:        Boolean;
  end;

  TDiagnosticsConfig = record
    Otel: TOtelDiagnosticsConfig;
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

  THeartbeatConfig = record
    Enabled:       Boolean;
    IntervalMins:  Integer;   { default 30; minimum enforced at runtime to 1 }
    ContentPath:   string;    { default '<home>/workspace/heartbeat.md'; relative
                                paths anchor on $PASCLAW_HOME }
    Channel:       string;    { Named channel from Cfg.Channels to post the result
                                to. Empty = log-only. Matches send_message
                                semantics: operator pre-declares the target so a
                                prompt-injected heartbeat body can't exfiltrate. }
  end;

  (* Shell-backend Docker options. Picks the image / network /
     privileged mode the Docker IShellBackend impl uses. Default
     image is small and universally available; operators can swap
     for pasclaw/runner: once we publish a curated one, or any
     image with the tooling they want preinstalled. *)
  TShellBackendDockerConfig = record
    Image:       string;    { default 'debian:bookworm-slim' }
    Network:     string;    { 'bridge' (default) | 'host' | 'none' }
    User:        string;    { '' = container default }
    Privileged:  Boolean;
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

  (* TSkillDistillerConfig -- the post-turn "should this become a
     reusable skill?" pass (Hermes-style autonomous skill creation).
     After a qualifying turn the agent hands the tool trace to a small
     LLM call which either emits a draft SKILL.md or declines. The
     draft is staged (or auto-committed; see TSelfImprovingSkillsConfig)
     -- it does NOT take effect mid-session: like a hub install, the
     next agent start re-scans workspace/skills and picks it up.
       Enabled:       master switch, default False.
       MinToolCalls:  only consider turns that dispatched at least this
                      many tool calls (proxy for "non-trivial workflow
                      worth capturing"). Default 5, matching Hermes.
       Model:         optional model override for the distiller call;
                      empty = use the turn's own model. Point this at a
                      cheap model (Haiku) to keep the tax low. *)
  TSkillDistillerConfig = record
    Enabled:      Boolean;
    MinToolCalls: Integer;
    Model:        string;
  end;

  (* TSelfImprovingSkillsConfig -- agent-authored skills (Hermes
     "self-improving skills" port). Three independent, all-opt-in
     capabilities plus a shared safety guard:

       SelfManage           registers the `skill_manage` tool so the
                            model can create / edit / patch / remove
                            skills on disk during a turn. Default False.
       ProgressiveDisclosure registers `skills_list` / `skill_view` and
                            switches the system prompt's SKILLS section
                            from "inline every skill" to a short
                            "list/view on demand" blurb -- keeps the
                            prompt small once a deployment accrues many
                            skills. Default False (today's full-catalog
                            behaviour preserved).
       AutoApprove          when True, skill_manage / the distiller write
                            straight to workspace/skills/<name>/; when
                            False (default) writes stage under
                            workspace/skills/.pending/<id>/ awaiting
                            `pasclaw skills approve <id>` (or the gateway
                            / web UI approve action). The operator is the
                            quality judge -- there is no automated utility
                            evaluator.
       GuardDeny            extra case-insensitive substrings appended to
                            the built-in dangerous-pattern denylist that
                            rejects a model-authored `shell:` skill body
                            before it is staged (rm -rf, curl|sh, etc).
       Distiller            see TSkillDistillerConfig. *)
  TSelfImprovingSkillsConfig = record
    SelfManage:            Boolean;
    ProgressiveDisclosure: Boolean;
    AutoApprove:           Boolean;
    GuardDeny:             array of string;
    Distiller:             TSkillDistillerConfig;
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
    Diagnostics: TDiagnosticsConfig;  { OpenTelemetry traces -- see TOtelDiagnosticsConfig }
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
    (* On-by-default since PR #289: when True, Cmd.Agent.NewBuiltinRegistry
       registers vault_search and vault_get for the model -- read-only
       HTTP GETs against the curated pasclaw.dev registry, no execution
       path. The onboarding flow asks (default Y). Operators who don't
       want any HTTP from this surface can flip it off in config.json. *)
    VaultToolsEnabled: Boolean;
    (* On-by-default since PR #289: register the web_fetch tool in
       Cmd.Agent / Cmd.Gateway / Cmd.Serve. Picoclaw historically
       leaves it off (its model uses shell + curl), but PasClaw runs
       fine in sandboxed containers where curl isn't available, so
       the default is now on. Onboarding asks (default Y); operators
       who don't want outbound HTTP from the agent flip it off. *)
    WebFetchEnabled:   Boolean;
    (* OFF by default: when True, the model gets a `cron` tool that can
       list/add/remove scheduled jobs by editing config.json's crons[].
       Bounded by design -- a cron entry only runs an EXISTING operator-
       installed skill on a schedule, so the model can schedule but not
       author the work. Off by default because letting the model schedule
       background execution is an autonomy step operators should opt into;
       flip cron_tool_enabled=true in config.json. The running scheduler
       picks up the model's edits within one tick (config mtime watch). *)
    CronToolEnabled:   Boolean;
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
    (* Off-by-default since PR #289: reversible condensation (CCR,
       headroom-inspired). When True, a condenser (JSON, shell
       filters) that actually shrinks tool output stashes the
       ORIGINAL under a fresh OutputCache handle and appends a footer
       naming it -- the model gets the structural view by default and
       can call tool_output_get when the shape isn't enough.
       tool_output_get registers whenever this is on OR
       Cfg.ToolOutputCap > 0. Flipped to off-by-default because
       silently rewriting `ls -l`/`grep` output into a structural
       view surprised operators on fresh deploys (PR #289). Onboarding
       asks (default N). *)
    CondenseReversible:    Boolean;
    (* HashlineEnabled gates fs_edit_hashline ONLY (PR #314: split the
       previous bundled gate -- fs_grep now registers unconditionally
       because its ripgrep-inspired optimisations beat shell_exec grep
       on real codebases and on Windows it's the only grep available).
       The flag also controls fs_read's default output format
       (hashline-prefixed vs raw bytes).

       Default True everywhere. The bench (bench/swe/README.md) found
       that smaller models (Haiku-class) mis-author the hashline
       anchor/payload format and burn turns recovering; operators on
       small-model deployments opt out via onboarding's PromptHashline
       (default N skips it) or the --no-hashline CLI flag. Both gate
       layers compose: CLI flag OR config off = drop the
       fs_edit_hashline registration. *)
    HashlineEnabled:       Boolean;
    (* Proactive periodic wake-up (picoclaw / openclaw heartbeat).
       Off by default. When Enabled, the standalone `pasclaw
       heartbeat` daemon (and the gateway / serve embedders, when
       they're set up to host it) reads workspace/heartbeat.md every
       IntervalMins minutes, runs RunToolLoop on its body, and
       optionally posts the result to a named channel. Empty file or
       missing file = skip the tick (no spurious model call). *)
    Heartbeat:             THeartbeatConfig;
    (* Shell backend (PasClaw.Shell.Backend). sbLocal = today's
       behaviour (commands in the host process); sbDocker spawns a
       per-session container and `docker exec`s into it for
       shell_exec / execute_code. Onboarding picks the default;
       commands can override per-run with --backend. Phase 2 adds
       sbSSH; this enum is a forward declaration from
       PasClaw.Shell.Backend so the same identifier flows
       everywhere. *)
    ShellBackend:          TShellBackendKind;
    ShellBackendDocker:    TShellBackendDockerConfig;
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
    (* Agent-authored / self-improving skills. All sub-switches
       default off -- see TSelfImprovingSkillsConfig. *)
    SelfImprovingSkills:  TSelfImprovingSkillsConfig;
    (* Persisted profile selection (PR #291). Written by
       `pasclaw profile use <name>`, read by LoadConfig as the third-
       level fallback selector (after --profile and PASCLAW_PROFILE).
       Round-trips through FromJSON / ToJSON so SaveConfig from any
       config-mutating command (auth login, model set, /v1/config PUT,
       ...) preserves the operator's choice instead of dropping it on
       the next read -- Codex P2 on the original PR. Empty = no
       persisted profile. *)
    Profile:              string;
    constructor Create;
    function  ToJSON: string;
    procedure FromJSON(const S: string);
  end;

function GetHome: string;
function GetConfigPath: string;
function LoadConfig: TConfig; overload;

(* Profile-aware overload (PR #291). When ProfileOverride is non-empty,
   apply the named profile (and its _inherits ancestors) BEFORE the
   operator's config.json. Empty string -> selection precedence:
     1. PASCLAW_PROFILE env var
     2. "profile" field inside config.json
     3. None -- behave exactly like LoadConfig() does today.
   Profile fields layer on top of TConfig.Create defaults; the
   operator's config.json fields layer on top of the profile so
   explicit config-json choices always win. See PasClaw.Config.Profile
   for the catalogue and inheritance semantics. *)
function LoadConfig(const ProfileOverride: string): TConfig; overload;
procedure SaveConfig(C: TConfig);

const
  { Placeholder the gateway's read-only /v1/config substitutes for any
    populated secret (providers[].api_key, mcp_servers[].env,
    gateway.token) so the web UI can show "set vs unset" without leaking
    the value. A write that sends this placeholder back means "keep the
    existing secret"; any other value sets a new one. Shared so the mask
    (GET) and the unmask-merge (PUT) can never drift. }
  MaskedSecretPlaceholder = '•••';

(* Merge an edited config body (as the web UI's Settings editor PUTs it,
   with secrets still showing MaskedSecretPlaceholder) onto the current
   on-disk config, restoring any masked secret from CurrentJSON so the
   client can SET secrets without ever VIEWING them: a field left at the
   placeholder keeps the server's value; any other value overwrites it.
   Restores providers[].api_key + mcp_servers[].env (matched by name) and
   gateway.token. Returns the merged JSON; raises on unparseable input.
   Exposed for tests. *)
function RestoreMaskedConfigSecrets(const EditedJSON, CurrentJSON: string): string;

(*  Effective gateway bearer token. Returns the env-var override
    when $PASCLAW_GATEWAY_TOKEN or $OPENCLAW_GATEWAY_TOKEN is set
    (PASCLAW_ wins when both are set), else C.Gateway.Token from
    the parsed config file. Distinct from C.Gateway.Token so that
    env-only secrets don't leak into the persisted config via the
    SaveConfig -> ToJSON round-trip a config-mutating command
    (auth, model, skills install, ...) would otherwise force on
    every restart. Codex P2 on PR #246.

    OPENCLAW_GATEWAY_TOKEN is honoured as an alias so an
    operator's existing openclaw .env file ports verbatim --
    openclaw uses that name; PasClaw's own convention is the
    PASCLAW_ prefix, but accepting both costs nothing.

    The gateway middleware uses this getter; ToJSON / SaveConfig
    serialise only C.Gateway.Token (never the env value). *)
function GetEffectiveGatewayToken(const C: TConfig): string;

(*  DescribeGatewayAuthState -- one-line summary of the gateway's
    bearer-token auth state, intended for a single LogInfo at
    gateway startup. Helps operators diagnose the typical
    misconfigurations from the deploy logs without a console
    exec into the container.

    Possible outputs (always exactly one line, no token value):

      gateway: bearer-token auth ENABLED (source=env, token len=64, prefix=ab12...)
      gateway: bearer-token auth ENABLED (source=config.json, token len=64, prefix=ab12...)
      gateway: bearer-token auth MISCONFIGURED -- token field is unresolved template '${PASCLAW_GATEWAY_TOKEN}'; env var not set, so no client token will match
      gateway: bearer-token auth DISABLED -- no token configured (every /v1/* and /mcp route open to any caller)

    The MISCONFIGURED case is the typo trap: an operator sets
    PASCAL_GATEWAY_TOKEN (no W) in the platform's env-var UI,
    ExpandEnvVarsInJSON sees no PASCLAW_GATEWAY_TOKEN to substitute,
    the literal `${PASCLAW_GATEWAY_TOKEN}` survives into
    Cfg.Gateway.Token, GetEffectiveGatewayToken returns it, and
    every bearer the web UI sends gets compared against the literal
    template string -- guaranteed mismatch, infinite 401 loop.
    This log line surfaces that case immediately at startup.

    The prefix is the first 4 chars of the token + `...` -- enough
    for the operator to visually match against the token they pasted
    into their secret manager, not enough to enable a brute force
    against the remaining bytes (16 bits of guessing for a hex
    token, and the token is presumed long). Suppressed for tokens
    shorter than 8 chars (we log `prefix=<short>` instead -- a 4-byte
    prefix of a 6-byte token leaks too much). *)
function DescribeGatewayAuthState(const C: TConfig): string;

(*  ExpandEnvVarsInJSON -- raw-text ${VAR_NAME} substitution applied
    to the JSON config body BEFORE TConfig.FromJSON parses it.
    Matches openclaw's `${...}` template-substitution feature so an
    operator can keep secrets out of `config.json` without using
    the dedicated `PASCLAW_GATEWAY_TOKEN` env var:

      "providers": [
        { "name": "anthropic", "api_key": "${ANTHROPIC_API_KEY}" }
      ]

    Pattern: `${[A-Z_][A-Z0-9_]*}` (uppercase only, matching openclaw).
    On a match we GetEnvironmentVariable the name and splice the value
    in -- JSON-escaping any `"`, `\`, or control byte so the result
    stays valid JSON regardless of the env value's contents. When the
    env var is unset (or set but empty), the literal `${VAR_NAME}` is
    left in place so an operator reading config back can diagnose by
    seeing the unresolved marker. No escape sequence for a literal
    `${UPPER}` value in v1; the workaround is downcasing one letter
    so the pattern doesn't match, or use the dedicated PASCLAW_* env
    var path that doesn't go through string substitution at all.

    Applied at LoadConfig only -- embedders constructing TConfig from
    a hand-crafted JSON string and calling FromJSON directly do their
    own env wiring. Exposed in the interface so the test can pin
    the expansion contract without driving LoadConfig itself. *)
function ExpandEnvVarsInJSON(const Body: string): string;

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
  StrUtils,                   { IndexStr -- shell_backend enum parsing }
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Config.Profile,     { ResolveProfileBodies / ExtractProfileField -- PR #291 }
  PasClaw.Logger,             { LogWarn / LogInfo on the profile-apply path }
  PasClaw.Promptware,         { LoadConfig propagates promptware_enabled --
                                see the comment inside LoadConfig }
  PasClaw.Tools.OutputCache,  { LoadConfig propagates condense_reversible
                                via SetCondenseReversible -- same pattern }
  PasClaw.Otel;               { LoadConfig calls InitOtelFromConfig so
                                env-var overrides (OTEL_EXPORTER_OTLP_ENDPOINT)
                                + the diagnostics.otel.* block in config.json
                                both take effect at the same single chokepoint
                                every entry point already passes through. }

var
  { Env-var-sourced gateway bearer token, kept SEPARATE from
    TConfig.Gateway.Token so a config-mutating command (auth,
    model, skills install, ...) doing LoadConfig -> SaveConfig
    can't accidentally persist a deployment secret into
    config.json. Set by LoadConfig at startup (from
    $PASCLAW_GATEWAY_TOKEN, or $OPENCLAW_GATEWAY_TOKEN for
    openclaw-compat); read by GetEffectiveGatewayToken which is
    what the middleware actually checks against. Empty when
    neither env var is set -- the middleware then falls back to
    C.Gateway.Token. }
  GEnvGatewayToken: string = '';

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
  Gateway.Token    := '';
  { OpenTelemetry diagnostics defaults: off, but pre-populated with
    the OTel Collector localhost address so flipping enabled=true is
    a one-key change. Sampling at 1.0 (trace every turn) is the right
    default for the small-scale deployments PasClaw targets; turn
    down for high-volume gateways. }
  Diagnostics.Otel.Enabled     := False;
  Diagnostics.Otel.Endpoint    := 'http://localhost:4318';
  Diagnostics.Otel.Protocol    := 'http/json';
  Diagnostics.Otel.ServiceName := 'pasclaw';
  Diagnostics.Otel.SampleRate  := 1.0;
  Diagnostics.Otel.Traces      := True;
  Diagnostics.Otel.Metrics     := False;
  Diagnostics.Otel.Logs        := False;
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
  PromptCache.TTL      := '1h';  { 1h cache hits well across back-to-back runs (bench/swe/results/ablation.md). 5m was the historical default; 1h is one of the six zero-prompt-cost behavioral toggles the bench identified as a free upgrade. }
  VaultToolsEnabled    := False; { off by default per the bench-grounded "stock = lean-edit shape" verdict (bench/swe/README.md). Vault entries are never called across the bench's 45+ cells -- the model has them as training data. Onboarding asks (default Y for operators who DO use the vault). }
  WebFetchEnabled      := False; { off by default for the same reason as VaultToolsEnabled. Also drops memory_fetch (RegisterMemoryFetchTool is gated on EnableWebFetch in NewBuiltinRegistry -- see comment there). Onboarding asks. }
  CronToolEnabled      := False; { off by default -- model-scheduled background jobs are an opt-in autonomy step (runs existing skills only). }
  RenderMarkdown       := True;  { on by default for terminal surfaces; cmd/serve flips off }
  ToolOutputCap        := 0;     { off by default; operators opt in. See TConfig.ToolOutputCap. }
  StatsCollectionEnabled := True;  { on by default -- zero prompt cost, useful for diagnosing turn-count regressions. Onboarding can flip off for privacy-conscious operators. }
  CheckpointsEnabled     := True;  { on by default -- zero prompt cost, prevents lost work on multi-edit sessions. }
  CheckpointsKeepLast    := 32;    { keep last 32 atomic edit checkpoints. }
  PromptwareEnabled      := True;  { on by default -- substring scan, effectively free. }
  OrientTaskAware        := True;  { on by default -- MEMORY task-aware injection. Zero prompt cost when MEMORY.md is absent; saves tokens when present. }
  CondenseReversible     := False; { off by default -- raw tool output preserved verbatim. Onboarding asks (default N). Flipped from on-by-default in PR #289 so a fresh deploy doesn't silently rewrite ls/grep output behind the operator's back. }
  { HashlineEnabled gates fs_edit_hashline ONLY (PR #314 split the
    previous bundled gate -- fs_grep registers unconditionally).

    Default True everywhere. The bench (bench/swe/README.md) found
    that smaller models (Haiku-class) mis-author fs_edit_hashline's
    anchor/payload format and burn turns recovering; those operators
    opt out via onboarding's PromptHashline (default Y) or the
    --no-hashline CLI flag. Big-model operators (Opus / Sonnet /
    GPT-4) use the tool correctly, and they're the majority case
    pasclaw is tuned for. CLI flag OR config off = drop the
    fs_edit_hashline registration. }
  HashlineEnabled        := True;
  Heartbeat.Enabled      := False; { opt-in via onboarding; off by default. }
  Heartbeat.IntervalMins := 30;
  Heartbeat.ContentPath  := '';    { empty -> default workspace/heartbeat.md at load time }
  Heartbeat.Channel      := '';
  ShellBackend           := sbLocal;
  ShellBackendDocker.Image      := 'debian:bookworm-slim';
  ShellBackendDocker.Network    := 'bridge';
  ShellBackendDocker.User       := '';
  ShellBackendDocker.Privileged := False;
  SetLength(Channels, 0);          { no channels -> send_message tool not registered. }
  AutoRouter.Enabled        := True;   { on by default -- routes easy turns to the cheap model when EasyProvider/Model are configured. Zero prompt cost; no effect unless multi-tier provider config is set. }
  AutoRouter.EasyProvider   := '';
  AutoRouter.EasyModel      := '';
  AutoRouter.EasyMaxTokens  := 500;
  { Self-improving skills: distiller on by default (zero prompt cost,
    post-turn pass produces staged drafts under workspace/skills/.pending/).
    The three other switches (self_manage / progressive_disclosure /
    auto_approve) remain opt-in -- each adds tool registrations or
    skips operator review. See TSelfImprovingSkillsConfig. }
  SelfImprovingSkills.SelfManage            := False;
  SelfImprovingSkills.ProgressiveDisclosure := False;
  SelfImprovingSkills.AutoApprove           := False;
  SetLength(SelfImprovingSkills.GuardDeny, 0);
  SelfImprovingSkills.Distiller.Enabled      := True;
  SelfImprovingSkills.Distiller.MinToolCalls := 5;
  SelfImprovingSkills.Distiller.Model        := '';
  Profile := '';   { PR #291: empty == no persisted profile selection }
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
  Root, Gw, Tmp, Tmp2, Diag, OtelHdrs: TJsonObject;
  Arr, FallbacksArr: TJsonArray;
  i: Integer;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('default_provider', DefaultProvider);
    Root.PutStr('default_model',    DefaultModel);
    { PR #291: persisted profile selection. Emit only when non-empty
      so a no-profile install stays tidy. SaveConfig from any
      config-mutating command preserves this verbatim. }
    if Profile <> '' then
      Root.PutStr('profile', Profile);
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
    if Gateway.Token <> '' then Gw.PutStr('token', Gateway.Token);
    Root.PutObject('gateway', Gw);

    (* diagnostics.otel round-trip. Without this block, ANY command
       that calls SaveConfig after a LoadConfig (auth, model, mcp,
       skill updates) would rewrite config.json through ToJSON and
       silently drop the whole diagnostics tree. The user re-runs
       the agent expecting traces and gets nothing, with no error to
       tell them why. The shape mirrors the FromJSON parse block
       below 1-for-1 (same keys, same types, same headers nested
       object). Symmetric with the gateway / sandbox blocks above:
       always emitted, even at defaults, so a `pasclaw config show`
       round-trip is stable. *)
    Tmp := TJsonObject.Create;
    Tmp.PutBool ('enabled',     Diagnostics.Otel.Enabled);
    Tmp.PutStr  ('endpoint',    Diagnostics.Otel.Endpoint);
    Tmp.PutStr  ('protocol',    Diagnostics.Otel.Protocol);
    Tmp.PutStr  ('serviceName', Diagnostics.Otel.ServiceName);
    Tmp.PutFloat('sampleRate',  Diagnostics.Otel.SampleRate);
    Tmp.PutBool ('traces',      Diagnostics.Otel.Traces);
    Tmp.PutBool ('metrics',     Diagnostics.Otel.Metrics);
    Tmp.PutBool ('logs',        Diagnostics.Otel.Logs);
    if Length(Diagnostics.Otel.Headers) > 0 then
    begin
      OtelHdrs := TJsonObject.Create;
      for i := 0 to High(Diagnostics.Otel.Headers) do
        OtelHdrs.PutStr(Diagnostics.Otel.Headers[i].Name,
                        Diagnostics.Otel.Headers[i].Value);
      Tmp.PutObject('headers', OtelHdrs);
    end;
    Diag := TJsonObject.Create;
    Diag.PutObject('otel', Tmp);
    Root.PutObject('diagnostics', Diag);

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
      tidy. Default flipped to 1h in PR #314 (bench/swe/README.md): an
      operator setting TTL back to "5m" or any other non-default needs
      the value to round-trip; same for the explicit-off path. Reading
      back: missing object => defaults (enabled, 1h). }
    if (not PromptCache.Enabled) or ((PromptCache.TTL <> '') and (PromptCache.TTL <> '1h')) then
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

    { vault_tools_enabled, web_fetch_enabled: defaults flipped to OFF
      in PR #314 (bench/swe/README.md). Emit only the explicit-on so a
      fresh config stays tidy AND so an operator who answered Y to the
      onboarding prompt sees the choice round-trip (without this, the
      Y would silently revert to N on the next LoadConfig). }
    if VaultToolsEnabled then
      Root.PutBool('vault_tools_enabled', True);
    if WebFetchEnabled then
      Root.PutBool('web_fetch_enabled', True);
    { cron_tool_enabled defaults OFF; emit only the explicit-on so an
      operator who opted into model-scheduled jobs round-trips. }
    if CronToolEnabled then
      Root.PutBool('cron_tool_enabled', True);
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
    { stats_collection_enabled, checkpoints_enabled, orient_task_aware:
      defaults flipped to ON in PR #314 (the six free behavioral toggles
      from the bench's ablation). Emit only the explicit-off so an
      operator answering N to onboarding (or editing the field by hand)
      sees the choice round-trip. Without this, an opt-out silently
      reverts to the on-by-default behavior on the next load -- privacy
      / storage / behavior opt-outs do not stick. }
    if not StatsCollectionEnabled then
      Root.PutBool('stats_collection_enabled', False);
    if not CheckpointsEnabled then
      Root.PutBool('checkpoints_enabled', False);
    { CheckpointsKeepLast default flipped from 0 (=> use library
      default 32) to an explicit 32 in PR #314. Emit when it differs --
      0 and other values both round-trip. }
    if CheckpointsKeepLast <> 32 then
      Root.PutInt('checkpoints_keep_last', CheckpointsKeepLast);
    { Default True -- emit only the explicit-off so it round-trips
      (same rule as render_markdown / vector_search_enabled). }
    if not PromptwareEnabled then
      Root.PutBool('promptware_enabled', False);
    if not OrientTaskAware then
      Root.PutBool('orient_task_aware', False);
    { condense_reversible: default flipped to OFF in PR #289. Emit
      only the explicit-on so fresh configs stay tidy. }
    if CondenseReversible then
      Root.PutBool('condense_reversible', True);
    { hashline_enabled: default True. Emit only the explicit OFF so
      small-model operators who answer N to PromptHashline (or who
      set the field via config edit) see their choice round-trip;
      Y-keepers don't get a redundant "hashline_enabled": true in
      their config.json. CLI --no-hashline still works as a per-run
      override. }
    if not HashlineEnabled then
      Root.PutBool('hashline_enabled', False);
    if Heartbeat.Enabled
       or (Heartbeat.IntervalMins <> 30)
       or (Heartbeat.ContentPath <> '')
       or (Heartbeat.Channel <> '') then
    begin
      Tmp := TJsonObject.Create;
      try
        Tmp.PutBool('enabled',       Heartbeat.Enabled);
        Tmp.PutInt ('interval_mins', Heartbeat.IntervalMins);
        if Heartbeat.ContentPath <> '' then
          Tmp.PutStr('content_path', Heartbeat.ContentPath);
        if Heartbeat.Channel <> '' then
          Tmp.PutStr('channel', Heartbeat.Channel);
        Root.PutObject('heartbeat', Tmp);
      except
        Tmp.Free; raise;
      end;
    end;
    { shell_backend always round-trips. Emit the kind string and,
      when docker is selected, the docker subobject too -- writing
      it out always (even on local) would clutter every stock
      config; only emit when the operator picked docker OR diverged
      from defaults. }
    if ShellBackend = sbDocker then
      Root.PutStr('shell_backend', 'docker')
    else if ShellBackend = sbLocal then
      { Default; skip emission unless someone touched the docker
        subobject -- in which case we still emit "local" to keep
        the file self-explanatory about which backend is active. }
      if (ShellBackendDocker.Image <> 'debian:bookworm-slim')
         or (ShellBackendDocker.Network <> 'bridge')
         or (ShellBackendDocker.User <> '')
         or ShellBackendDocker.Privileged then
        Root.PutStr('shell_backend', 'local');
    if (ShellBackend = sbDocker)
       or (ShellBackendDocker.Image <> 'debian:bookworm-slim')
       or (ShellBackendDocker.Network <> 'bridge')
       or (ShellBackendDocker.User <> '')
       or ShellBackendDocker.Privileged then
    begin
      Tmp := TJsonObject.Create;
      try
        Tmp.PutStr('image',      ShellBackendDocker.Image);
        Tmp.PutStr('network',    ShellBackendDocker.Network);
        if ShellBackendDocker.User <> '' then Tmp.PutStr('user', ShellBackendDocker.User);
        if ShellBackendDocker.Privileged then Tmp.PutBool('privileged', True);
        Root.PutObject('shell_backend_docker', Tmp);
      except
        Tmp.Free; raise;
      end;
    end;
    { auto_router.enabled default flipped to ON in PR #314. Always
      emit the subobject -- True default plus the previous "emit when
      Enabled" gate means an opt-out (Enabled := False with no other
      changes) would skip emission and the next LoadConfig would
      silently re-enable. Emitting unconditionally keeps the round-trip
      honest at the cost of one always-present subobject in fresh
      configs (cheap given it has four fields). }
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
    { Self-improving skills -- emit when ANYTHING differs from the new
      defaults so the round-trip is honest. Distiller.Enabled default
      flipped to True in PR #314, so the gate ALSO has to fire on the
      explicit-off path (without `not Distiller.Enabled` here, an
      onboarding-skip + manual distiller=false flip would silently
      revert to on). SelfManage / ProgressiveDisclosure / AutoApprove
      defaults stay False -- gate emits when any is True. }
    if SelfImprovingSkills.SelfManage
       or SelfImprovingSkills.ProgressiveDisclosure
       or SelfImprovingSkills.AutoApprove
       or (not SelfImprovingSkills.Distiller.Enabled)
       or (Length(SelfImprovingSkills.GuardDeny) > 0)
       or (SelfImprovingSkills.Distiller.MinToolCalls <> 5)
       or (SelfImprovingSkills.Distiller.Model <> '') then
    begin
      Tmp := TJsonObject.Create;
      try
        Tmp.PutBool('self_manage',            SelfImprovingSkills.SelfManage);
        Tmp.PutBool('progressive_disclosure', SelfImprovingSkills.ProgressiveDisclosure);
        Tmp.PutBool('auto_approve',           SelfImprovingSkills.AutoApprove);
        Arr := TJsonArray.Create;
        for i := 0 to High(SelfImprovingSkills.GuardDeny) do
          Arr.AddStr(SelfImprovingSkills.GuardDeny[i]);
        Tmp.PutArray('guard_deny', Arr);
        Tmp2 := TJsonObject.Create;
        try
          Tmp2.PutBool('enabled',        SelfImprovingSkills.Distiller.Enabled);
          Tmp2.PutInt ('min_tool_calls', SelfImprovingSkills.Distiller.MinToolCalls);
          Tmp2.PutStr ('model',          SelfImprovingSkills.Distiller.Model);
          Tmp.PutObject('distiller', Tmp2);
        except
          Tmp2.Free; raise;
        end;
        Root.PutObject('self_improving_skills', Tmp);
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
  Root, Obj, Item, Sub, SubHdrs: TJsonObject;
  Arr, ToolsArr: TJsonArray;
  HdrKeys: TStringList;
  i, j: Integer;
begin
  if Trim(S) = '' then Exit;
  Root := TJsonObject.Parse(S);
  if Root = nil then Exit;
  try
    DefaultProvider := Root.GetStr('default_provider', DefaultProvider);
    DefaultModel    := Root.GetStr('default_model',    DefaultModel);
    Profile         := Root.GetStr('profile',          Profile);   { PR #291 }
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
      Gateway.Token    := Obj.GetStr('token',     Gateway.Token);
    finally
      Obj.Free;
    end;

    { diagnostics.otel.* -- mirrors openclaw v2026.2+ keys so a
      config block ports cleanly. The env vars
      OTEL_EXPORTER_OTLP_ENDPOINT / OTEL_EXPORTER_OTLP_HEADERS take
      effect later in PasClaw.Otel.InitOtelFromConfig; we don't
      mutate the parsed values here so the round-trip toString stays
      faithful to what's in config.json. }
    Obj := Root.ChildObject('diagnostics');
    if Obj <> nil then
    try
      Sub := Obj.ChildObject('otel');
      if Sub <> nil then
      try
        Diagnostics.Otel.Enabled     := Sub.GetBool('enabled',     Diagnostics.Otel.Enabled);
        Diagnostics.Otel.Endpoint    := Sub.GetStr ('endpoint',    Diagnostics.Otel.Endpoint);
        Diagnostics.Otel.Protocol    := Sub.GetStr ('protocol',    Diagnostics.Otel.Protocol);
        Diagnostics.Otel.ServiceName := Sub.GetStr ('serviceName', Diagnostics.Otel.ServiceName);
        Diagnostics.Otel.SampleRate  := Sub.GetFloat('sampleRate', Diagnostics.Otel.SampleRate);
        Diagnostics.Otel.Traces      := Sub.GetBool('traces',      Diagnostics.Otel.Traces);
        Diagnostics.Otel.Metrics     := Sub.GetBool('metrics',     Diagnostics.Otel.Metrics);
        Diagnostics.Otel.Logs        := Sub.GetBool('logs',        Diagnostics.Otel.Logs);
        SubHdrs := Sub.ChildObject('headers');
        if SubHdrs <> nil then
        try
          HdrKeys := SubHdrs.Keys;
          try
            SetLength(Diagnostics.Otel.Headers, HdrKeys.Count);
            for i := 0 to HdrKeys.Count - 1 do
            begin
              Diagnostics.Otel.Headers[i].Name  := HdrKeys[i];
              Diagnostics.Otel.Headers[i].Value := SubHdrs.GetStr(HdrKeys[i], '');
            end;
          finally
            HdrKeys.Free;
          end;
        finally
          SubHdrs.Free;
        end;
      finally
        Sub.Free;
      end;
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
    CronToolEnabled     := Root.GetBool('cron_tool_enabled',     CronToolEnabled);
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
    CondenseReversible  := Root.GetBool('condense_reversible', CondenseReversible);
    HashlineEnabled     := Root.GetBool('hashline_enabled',    HashlineEnabled);

    Obj := Root.ChildObject('heartbeat');
    if Obj <> nil then
    try
      Heartbeat.Enabled      := Obj.GetBool('enabled',       Heartbeat.Enabled);
      Heartbeat.IntervalMins := Integer(Obj.GetInt('interval_mins',
                                                    Heartbeat.IntervalMins));
      Heartbeat.ContentPath  := Obj.GetStr('content_path', Heartbeat.ContentPath);
      Heartbeat.Channel      := Obj.GetStr('channel',      Heartbeat.Channel);
    finally
      Obj.Free;
    end;

    { shell_backend: a single string at the top level. Unknown
      values fall back to local rather than failing -- a future
      "ssh" string written by a newer PasClaw shouldn't brick an
      older binary's startup. }
    case IndexStr(LowerCase(Trim(Root.GetStr('shell_backend', ''))),
                  ['', 'local', 'docker']) of
      0, 1: ShellBackend := sbLocal;
      2:    ShellBackend := sbDocker;
    else
      ShellBackend := sbLocal;
    end;

    Obj := Root.ChildObject('shell_backend_docker');
    if Obj <> nil then
    try
      ShellBackendDocker.Image      := Obj.GetStr('image',      ShellBackendDocker.Image);
      ShellBackendDocker.Network    := Obj.GetStr('network',    ShellBackendDocker.Network);
      ShellBackendDocker.User       := Obj.GetStr('user',       ShellBackendDocker.User);
      ShellBackendDocker.Privileged := Obj.GetBool('privileged', ShellBackendDocker.Privileged);
    finally
      Obj.Free;
    end;

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

    Obj := Root.ChildObject('self_improving_skills');
    if Obj <> nil then
    try
      SelfImprovingSkills.SelfManage :=
        Obj.GetBool('self_manage', SelfImprovingSkills.SelfManage);
      SelfImprovingSkills.ProgressiveDisclosure :=
        Obj.GetBool('progressive_disclosure', SelfImprovingSkills.ProgressiveDisclosure);
      SelfImprovingSkills.AutoApprove :=
        Obj.GetBool('auto_approve', SelfImprovingSkills.AutoApprove);
      Arr := Obj.ChildArray('guard_deny');
      if Arr <> nil then
      begin
        SetLength(SelfImprovingSkills.GuardDeny, Arr.Count);
        for i := 0 to Arr.Count - 1 do
          SelfImprovingSkills.GuardDeny[i] := Arr.ItemStr(i, '');
        Arr.Free;
      end;
      Sub := Obj.ChildObject('distiller');
      if Sub <> nil then
      try
        SelfImprovingSkills.Distiller.Enabled :=
          Sub.GetBool('enabled', SelfImprovingSkills.Distiller.Enabled);
        SelfImprovingSkills.Distiller.MinToolCalls :=
          Integer(Sub.GetInt('min_tool_calls', SelfImprovingSkills.Distiller.MinToolCalls));
        SelfImprovingSkills.Distiller.Model :=
          Sub.GetStr('model', SelfImprovingSkills.Distiller.Model);
      finally
        Sub.Free;
      end;
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
begin
  Result := LoadConfig('');
end;

function LoadConfig(const ProfileOverride: string): TConfig;
var
  Path, S, ProfileName, PErr, B: string;
  Bodies: TProfileBodyArray;
  i: Integer;
  HasConfigFile: Boolean;
begin
  Result := TConfig.Create;
  Path := GetConfigPath;
  S := '';
  HasConfigFile := FileExists(Path);
  try
    if HasConfigFile then
    begin
      S := ReadFileText(Path);
      (* Resolve ${VAR_NAME} markers BEFORE FromJSON parses. Lets
         operators keep API keys / bearer tokens / webhook URLs in
         the environment and reference them by name from config.json
         the same way openclaw's templates work. Unset env vars
         leave the literal marker in place so config-back-from-disk
         diagnostics still show which variable didn't resolve. *)
      S := ExpandEnvVarsInJSON(S);
    end;

    (* Profile resolution (PR #291). Selection precedence:
         1. ProfileOverride (CLI --profile)
         2. PASCLAW_PROFILE env var
         3. "profile" field in config.json (when one exists)
         4. None
       Lives OUTSIDE the FileExists guard so a fresh deploy that has
       no config.json yet still honours --profile / PASCLAW_PROFILE
       (Codex P2 on PR #291). When a profile name resolves, apply
       the ancestor chain + the profile body via TConfig.FromJSON
       BEFORE the operator's own config.json -- so explicit user
       fields win. FromJSON is merge-style (every GetX call defaults
       to the current TConfig value), so multiple applies layer
       cleanly. *)
    ProfileName := ProfileOverride;
    if ProfileName = '' then
      ProfileName := GetEnvironmentVariable('PASCLAW_PROFILE');
    if (ProfileName = '') and HasConfigFile then
      ProfileName := ExtractProfileField(S);
    if ProfileName <> '' then
    begin
      if ResolveProfileBodies(GetHome, ProfileName, Bodies, PErr) then
      begin
        for i := 0 to High(Bodies) do
        begin
          B := ExpandEnvVarsInJSON(Bodies[i]);
          try
            Result.FromJSON(B);
          except
            on E: Exception do
              LogWarn('config: profile "%s" layer %d apply failed: %s',
                      [ProfileName, i, E.Message]);
          end;
        end;
        LogInfo('config: profile "%s" applied (%d layer(s))',
                [ProfileName, Length(Bodies)]);
      end
      else
        LogWarn('config: %s -- using defaults + config.json only', [PErr]);
    end;

    if HasConfigFile then
    begin
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
    { Symmetric propagation of the reversible-condensation flag --
      OutputCache holds the same process-global mirror. }
    SetCondenseReversible(Result.CondenseReversible);
    { OpenTelemetry traces. No-op when diagnostics.otel.enabled is
      False AND the OTEL_EXPORTER_OTLP_ENDPOINT env var is unset --
      so single-shot CLI commands like `pasclaw status` pay nothing
      for the wiring. }
    InitOtelFromConfig(Result);
    { Gateway bearer-token env override. Populates the module-level
      GEnvGatewayToken; does NOT mutate Result.Gateway.Token, so
      SaveConfig -> ToJSON never persists an env-only secret into
      config.json. PASCLAW_GATEWAY_TOKEN is PasClaw's prefix; we
      also honour OPENCLAW_GATEWAY_TOKEN for openclaw-compat -- an
      operator pointing PasClaw at an existing openclaw .env file
      doesn't have to rename anything. PASCLAW_ wins when both
      env vars are set (we're not openclaw, after all). Codex P2
      on PR #246: persistence side of the fix. }
    if GetEnvironmentVariable('PASCLAW_GATEWAY_TOKEN') <> '' then
      GEnvGatewayToken := GetEnvironmentVariable('PASCLAW_GATEWAY_TOKEN')
    else if GetEnvironmentVariable('OPENCLAW_GATEWAY_TOKEN') <> '' then
      GEnvGatewayToken := GetEnvironmentVariable('OPENCLAW_GATEWAY_TOKEN')
    else
      GEnvGatewayToken := '';
  end;
end;

function GetEffectiveGatewayToken(const C: TConfig): string;
begin
  if GEnvGatewayToken <> '' then
    Result := GEnvGatewayToken
  else
    Result := C.Gateway.Token;
end;

function LooksLikeUnresolvedTemplate(const S: string): Boolean;
(* Heuristic: matches the literal `${...}` shape ExpandEnvVarsInJSON
   leaves behind when an env var referenced by config.json isn't set.
   No real bearer token would ever be generated in this shape (operators
   pull from `openssl rand -hex 32` / a password manager / DO's secret
   form), so the false-positive risk is zero in practice. *)
var
  n: Integer;
begin
  n := Length(S);
  Result := (n >= 4) and (S[1] = '$') and (S[2] = '{') and (S[n] = '}');
end;

function GatewayTokenPrefix(const Tok: string): string;
(* First 4 chars + `...` when long enough to keep the prefix from
   leaking too much of a short token. Pure display helper; never
   handed to the comparison path. *)
begin
  if Length(Tok) >= 8 then
    Result := Copy(Tok, 1, 4) + '...'
  else
    Result := '<short>';
end;

function DescribeGatewayAuthState(const C: TConfig): string;
var
  Tok, Source: string;
begin
  if GEnvGatewayToken <> '' then
  begin
    Tok    := GEnvGatewayToken;
    Source := 'env';
  end
  else if C.Gateway.Token <> '' then
  begin
    Tok    := C.Gateway.Token;
    Source := 'config.json';
  end
  else
  begin
    (* Mention both /v1/* (main API surface) and /mcp (the dedicated
       MCP companion listener at --mcp-port, plus the /v1/mcp/rpc
       in-main-port path) so operators understand the full exposure
       -- a token-less gateway leaves the MCP JSON-RPC endpoint open
       to any reachable caller, not just the OpenAI-compatible
       routes. Codex P2 on PR #255. *)
    Result := 'gateway: bearer-token auth DISABLED -- ' +
              'no token configured (every /v1/* and /mcp route ' +
              'open to any caller)';
    Exit;
  end;

  if LooksLikeUnresolvedTemplate(Tok) then
  begin
    Result := Format('gateway: bearer-token auth MISCONFIGURED -- ' +
                     'token field is unresolved template ''%s''; env var ' +
                     'not set, so no client token will match', [Tok]);
    Exit;
  end;

  Result := Format('gateway: bearer-token auth ENABLED ' +
                   '(source=%s, token len=%d, prefix=%s)',
                   [Source, Length(Tok), GatewayTokenPrefix(Tok)]);
end;

function EnvSubstJsonEscape(const S: string): string;
(* Escape a substituted env value so the resulting JSON stays valid
   no matter what bytes the operator's env happens to contain. Same
   control-byte handling as PasClaw.Otel's JsonEscape (intentionally
   duplicated -- making PasClaw.Config depend on PasClaw.Otel for
   one helper would be backwards: Config is downstream of Otel).
   Used only for ${VAR_NAME} expansion below. *)
var
  i: Integer;
  c: Char;
  Sb: TStringBuilder;
begin
  Sb := TStringBuilder.Create;
  try
    for i := 1 to Length(S) do
    begin
      c := S[i];
      case c of
        '"':  Sb.Append('\"');
        '\':  Sb.Append('\\');
        #8:   Sb.Append('\b');
        #9:   Sb.Append('\t');
        #10:  Sb.Append('\n');
        #12:  Sb.Append('\f');
        #13:  Sb.Append('\r');
      else
        if Ord(c) < $20 then
          Sb.Append('\u00' + IntToHex(Ord(c), 2))
        else
          Sb.Append(c);
      end;
    end;
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

function ExpandEnvVarsInJSON(const Body: string): string;
var
  i, j, n, NameStart: Integer;
  Sb: TStringBuilder;
  Name, Value: string;

  function IsFirstNameChar(c: Char): Boolean;
  begin
    Result := ((c >= 'A') and (c <= 'Z')) or (c = '_');
  end;

  function IsNameChar(c: Char): Boolean;
  begin
    Result := ((c >= 'A') and (c <= 'Z'))
           or ((c >= '0') and (c <= '9'))
           or (c = '_');
  end;

begin
  n := Length(Body);
  Sb := TStringBuilder.Create;
  try
    i := 1;
    while i <= n do
    begin
      if (Body[i] = '$') and (i + 1 <= n) and (Body[i + 1] = '{') then
      begin
        NameStart := i + 2;
        if (NameStart <= n) and IsFirstNameChar(Body[NameStart]) then
        begin
          j := NameStart + 1;
          while (j <= n) and IsNameChar(Body[j]) do Inc(j);
          if (j <= n) and (Body[j] = '}') then
          begin
            Name := Copy(Body, NameStart, j - NameStart);
            Value := GetEnvironmentVariable(Name);
            if Value <> '' then
              Sb.Append(EnvSubstJsonEscape(Value))
            else
              (* Unset / empty env: keep the literal ${VAR_NAME} in
                 the JSON so the operator can read config back and
                 see exactly which marker didn't resolve. FromJSON
                 accepts it as a normal string value. *)
              Sb.Append(Copy(Body, i, j + 1 - i));
            i := j + 1;
            Continue;
          end;
        end;
        (* Falls through: malformed ${...} -- missing closing brace,
           empty name, lowercase first char. Preserve verbatim so an
           accidental `$` in a value like a regex doesn't get eaten. *)
      end;
      Sb.Append(Body[i]);
      Inc(i);
    end;
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

procedure SaveConfig(C: TConfig);
begin
  WriteFileText(GetConfigPath, C.ToJSON);
end;

function RestoreMaskedConfigSecrets(const EditedJSON, CurrentJSON: string): string;

  { Codepage-agnostic "is this the mask placeholder?" check. This unit has
    no UTF8 codepage directive, so the MaskedSecretPlaceholder literal is
    tagged with the default source codepage while the parser hands back the
    value tagged CP_NONE/CP_ACP -- a direct equality triggers a lossy
    conversion and can be unequal on FPC despite byte-identical UTF-8.
    Compare the raw bytes instead. (Delphi's string is UnicodeString, so a
    plain compare is already correct there.) }
  function IsMask(const S: string): Boolean;
  begin
    {$IFDEF FPC}
    Result := RawByteString(S) = RawByteString(MaskedSecretPlaceholder);
    {$ELSE}
    Result := S = MaskedSecretPlaceholder;
    {$ENDIF}
  end;

  { Find the named item in Arr and return its String field, or '' if no
    match. Used to pull a secret back from the current config when the
    edited body kept the placeholder. }
  function LookupByName(Arr: TJsonArray; const Name, Field: string): string;
  var
    j: Integer;
    It: TJsonObject;
  begin
    Result := '';
    if Arr = nil then Exit;
    for j := 0 to Arr.Count - 1 do
    begin
      It := Arr.ItemObject(j);
      if It = nil then Continue;
      try
        if It.GetStr('name', '') = Name then
        begin
          Result := It.GetStr(Field, '');
          Exit;
        end;
      finally
        It.Free;
      end;
    end;
  end;

  { For each item in EdArr whose Field == placeholder, restore it from the
    same-named item in CurArr. }
  procedure RestoreArray(EdArr, CurArr: TJsonArray; const Field: string);
  var
    i: Integer;
    It: TJsonObject;
  begin
    if EdArr = nil then Exit;
    for i := 0 to EdArr.Count - 1 do
    begin
      It := EdArr.ItemObject(i);
      if It = nil then Continue;
      try
        if IsMask(It.GetStr(Field, '')) then
          It.PutStr(Field, LookupByName(CurArr, It.GetStr('name', ''), Field));
      finally
        It.Free;
      end;
    end;
  end;

var
  Edited, Current: TJsonObject;
  EdArr, CurArr: TJsonArray;
  EdGw, CurGw: TJsonObject;
begin
  Edited := TJsonObject.Parse(EditedJSON);
  if Edited = nil then
    raise EArgumentException.Create('config body is not valid JSON');
  try
    Current := TJsonObject.Parse(CurrentJSON);
    try
      { providers[].api_key -- matched by provider name. }
      EdArr  := Edited.ChildArray('providers');
      try
        if Current <> nil then CurArr := Current.ChildArray('providers') else CurArr := nil;
        try
          RestoreArray(EdArr, CurArr, 'api_key');
        finally
          if CurArr <> nil then CurArr.Free;
        end;
      finally
        if EdArr <> nil then EdArr.Free;
      end;

      { mcp_servers[].env -- matched by server name. }
      EdArr  := Edited.ChildArray('mcp_servers');
      try
        if Current <> nil then CurArr := Current.ChildArray('mcp_servers') else CurArr := nil;
        try
          RestoreArray(EdArr, CurArr, 'env');
        finally
          if CurArr <> nil then CurArr.Free;
        end;
      finally
        if EdArr <> nil then EdArr.Free;
      end;

      { gateway.token -- single object. }
      EdGw := Edited.ChildObject('gateway');
      if EdGw <> nil then
      try
        if IsMask(EdGw.GetStr('token', '')) then
        begin
          if Current <> nil then CurGw := Current.ChildObject('gateway') else CurGw := nil;
          if CurGw <> nil then
          try
            EdGw.PutStr('token', CurGw.GetStr('token', ''));
          finally
            CurGw.Free;
          end
          else
            EdGw.PutStr('token', '');
        end;
      finally
        EdGw.Free;
      end;

      { web_search.api_key -- single object. }
      EdGw := Edited.ChildObject('web_search');
      if EdGw <> nil then
      try
        if IsMask(EdGw.GetStr('api_key', '')) then
        begin
          if Current <> nil then CurGw := Current.ChildObject('web_search') else CurGw := nil;
          if CurGw <> nil then
          try
            EdGw.PutStr('api_key', CurGw.GetStr('api_key', ''));
          finally
            CurGw.Free;
          end
          else
            EdGw.PutStr('api_key', '');
        end;
      finally
        EdGw.Free;
      end;

      Result := Edited.ToJSON;
    finally
      if Current <> nil then Current.Free;
    end;
  finally
    Edited.Free;
  end;
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
