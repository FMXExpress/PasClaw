# Architecture

A walkthrough of how PasClaw's pieces fit together. The detailed truth is in the inline block comments at the top of each unit — this page is the orientation map.

## High level

```
                                  ┌──────────────────────────┐
                                  │   pasclaw.dpr  (entry)    │
                                  │   - banner / quiet detect │
                                  │   - tz init               │
                                  └───────────┬───────────────┘
                                              │
                                  ┌───────────▼───────────────┐
                                  │   PasClaw.Cmd.Root        │
                                  │   - argv → command        │
                                  │   - apply config log lvl  │
                                  └───────────┬───────────────┘
                                              │
                  ┌───────────────────────────┼───────────────────────────┐
                  │                           │                           │
        ┌─────────▼─────────┐       ┌─────────▼─────────┐       ┌─────────▼─────────┐
        │ pasclaw agent     │       │ pasclaw gateway   │       │ pasclaw tui       │
        │ pasclaw resume    │       │ pasclaw serve     │       │                   │
        │ pasclaw heartbeat │       │ TGatewayServer    │       │ Console two-pane  │
        │                   │       │ /v1/chat/comp.   │       │                   │
        └─────────┬─────────┘       └─────────┬─────────┘       └─────────┬─────────┘
                  │                           │                           │
                  └────────────┬──────────────┴────────────┬──────────────┘
                               │                           │
                  ┌────────────▼────────────┐ ┌────────────▼────────────┐
                  │ PasClaw.Tools.ToolLoop  │ │  PasClaw.Channels.*     │
                  │ RunToolLoop             │ │  Telegram / Slack /     │
                  │                         │ │  Matrix / IRC / ...     │
                  └────────────┬────────────┘ └────────────┬────────────┘
                               │                           │
                  ┌────────────▼───────────────────────────▼────────────┐
                  │   Provider chain (anthropic / openai / gemini ...)  │
                  │   Tool registry (fs_* / shell / web / mcp / skill)  │
                  │   MCP client bridges (stdio + http)                 │
                  │   Sandbox guard (workspace + shell + ssrf)          │
                  └─────────────────────────────────────────────────────┘
```

Every surface — CLI agent, gateway HTTP endpoints, TUI, chat channels, heartbeat daemon — calls into the **same** `RunToolLoop`. Behaviour is uniform: a tool added to the registry shows up everywhere.

## Entry point: `PasClaw.dpr`

`src/pasclaw/PasClaw.dpr` is the entry point on both FPC and Delphi builds. Sequence:

1. `CliUI_Init` — detect color support (`NO_COLOR` env, `--no-color` arg).
2. Decide whether to print the banner. Suppressed when:
   - `IsStdioMCPInvocation` — `pasclaw mcp stdio` must keep stdout clean JSON-RPC.
   - `IsQuietInvocation` — `--quiet` / `-q` anywhere on argv.
3. `IsQuietInvocation` also clamps the logger to `llError` so `[info]` / `[debug]` noise stays off the pipe scripts read.
4. `ApplyTimezoneFromEnv` — `$TZ` propagation for cron specs.
5. `RunRootCommand` — dispatch to the named command.

## Dispatch: `PasClaw.Cmd.Root`

`src/cmd/PasClaw.Cmd.Root.pas` is a flat switch on `argv[1]` → `Cmd_<Name>_Run`. Each command has its own `PasClaw.Cmd.<Name>.pas` unit.

Before dispatch, `RunRootCommand`:

- `CollectArgs` — read `ParamStr(1..N)` into a `TStringList`.
- `StripGlobalFlags` — remove `--no-color` (already consumed by `CliUI_Init`).
- `LoadConfig` + `SetLogLevelFromString(Cfg.Gateway.LogLevel)` — apply config-driven log level **unless** `ArgvHasQuietFlag` (which would undo the dpr's `llError` clamp).

Resume is a special-case shortcut: `pasclaw resume <id>` becomes `Cmd_Agent_Run(['--session', '<id>'])`.

## The agent loop: `PasClaw.Tools.ToolLoop.RunToolLoop`

The heart of PasClaw. Lives at `src/pkg/tools/PasClaw.Tools.ToolLoop.pas` and runs everywhere the agent runs.

### Iteration shape

```
loop while Iter < MaxIterations:
  Iter += 1

  # 1. Pre-call compaction
  if NeedsCompact(Hist):
    Hist = CompactMessages(Hist, system_prompt)

  # 2. Drain background results + steering queue
  if BackgroundDrainKey: drain into system prompt
  if SteeringKey:        drain queue → fold N entries as [user steering] system notes

  # 3. Provider request (with empty-turn retry + fallback walk)
  span openclaw.agent.turn → span chat <model>:
    Resp = ChatWithEmptyRetry(Provider, Hist, Tools, Model, Options)
    if Resp not 2xx:
      walk Cfg.Fallbacks calling Chat on each until one succeeds

  # 4. Roll usage + fire hooks + OnText
  Loop.TotalUsage += Resp.Usage
  HooksOnError if Resp not 2xx

  # 5. If no tool_calls: append assistant text, return success
  if Resp.ToolCalls empty:
    Loop.Content = Resp.Content
    return True

  # 6. Plan tool batches (parallel-friendly read-only groups + serial mutating)
  Batches = BuildBatches(Resp.ToolCalls, Registry, Cfg.Parallel)

  for Batch in Batches:
    # 7. Approval-gate hooks (BeforeToolCall) may veto / synthesise results
    HooksBeforeToolCall

    if len(Batch) > 1 and Cfg.Parallel:
      fan out to worker threads, join
    else:
      span execute_tool <name>:
        DispatchOneToolCall(Cfg, slot)

    # 8. AfterToolResult hooks + OnToolResult event + append to Hist
    HooksAfterToolResult         # may rewrite ResultText and inject a system note
    InContext = StashAndMaybeTruncate(ResultText, OutputCache)
    Hist.append(tool_result message)

return True (exhausted iterations)
```

### Compaction

Mid-loop. When `TokenEstimate(Hist) > Cfg.CompactOpts.ThresholdTokens` (default 50000), `CompactMessages` slices off the older portion, runs `Provider.Chat` against the slice with a summariser system prompt, and replaces the slice with a single system message. Falls back to verbatim on summariser failure — no silent context loss.

### Steering

`Cfg.SteeringKey` (typically the session id) registers the loop with `PasClaw.Agent.Steering`. At each iteration's top, pending messages (pushed by `pasclaw steer <id> "..."` from another terminal, or `/steer` inline) drain into history as `[user steering] ...` system notes. Up to 4 per iteration; extras drop with a warning. Storage: `workspace/steering/<id>.jsonl`.

### Hooks

`Cfg.Hooks` is an array of `TPasClawHook`. Four virtuals fire in registration order:

| Stage | Virtual | Power |
|---|---|---|
| Start of turn | `BeforeTurn(var ContinueTurn, var Messages)` | Abort cleanly, mutate `Messages`. |
| Before each tool call | `BeforeToolCall(call, var Cancel, var SyntheticResult)` | Approval-gate. `Cancel := True` skips the real handler. |
| After each tool call | `AfterToolResult(call, var ResultText, var ErrMsg, var SteeringMessage)` | Rewrite results; inject a system note before the next round. |
| On error | `OnError(Stage, Msg)` | Observe only. Stages: `hsProviderCall`, `hsToolDispatch`, `hsCompact`. |

See [Embedding](./embedding.md#hooks) for the user-facing surface.

### Fallback walk

When `Cfg.Provider.Chat` returns a non-2xx (or `StatusCode <= 0` for pre-HTTP failures: DNS miss, TLS refusal, socket reset, no OpenSSL IO handler) the loop walks `Cfg.Fallbacks` (a `TLLMProviderArray` resolved from `TConfig.Fallbacks` via `PasClaw.Providers.Factory.ResolveFallbacks`). Each fallback is tried with the same `Hist + Tools + Model + Options`; the first 2xx wins.

Auto-router (cheap-tier routing) prepends the original primary to the fallback chain when a turn is routed away, so a misclassified easy turn falls through transparently.

### Parallel dispatch

Read-only tools (`tcReadOnly` category: `web_search`, `web_fetch`, `fs_read`/`grep`/`list`, `memory_search`) form parallel batches; mutating tools (`tcMutating`: `fs_write`, `fs_edit_hashline`, `shell_exec`, `execute_code`) are batches of one. Each parallel batch runs on dedicated worker threads (`TToolCallWorker`); the main thread joins before the next batch. Race-free by construction — workers only touch their own slot in the `Dispatches` array.

Hooks always fire on the main thread, in array order, AFTER the whole batch joins. So `OnToolCall` / `OnToolResult` orderings the embedder sees are identical between serial and parallel modes.

## Tool dispatch: `PasClaw.Tools.Registry`

`TToolRegistry` is a flat name → handler map. `RunTool(Name, ArgsJSON, out Err)` looks up the named tool, runs preflight (`PreflightToolCall`), invokes `Handler(ArgsJSON, Err)`, returns the result string.

Tools are records of `(Name, Description, Schema, Handler, IsCore, Category)`. The schema is JSON Schema; the model sees `Name + Description + Schema`. `IsCore: True` means "always advertised, even with `--no-tools`" — currently used only for `tool_output_get`.

`Category` (`tcReadOnly` / `tcMutating`) controls parallel-batch eligibility.

## Provider chain: `PasClaw.Providers.*`

`PasClaw.Providers.Factory.NewProviderFromConfig(Kind)` returns an `ILLMProvider` interface backed by:

- `PasClaw.Providers.Anthropic` (`pfAnthropic` catalog entries).
- `PasClaw.Providers.OpenAI` (`pfOpenAI` — covers OpenAI + 17 compatible providers).
- `PasClaw.Providers.Gemini` (`pfGemini`).

Each implements `Chat(Messages, Tools, Model, Options): TLLMResponse` and `ChatStream(...)`. Streaming uses Indy's SSE parser; the non-stream variant is one-shot.

`ChatWithEmptyRetry` (in `PasClaw.Stream.Reliability`) wraps `Provider.Chat` with N retries on empty-turn responses (`Content='' + no tool calls + finish_reason='stop'`). Default 0; CLI agent and gateway opt in via `Cfg.StreamReliability.EmptyRetryAttempts`.

## MCP bridges: `PasClaw.MCP.*`

Two transports:

- **Stdio** — `PasClaw.MCP.Client.Stdio` spawns the subprocess once per session, holds an open pipe, multiplexes JSON-RPC calls.
- **HTTP** — `PasClaw.MCP.Client.HTTP` reuses an Indy `TIdHTTP` connection, handles SSE-framed responses (Streamable HTTP MCP), and supports Bearer-token auth.

`PasClaw.MCP.Bridge` registers each MCP server's tools into the `TToolRegistry` with the server's name as a prefix (`filesystem.read_file`). Cached metadata lives at `$PASCLAW_HOME/cache/mcp/<server>.json` so a startup refresh doesn't block the first turn — see `mcp[<name>] cache hit` log line.

## Sandbox: `PasClaw.Tools.Sandbox`

Two gates:

1. **`CanReadPath` / `CanWritePath`** — checked before every `fs_*` syscall. Respects `sandbox.restrict_to_workspace`, `allow_read_paths` / `allow_write_paths` regex, `allow_read_outside_workspace`.
2. **`ShellAllowed`** — checked before `shell_exec` / `execute_code`. Token denylist (`sudo`, `rm`, `dd`, `mkfs`, ...) + substring denylist (`dd if=`, `$( )`, ...) + custom-substring extension. Workspace-pin in the shell when `restrict_to_workspace`: `Tool_Shell` passes `WorkingDir = workspace` to `RunOneShot`.

`PasClaw.Net.SSRF.IsBlocked` guards `web_fetch` URLs and every redirect hop.

## Shell backend: `PasClaw.Shell.Backend`

`IShellBackend` interface with two implementations:

- **Local** (`PasClaw.Shell.Backend.Local`) — `/bin/sh -c` (or `cmd.exe /C`) in the host process. Default.
- **Docker** (`PasClaw.Shell.Backend.Docker`) — per-session container, `docker exec` for each call, workspace bind-mounted at the same path. Hardening win: even denylist escapes hit only the container, not the host.

`StartShellSession(SessionId)` / `CloseShellSession(SessionId)` bracket each session. `RunOneShotViaBackend` dispatches through the active backend; `SetCurrentSessionId` tells the backend which session to attribute the call to.

## Storage layout

See [Getting started](./getting-started.md#what-gets-created-where) for the on-disk tree under `$PASCLAW_HOME`.

## Telemetry: `PasClaw.Otel`

OTLP/HTTP+JSON exporter, OFF by default. When enabled:

- `StartSpan(name, kind, parentTraceparent)` returns a `TOtelSpan` or nil (if disabled or not sampled).
- Threadvar current-span stack handles parent inheritance across nested spans.
- Spans buffer until the root finishes (typically the agent.turn span), then ship in one POST.
- Test seam `SetExportTransport(@CaptureFn)` swaps the OTLP/HTTP transport for a callback — used by `make test-otel`.

Instrumentation points: agent turn (`openclaw.agent.turn`), provider request (`chat <model>` with `gen_ai.*` attrs), tool call (`execute_tool <name>`), and HTTP server (`HTTP <method> <route>` in the gateway).

See [Observability](./observability.md) for the full span shape.

## Logger: `PasClaw.Logger`

Five-level (`Debug` / `Info` / `Warn` / `Error` / `Silent`) with stderr output + 1000-entry ring buffer. Listeners subscribable for the SSE `/v1/logs` route.

`SetLogLevel` global, mutated by:

1. The dpr's `--quiet` clamp.
2. `RunRootCommand`'s `SetLogLevelFromString(Cfg.Gateway.LogLevel)` (skipped when quiet).
3. Per-command overrides (e.g. `--debug` on `pasclaw serve`).

## Cross-cutting concerns

- **Hashline format** (`PasClaw.Hashline`) — the `¶path#hash` header + LINENO:line shape that `fs_read` emits, `fs_grep` returns matches in, and `fs_edit_hashline` parses for race-safe patches.
- **JSON** (`PasClaw.JSON`) — project-local DOM. Simple GetStr/GetInt/GetBool/GetFloat + ChildObject/ChildArray API. The same TJsonObject is used for config, MCP RPC, tool args, provider request bodies.
- **HTTP** (`PasClaw.Providers.HTTP`) — `PostJSON` / `GetJSON` helpers wrapping `TIdHTTP`. Used by every outbound HTTP path (providers, MCP, OTel, channels). Honours sandbox `block_private_networks` via `PasClaw.Net.SSRF`.
- **Output cache** (`PasClaw.Tools.OutputCache`) — process-lifetime store for `tool_output_get` handles. Used by both the byte-cap truncation and the reversible-condensation footer.
- **Identity** (`PasClaw.Identity`) — canonical `<platform>:<id>` strings and the `IsAllowedSender` gate.
- **Promptware** (`PasClaw.Promptware`) — substring-pattern scan over three indirect-input chokepoints (tool output, recalled memory, stored skills). See [Tools](./tools.md#promptware-defense).

## Repository layout

See the [root README](../README.md#repository-layout) for the `src/cmd/` + `src/pkg/*/` breakdown.

## See also

- [Contributing](./contributing.md) for build / test conventions when modifying these subsystems.
- [Embedding](./embedding.md) for the `TPasClawAgent` / `TPasClawServer` shape on top of the loop.
- [Observability](./observability.md) for instrumentation hookpoints.
