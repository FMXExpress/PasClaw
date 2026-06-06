# PasClaw

PasClaw is an ultra-lightweight personal AI agent written in Delphi Object Pascal. It is a Delphi/FPC port inspired by picoclaw, with a command-line assistant, tool calling, MCP integration, an HTTP gateway, an OpenAI-compatible API surface, a small embedded web UI, scheduled tasks, skills, and channel integrations.

The main program lives at `src/pasclaw/PasClaw.dpr`. It initializes terminal color handling, prints the banner, applies timezone configuration, and dispatches into the command tree implemented under `src/cmd/`.

## Features

**LLM providers** — 19-entry catalog covering Anthropic Messages, OpenAI Chat Completions, Google Gemini `generateContent`, plus OpenAI-protocol-compatible providers (Groq, DeepSeek, Mistral, Cerebras, OpenRouter, Zhipu, Qwen, Moonshot, MiniMax, NVIDIA NIM, Novita, MiMo, VolcEngine, Ollama, vLLM, LiteLLM). The full list lives in `src/pkg/providers/PasClaw.Providers.Catalog.pas`; adding a provider is a one-record append. Streaming SSE on all three protocol families; native search grounding on Gemini; citation collation on Perplexity. **Fallback chain** — `Cfg.Fallbacks = ["openai", "gemini"]` walks the list when the primary returns 429 / 5xx / network error. Code-driven `SetProvider('anthropic', $ANTHROPIC_API_KEY)` for embedders so no `~/.pasclaw/config.json` is required.

**Built-in tools** — exposed to the model on every turn:

| Tool | What it does |
|---|---|
| `fs_read` / `fs_write` / `fs_list` | sandboxed filesystem access |
| `fs_grep` | recursive substring search, returns hashline-formatted matches |
| `fs_edit_hashline` | patch by line-anchor + file-hash header, race-safe |
| `shell_exec` | `/bin/sh -c` (or `cmd.exe`), output capped at 1 MiB, denylist-gated |
| `web_search` | DuckDuckGo / Brave / Tavily / SearXNG / Perplexity / Gemini-grounding — 6 providers |
| `web_fetch` | HTTP GET → readable plain text (HTML stripped, entities decoded), SSRF-guarded |
| `memory_search` | SQLite FTS5 BM25 over `workspace/memory/*.md` and `MEMORY.md`; hybrid FTS + local-vector mode opt-in via `vector_search_enabled` (default yes; embedding model downloaded on first use after the runtime hookup PR lands) |
| `vault_search` / `vault_get` | search + read pasclaw.dev Code Vault entries (Object Pascal samples + components); opt-in via `vault_tools_enabled` |
| `skill_<name>` | Pascal-side tools registered from `kind: shell` / `kind: prompt` skills |
| MCP-bridged | every tool a configured MCP server exports — see below |

**Parallel dispatch** — when the model returns multiple `tool_use` blocks in one turn, read-only tools (`web_search`, `web_fetch`, `fs_read`/`grep`/`list`, `memory_search`) fan out on worker threads; mutating tools (`fs_write`, `fs_edit_hashline`, `shell_exec`) stay serial. ~50% wall-clock win on multi-network-tool turns.

**MCP** — both transports. Stdio MCP via spawned subprocess + JSON-RPC over pipes, and Streamable HTTP MCP (handles SSE-framed responses, Bearer-token auth). `pasclaw mcp catalog` queries the pasclaw.dev MCP registry (`GET /api/public/v1/mcp`) with a 5 s timeout and falls back to the bundled 5-entry list (`replicate`, `digitalocean-apps`, `digitalocean-databases`, `runpod-docs`, `huggingface`) when the hub is unreachable — source attribution (`hub` / `built-in`) shown in the output. `pasclaw mcp search <q>` searches the hub directly (no fallback — bundled list is too small to search). `pasclaw mcp install <slug>` tries the hub first so any registered server is installable, falls back to the bundled catalog when the hub doesn't have it. Reads the right env var, writes the right Authorization header, never preloaded.

**Skills** — markdown manifests under `$PASCLAW_HOME/workspace/skills/` advertised in the system prompt; the model loads the body via `fs_read` on demand. Install from GitHub (`pasclaw skills install owner/repo[/path][@ref]` — codeload zip, FPC's `Zipper.TUnZipper` or Delphi's `System.Zip.TZipFile`); from the pasclaw.dev hub (`pasclaw skills install hub:<slug>[@<version>]`, or just `pasclaw skills install <slug>` which tries pasclaw.dev first then falls back to ClawHub); or from ClawHub directly (`pasclaw skills install clawhub:<slug>[@<version>]`). `pasclaw skills search <q>` queries both hubs and aggregates the results (pasclaw.dev first, ClawHub deduped). Malware-flagged skills refused; suspicious-flagged install with a warning.

**Code Vault** — the pasclaw.dev Code Vault hosts Object Pascal source code (sample programs, reusable components, libraries) as GitHub-backed entries. `pasclaw vault search <q>` and `pasclaw vault show <slug>` discover; `pasclaw vault install <slug> [<dest>]` `git clone`s the entry's `repoUrl` into `$PASCLAW_HOME/workspace/vault/<slug>` (or a path you pass). The agent gets two **opt-in** tools — `vault_search` and `vault_get` — registered only when `vault_tools_enabled: true` in config.json; `pasclaw onboard` asks during setup with a default-yes prompt. Both tools are read-only HTTP GETs against the vault registry; obtaining the code itself is a separate `shell_exec git clone` call the model makes after `vault_get` returns the `repoUrl`.

**HTTP gateway** — `pasclaw gateway` and `pasclaw serve`. OpenAI-compatible `/v1/chat/completions` (streaming + non-streaming) and `/v1/responses` (tool-passthrough so Codex CLI can drive its own tools). Embedded web UI (vanilla ES2020, single HTML file, no JS toolchain) with 8 tabs: **Chat** (SSE-streamed, tool activity surfaced inline), **Memory**, **Files**, **MCP**, **Cron**, **Skills**, **Logs** (live tail via SSE from the in-process ring buffer), **Settings**. Read-only inspection endpoints (`/v1/mcp`, `/v1/cron`, `/v1/skills`, `/v1/memory`, `/v1/fs`, `/v1/config`, `/v1/logs`) backed by the gateway's sandbox + secret-masking.

**Chat channels** — bidirectional (inbound message → agent loop → outbound reply): Telegram (long-poll bot), Discord (bot polling), LINE (webhook), WhatsApp (Cloud API webhook), Slack (Events API webhook + Incoming Webhook reply), Matrix (REST `/sync` long-poll, federated, self-hostable), IRC (`TIdIRC`), Email (SMTP send + IMAP poll, `--email` flag, env-var configured). Outbound-only: Microsoft Teams (Incoming Webhook), generic Webhook sink.

**Cron** — `pasclaw cron add daily-summary "0 9 * * *" summarize "workspace/memory"`. Last-fired timestamp persisted to `workspace/cron/state.json` so a missed slot (gateway down, laptop closed) catches up on the next tick instead of being silently skipped. **At-least-once delivery** — the state file is written after the skill runs, so a crash in the window between the skill's side effects and the timestamp persist will replay the job on restart; idempotent skills are safe, side-effecting skills should self-deduplicate. Per-entry channel sink (`--channel <kind>:<target>`) posts skill output; output also appended to `workspace/memory/<today>.md` for the model to recall later.

**Memory** — SQLite FTS5 BM25 index over `workspace/memory/*.md` and `MEMORY.md`. `pasclaw migrate` (re-)indexes; `pasclaw membench --records N` benchmarks. Conversation history compaction (`pasclaw compaction.threshold_tokens`) kicks in mid-loop, summarises the older portion via the same provider, folds the summary into the system prompt, falls back to verbatim on summariser failure (no silent context loss).

**Sandbox + safety** — read/write path allowlists, shell-command denylist (separate `restrict_to_workspace` denylist + `shell_deny_enabled` global), SSRF guard on `web_fetch` (IPv4 blocklist incl. `169.254.169.254`, redirect re-check), hashline patches require matching file-hash header (stale patches abort without writing). TLS required for HTTPS provider/MCP calls via Indy's OpenSSL IO handler.

**Embedding** — `TPasClawAgent` and `TPasClawServer` as `TComponent`s in `PasClaw.Agent`:

```pascal
uses PasClaw.Agent, PasClaw.Tools;

Agent := TPasClawAgent.Create('claude-opus-4-7');
Agent.SetProvider('anthropic', GetEnvironmentVariable('ANTHROPIC_API_KEY'));
Agent.RegisterTool(TWebSearchTool.Create);
Agent.RegisterTool(TFileSystemTool.Create);
WriteLn(Agent.Run('Summarize the latest Delphi release notes.'));
Agent.Free;
```

Form-designable with published properties for the VCL/FMX path; code-driven OOP API for everything else. Custom tools subclass `TPasClawTool` and override `Name` / `Description` / `Schema` / `Run` / `Category`. Single-process server: `TPasClawServer.Create('0.0.0.0', 8088); Server.Run;` blocks until `Stop` is signalled from another thread.

**Interactive chat** — `pasclaw agent` and `pasclaw tui` ship slash commands: `/help` lists them; `/status` shows model + provider + message count + thinking state; `/new` starts a fresh session (new id, history cleared); `/reset` clears history in the current session; `/compact` forces a summariser pass; `/think` toggles extended-thinking mode for the next turn (Anthropic Claude); `/tools` lists registered tools; `/quit` exits.

**Persistent sessions** — `pasclaw agent` serialises conversation history to `$PASCLAW_HOME/workspace/sessions/<id>.json` after every turn (messages + tool_calls + tool_results + model + provider + compaction summary). Persistence is on by default — every interactive `pasclaw agent` run auto-allocates a fresh id and the conversation survives Ctrl-C / crash without any flag. Resume with `pasclaw resume <id>` or `pasclaw agent --session <id>`; an id that doesn't yet exist starts a fresh session at that id (handy for scripts pre-seeding e.g. `daily-2026-06-01`). `pasclaw session list / show / delete / export` manages saved sessions. Session ids are `yyyymmddTHHMMSS-<8 hex>` — sortable and collision-safe. On the **Delphi build** of `pasclaw tui` the same persistence is wired through a positioned two-pane TUI (session list on the left, chat on the right) — see Chat and UI below. The **FPC build** of `tui` keeps history in-memory.

**Prompt caching** — on by default for Anthropic and OpenAI. The Anthropic request builder emits `cache_control: { type: "ephemeral" }` on the system prompt and the trailing tools-array entry (uses 2 of the 4-breakpoint budget; caches the largest stable prefix on every turn), with optional `ttl: "1h"` extended-TTL hint. OpenAI gets `prompt_cache_key` anchored to the persistent session id so each conversation routes to its own cache bucket. Cache hit / write tokens roll up in `/status` (`cache: on, N read / M written (X% hit on input so far)`) and surface inline in the per-turn `[tokens in=… out=… cache_r=… cache_w=…]` summary. Disable via `prompt_cache.enabled: false` in `config.json`; extend the TTL via `prompt_cache.ttl: "1h"`. Gemini caching not yet wired — implicit caching applies automatically on supported models.

**Sender identity** — every channel tags inbound messages with a canonical `<platform>:<id>` (e.g. `slack:U12345`, `telegram:5551234`, `matrix:@eli:matrix.org`, `email:eli@example.com`, `irc:eli`, `discord:9876543210`, `cli:$USER`). Identity rides on `TToolLoopConfig.Identity` from the channel boundary down through hooks and audit logs, so embedder hooks can gate behaviour per-sender. Configure an allowlist in `config.json`:

```json
"allow_senders": ["slack:U-eli", "telegram:*", "cli:*"]
```

Patterns are exact ids or `<platform>:*` wildcards; `*` allows anyone (escape hatch). Empty array (default) = no gate. Each channel calls `IsAllowedSender` before invoking the agent — non-matching senders are dropped at the boundary with a log line, the model never sees them. Ports picoclaw's `pkg/identity` pattern.

**Mid-loop steering** — push a follow-up into a running agent without waiting for the current tool loop to finish. From another terminal:

```sh
pasclaw steer 20260601T093015-1a2b3c4d "actually skip X, focus on Y"
pasclaw steer <session-id> --list        # show pending count
pasclaw steer <session-id> --clear       # drop the queue
```

The running `pasclaw agent --session <id>` drains the queue at the top of its NEXT tool-loop iteration and folds each pending message into history as a `[user steering] ...` system note before the next LLM round-trip. Up to 4 messages per iteration are applied (`MaxSteeringPerTurn`, matching nanobot's `_MAX_INJECTIONS_PER_TURN`); extras are dropped with a warning so a runaway pusher can't grow history unbounded. `/steer <msg>` inside an interactive session is the same mechanism (handy for testing). `/reset`, `/new`, and `pasclaw session delete` clear the queue. Storage is one append-only JSONL file per session under `$PASCLAW_HOME/workspace/steering/<id>.jsonl` — atomic per-line POSIX appends + rename-to-tmp-on-drain so concurrent push/drain doesn't lose messages. Currently only CLI sessions wire `SteeringKey`; channels can opt in by passing their own per-conversation key on `TToolLoopConfig.SteeringKey` once they restructure to non-blocking poll loops.

**Hooks + steering** — `TPasClawHook` (in `PasClaw.Agent.Hooks`) is the typed callback surface for embedders to observe, transform, or veto agent events. Four virtuals: `BeforeTurn(var ContinueTurn, var Messages)` — set ContinueTurn := False to abort cleanly; `BeforeToolCall(call, var Cancel, var SyntheticResult)` — Cancel := True bypasses the real tool handler and uses SyntheticResult as the tool_result (the approval-gate pattern); `AfterToolResult(call, var ResultText, var ErrMsg, var SteeringMessage)` — rewrite results inline AND inject a system note before the next LLM round (picoclaw's steering); `OnError(Stage, Msg)` — observe failures. Register via `Agent.RegisterHook(THook.Create)`; multiple hooks form an ordered chain in registration order.

**Subagents** — fan-out to focused specialists via a `spawn(agent, prompt)` tool. Declare them in `config.json`'s `subagents:` array (name + description + system prompt + tool allowlist + optional model / max-iterations override). Each spawn runs a short `RunToolLoop` against the parent's provider + fallback chain with a registry filtered to the named tools and a specialist system prompt; result lands back as the parent's `tool_result`. Implementation in `src/pkg/agent/PasClaw.Agent.Subagent.pas` — picoclaw's `SubTurn` pattern, nanobot's `subagent` module, openclaw's multi-agent routing, ~300 LOC.

```json
"subagents": [
  { "name": "researcher",
    "description": "Web search + summary specialist",
    "system_prompt": "You search the web and produce a 3-bullet summary...",
    "tools": ["web_search", "web_fetch"],
    "max_iterations": 4 },
  { "name": "coder",
    "description": "Code editor",
    "system_prompt": "You edit code precisely using hashline patches...",
    "tools": ["fs_read", "fs_write", "fs_grep", "fs_edit_hashline"] }
]
```

**Cross-platform** — Linux x86_64 + aarch64 under FPC 3.2+; macOS x86_64 + arm64 under FPC (Homebrew unit paths autodetected); Windows x64 + Linux + macOS under Delphi 12 / RAD Studio. Windows-on-ARM64 builds via FPC are supported through the Makefile's `CROSS_TARGET=aarch64-win64` override (pair with `FPC_UNITS_DIR` pointing at the cross-build's unit tree); the updater emits `windows_arm64.exe` as the release-asset suffix on those builds. The `Delphi 13 WinArm64EC` target isn't wired into `PasClaw.dproj` yet — add the platform via the IDE's Project Manager when you're ready to ship for it. Three sample binaries under `samples/component-console/` plus matching `.dproj` files for RAD Studio and `dcc32.cfg` / `dcc64.cfg` for cmdline Delphi builds.

## Requirements

- Free Pascal 3.2+ in Delphi mode, or Delphi/RAD Studio.
- Indy (`TIdHTTP`, `TIdHTTPServer`) for HTTP clients, the gateway, and channel integrations.
  - FPC builds vendor Indy into `vendor/Indy`.
  - Delphi/RAD Studio ships Indy, so no vendored Indy checkout is required.

## Build

### Delphi / RAD Studio

Open `src/pasclaw/PasClaw.dproj` in Delphi/RAD Studio and build the project. The checked-in Delphi project already contains the project search paths.

On Windows, you can optionally build from a RAD Studio command prompt with:

```bat
build-delphi.bat
```

The batch file uses MSBuild with the existing Delphi project when available, and falls back to the installed Delphi command-line compiler.

### Free Pascal

See [`fpc.md`](fpc.md) for detailed FPC prerequisites, Indy vendoring, resource generation, Makefile targets, and variable overrides.

On Windows, you can optionally build with:

```bat
build-fpc.bat
```

## Configuration

PasClaw stores configuration as JSON. By default:

- Home directory: `~/.pasclaw`
- Config file: `~/.pasclaw/config.json`
- Default provider: `anthropic`
- Default model: `claude-opus-4-7`
- Gateway bind address: `127.0.0.1`
- Gateway port: `8088`
- Gateway log level: `info`

Environment variables:

| Variable | Purpose |
|----------|---------|
| `PASCLAW_HOME` | Overrides the PasClaw home directory. |
| `PASCLAW_CONFIG` | Overrides the config file path. |
| `PASCLAW_VERSION` | Compile-time FPC version override used by the Makefile. |
| `PASCLAW_TELEGRAM_TOKEN` | Default Telegram bot token for `pasclaw gateway --telegram`. |
| `PASCLAW_LINE_TOKEN` | LINE Messaging API channel access token. Used by `pasclaw post line` and `pasclaw gateway --line`. |
| `PASCLAW_LINE_SECRET` | LINE channel secret. Required by `pasclaw gateway --line` to verify `X-Line-Signature` on inbound events. |
| `PASCLAW_WHATSAPP_TOKEN` | WhatsApp Cloud API system-user access token. Used by `pasclaw post whatsapp` and `pasclaw gateway --whatsapp`. |
| `PASCLAW_WHATSAPP_PHONE_ID` | WhatsApp phone-number ID (the numeric ID, not the phone number itself). |
| `PASCLAW_WHATSAPP_VERIFY_TOKEN` | User-chosen string used to verify Meta's `GET /webhooks/whatsapp` subscription handshake. |
| `PASCLAW_WHATSAPP_APP_SECRET` | Meta App Secret used to validate `X-Hub-Signature-256` on inbound events. |
| `PASCLAW_BRAVE_API_KEY` | Brave Search API key for the `web_search` tool when `web_search.provider = brave`. |
| `PASCLAW_TAVILY_API_KEY` | Tavily API key for the `web_search` tool when `web_search.provider = tavily`. |
| `PASCLAW_SEARXNG_API_KEY` | Bearer token for protected SearXNG instances (most public ones don't need it). |
| `PASCLAW_PERPLEXITY_API_KEY` | Perplexity API key for the `web_search` tool when `web_search.provider = perplexity`. |
| `PASCLAW_GEMINI_API_KEY` | Google AI Studio key for the `web_search` tool when `web_search.provider = gemini`. `PASCLAW_GOOGLE_API_KEY` works too. |
| `PASCLAW_MATRIX_HOMESERVER` | Matrix homeserver base URL (e.g. `https://matrix.org`) for `pasclaw gateway --matrix`. |
| `PASCLAW_MATRIX_TOKEN` | Matrix access token (provisioned out-of-band via `/login` or the homeserver admin UI). |
| `PASCLAW_IRC_SERVER` | IRC server hostname (e.g. `irc.libera.chat`) for `pasclaw gateway --irc`. |
| `PASCLAW_IRC_PORT` | IRC server port (default `6667`). |
| `PASCLAW_IRC_NICK` | IRC nickname the bot connects with. |
| `PASCLAW_IRC_CHANNEL` | IRC channel to join on connect (must start with `#`). |
| `PASCLAW_IRC_PASSWORD` | Optional NickServ / server password. |
| `NO_COLOR` | Disables ANSI color output. |

Useful config commands:

```sh
pasclaw onboard       # create/update home + workspace dirs, pick a provider + model + API key,
                      # then optionally enable any of the 5 built-in MCP servers inline
                      # (replicate, digitalocean-apps, digitalocean-databases, runpod-docs, huggingface)
pasclaw config        # print current JSON config
pasclaw config path   # print resolved config path
pasclaw config reset  # write a default config
```

## Command surface

Global flags:

```sh
pasclaw --help
pasclaw --no-color status
NO_COLOR=1 pasclaw status
```

Top-level commands are dispatched by `src/cmd/PasClaw.Cmd.Root.pas`:

| Command | Purpose |
|---------|---------|
| `config` | View or reset the JSON configuration. |
| `onboard` | Initialize `PASCLAW_HOME`, workspace folders, and provider settings. |
| `agent` | Chat with the assistant from the terminal. |
| `tui` | Chat in the full-screen TUI. |
| `auth` | Store, clear, or inspect provider API keys. |
| `gateway` | Start the full HTTP gateway, embedded web UI, cron scheduler, tools, MCP, and optional Telegram channel. |
| `serve` | Start the OpenAI-compatible API server surface. |
| `status` | Show provider, model, gateway, MCP, cron, and skill status. |
| `cron` | Manage scheduled tasks. |
| `mcp` | Manage MCP server entries. |
| `migrate` | Run data migrations for older versions. |
| `skills` | List, install, or remove skill extensions. |
| `model` | Show or change the default model. |
| `post` | Send a one-shot message to a Discord, Slack, Microsoft Teams, generic, LINE, or WhatsApp webhook target. |
| `membench` | Benchmark the memory log subsystem. |
| `update` | Check GitHub releases or self-update. |
| `version` | Print version/build information. |

### Chat and UI

```sh
pasclaw agent
pasclaw agent -m "hello"
pasclaw agent --model claude-opus-4-7 --provider anthropic -m "summarize this repo"
pasclaw agent --system "Be concise" --thinking medium --max-tokens 2048 --max-iterations 25
pasclaw agent --no-tools --no-mcp --no-hashline

pasclaw tui
pasclaw tui --session 20260601T093015-1a2b3c4d
pasclaw tui --provider openai --model gpt-4o-mini
pasclaw tui --theme matrix
pasclaw tui --no-tools --no-mcp --no-hashline
```

The **Delphi build** of `pasclaw tui` paints a positioned two-pane layout (`MVCFramework.Console`-backed, default theme `ConsoleThemeDefault`): session list on the left, chat history + input on the right, header bar with provider/model/clock, footer bar with focus-aware hotkeys. **Tab** swaps focus between panes; in the session pane **Up/Down** navigates, **Enter** loads, **N** spawns a fresh session, **D** then **Y** deletes (one-key confirm), **R** refreshes the list. In the chat pane typing fills the input; **Enter** sends the turn (which runs in a background thread so the UI keeps redrawing — spinner shown in the divider above the input); **Up/Down** scrolls the chat back. If a follow-up is sent while a turn is still running it's queued via [`pasclaw steer`](#mid-loop-steering) automatically. Pending steering count is shown in the chat divider next to the spinner. **Q** or **Escape** quits. The **FPC build** of `pasclaw tui` stays on the original line-based ANSI renderer (no session list pane yet).

**Theme switcher** — `--theme <name>` picks the initial colour theme; type `/theme` inside the TUI to open a modal menu with **Up/Down** live-preview, **Enter** to apply, **Escape** to revert. Themes are the ones DMVCFramework ships: `default` (default), `navy`, `matrix`, `sunset`, `ocean`, `midnight`, `classic`. Unknown names fall back to `default` silently. Changes don't persist across runs — pass `--theme` next time, or wire a config field in a follow-up.

### Provider authentication and model selection

```sh
pasclaw auth status
pasclaw auth login anthropic
pasclaw auth logout anthropic
pasclaw auth weixin

pasclaw model show
pasclaw model set claude-opus-4-7
pasclaw model add openai gpt-4o-mini
```

`auth login` prompts for an API key and stores it in the matching provider entry. `model set` changes `default_model`; `model add` upserts a provider entry and records a model for that provider.

### MCP servers

```sh
pasclaw mcp list
pasclaw mcp add filesystem npx -y @modelcontextprotocol/server-filesystem /tmp
pasclaw mcp add remote https://example.com/mcp
pasclaw mcp show filesystem
pasclaw mcp test filesystem
pasclaw mcp remove filesystem
pasclaw mcp edit

pasclaw mcp catalog          # list public MCP servers PasClaw knows about
pasclaw mcp install <name>   # add one from the catalog; auth from $ENV_VAR
```

MCP entries are stored in the config as `mcp_servers`. A command starting with `http://` or `https://` is tested with the HTTP MCP client; other commands are spawned with the stdio MCP client.

**Catalog** (curated public MCP servers; opt-in, never preloaded). `pasclaw mcp install <name>` writes a normal `mcp_servers` entry — list/remove/test/show all just work afterwards. Auth is read from the env var the catalog entry names; installing with the env unset writes an empty Authorization header and a hint to re-run after setting it.

| name | env var | provider |
|---|---|---|
| `replicate` | `REPLICATE_API_TOKEN` | Run AI models (text/image/video/audio) on Replicate — 5000+ models. |
| `digitalocean-apps` | `DIGITALOCEAN_TOKEN` | Manage DigitalOcean App Platform. |
| `digitalocean-databases` | `DIGITALOCEAN_TOKEN` | Manage DigitalOcean Managed Databases. |
| `runpod-docs` | _(none)_ | Search RunPod documentation. |
| `huggingface` | `HF_TOKEN` | Search models / datasets / papers / Spaces. |

### Cron

```sh
pasclaw cron list
pasclaw cron add daily-summary "0 9 * * *" summarize "workspace/memory"
pasclaw cron add ping-discord "*/15 * * * *" healthcheck "--channel discord:https://discord.com/api/webhooks/..."
pasclaw cron add line-status "0 * * * *" status_skill "--channel line:U1234abcd"
pasclaw cron disable daily-summary
pasclaw cron enable daily-summary
pasclaw cron remove daily-summary
```

Each cron entry persists its last successful fire time to `$PASCLAW_HOME/workspace/cron/state.json` so a missed slot (gateway down, laptop closed) catches up on the next tick instead of being silently skipped. Delivery is **at-least-once**: the state file is written after the skill runs (`PasClaw.Cron.Scheduler.pas:175` runs the skill, `:196` persists the timestamp), so a crash between those two steps will replay the job on restart. Idempotent skills are safe; side-effecting skills (sending emails, posting to channels) should self-deduplicate. Skill output is appended to `workspace/memory/<today>.md` for the model to recall on subsequent turns, and — if `--channel <kind>:<target>` was set — posted to the configured channel. Channel kinds: `discord`, `slack`, `teams`, `webhook` (URL is the target), `line` (target is userId, token from `$PASCLAW_LINE_TOKEN`), `whatsapp` (target is phone number, credentials from `$PASCLAW_WHATSAPP_TOKEN` + `$PASCLAW_WHATSAPP_PHONE_ID`).

### Sessions

```sh
pasclaw agent --session 20260601T093015-1a2b3c4d   # resume by id (creates fresh if absent)
pasclaw resume 20260601T093015-1a2b3c4d            # shorthand for the above

pasclaw session list                # id, age, title, msg count for every saved session
pasclaw session show <id>           # metadata + last 8 messages (head trimmed)
pasclaw session export <id>         # raw JSON to stdout (pipe through `jq`)
pasclaw session delete <id>         # remove the session file
```

Sessions live as one JSON file per id under `$PASCLAW_HOME/workspace/sessions/<id>.json`. The file carries the full `messages` array (role / content / name / tool_call_id / tool_calls), the model + provider + title in `meta`, and any `system_prompt_override` left behind by `/compact`. `pasclaw agent` saves after each turn (atomic `.tmp` → rename), so killing the process mid-conversation is safe — `pasclaw resume <id>` picks up exactly where it stopped. `/new` inside an interactive session spawns a new id; `/reset` clears history in place and keeps the same id; `/compact` is persisted before returning to the prompt so a summariser pass survives an immediate `/quit`. The Delphi build of `pasclaw tui` uses the same store (session list pane reads `ListSessions`, the chat pane operates against the loaded `TSession.Messages`); the FPC build of `pasclaw tui` stays in-memory.

### Web search

Two tools, both registered automatically alongside the filesystem and shell tools:

- **`web_search(query, k?)`** — returns up to k results as title + URL + snippet. Dispatches to the configured provider; defaults to DuckDuckGo when nothing is set.
- **`web_fetch(url, max_chars?)`** — fetches an `http://` or `https://` URL and returns the response body as readable plain text (HTML tags stripped, entities decoded, whitespace collapsed, capped at 50 KB by default).

Provider is set under `web_search` in `~/.pasclaw/config.json`:

```json
{
  "web_search": {
    "provider":    "brave",
    "api_key":     "",
    "max_results": 5
  }
}
```

| Provider | API key needed? | Source |
|---|---|---|
| `duckduckgo` (default) | no | HTML scrape of `html.duckduckgo.com/html/` |
| `brave` | yes — `$PASCLAW_BRAVE_API_KEY` overrides `api_key` | `api.search.brave.com/res/v1/web/search` |
| `tavily` | yes — `$PASCLAW_TAVILY_API_KEY` overrides `api_key` | `api.tavily.com/search` |
| `searxng` | no (most public instances); optional `$PASCLAW_SEARXNG_API_KEY` for protected ones | `<web_search.base_url>/search?format=json` |
| `perplexity` | yes — `$PASCLAW_PERPLEXITY_API_KEY` overrides `api_key` | `api.perplexity.ai/chat/completions` (Sonar model — returns one synthesised answer plus citation URLs) |
| `gemini` | yes — `$PASCLAW_GEMINI_API_KEY` (or `$PASCLAW_GOOGLE_API_KEY`) overrides `api_key` | `generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent` with `google_search` grounding — returns one synthesised answer plus the ground-truth source URLs Gemini consulted |

Env-var values win over the `api_key` field so secrets can stay out of `config.json`. SearXNG additionally needs `web_search.base_url` set since every instance is self-hosted (e.g. `"base_url": "https://searx.be"`).

### Skills

A skill is a markdown manifest under `$PASCLAW_HOME/workspace/skills/`. The system prompt lists each installed skill (name + one-line description + path); the model reads the full body with `fs_read` when a matching task comes up. Skills tagged `kind: shell` or `kind: prompt` also register as a callable `skill_<name>` tool.

```sh
pasclaw skills list
pasclaw skills install owner/repo                         # GitHub repo root
pasclaw skills install owner/repo/path/to/skill           # GitHub subdirectory
pasclaw skills install owner/repo/path/to/skill@v1.2.3    # GitHub at a pinned ref
pasclaw skills install clawhub:code-review                # ClawHub: latest version
pasclaw skills install clawhub:code-review@1.2.3          # ClawHub: pinned version
pasclaw skills search "code review"                       # ClawHub: search the registry
pasclaw skills install my-skill                           # Legacy: record name in config.json
pasclaw skills remove my-skill                            # Delete workspace dir + config entry
```

#### On-disk layout

PasClaw accepts two layouts:

- **Per-directory `SKILL.md`** (preferred — same format picoclaw, nanobot, ClawHub, and Anthropic agent-skills use):

  ```
  workspace/skills/my-skill/
  └── SKILL.md     ← YAML frontmatter + markdown body
  ```

  ```yaml
  ---
  name: my-skill
  description: One-line summary the model uses to pick the skill
  # Omit `kind` for knowledge-only skills (most common); set `kind: shell`
  # or `kind: prompt` to register a callable `skill_<name>` tool.
  ---

  # My skill

  Markdown body. The system prompt advertises this SKILL.md path; the
  model loads the full body with `fs_read` when the matching task comes
  up.
  ```

  A copy-pasteable starter lives at [`samples/skills/hello/SKILL.md`](samples/skills/hello/SKILL.md).

- **Legacy single `*.json`** (`workspace/skills/<name>.json`) — still loaded for backwards compat. Per-directory `SKILL.md` entries shadow same-named JSON entries; new skills should use the directory layout. The JSON shape mirrors the frontmatter:

  ```json
  {
    "name": "my-skill",
    "description": "One-line summary the model uses to pick the skill",
    "kind": "shell",
    "schema": "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}"
  }
  ```

  `kind` and `schema` are only needed for callable skills; knowledge-only skills carry just `name` + `description`.

#### Install from GitHub

`pasclaw skills install owner/repo[/path][@ref]`:

- Fetches a zip snapshot from `codeload.github.com`.
- Extracts it via the bundled zip library — `Zipper.TUnZipper` under FPC, `System.Zip.TZipFile` under Delphi. No tar dependency.
- Locates `SKILL.md` at the requested subpath and validates it through `ParseSkillMD`.
- Copies the containing directory tree into `$PASCLAW_HOME/workspace/skills/<dest>/`, where `<dest>` is the last segment of the subpath, or the repo name when no subpath was given.
- When `@ref` is omitted, tries `main` first and falls back to `master`.
- Refuses to overwrite an existing skill directory — run `pasclaw skills remove <name>` first to reinstall.

#### Install from ClawHub

`pasclaw skills install clawhub:<slug>[@<version>]` talks to ClawHub (`https://clawhub.ai`), the slug-based registry picoclaw and nanobot standardised on:

- `GET /api/v1/skills/<slug>` — fetches metadata, surfaces moderation flags, and resolves `latestVersion` when no `@<version>` is pinned.
- `GET /api/v1/download?slug=<slug>&version=<version>` — pulls the zip, then runs it through the same `PasClaw.Skills.Zip` + `ParseSkillMD` validation pipeline as the GitHub install path.
- Malware-flagged skills are refused; skills flagged as suspicious install with a warning.
- Slugs are lowercase alphanumerics with `-` or `_`.
- The `clawhub:` prefix is required. A bare slug-shaped name like `my-skill` still falls through to the legacy `config.json`-only record, so pre-Phase-3 install scripts keep working unchanged.

`pasclaw skills search <query>` hits `/api/v1/search` and prints slug / version / display-name / summary rows.

Subsequent phases will add `scripts/` (callable helpers) + `references/` (lazy-loaded context) runtime support.

### Gateway, OpenAI-compatible server, and channels

```sh
pasclaw gateway
pasclaw gateway --addr 0.0.0.0 --port 8088
pasclaw gateway --telegram --token <BOT_TOKEN>
pasclaw gateway --line                              # also pass $PASCLAW_LINE_TOKEN + $PASCLAW_LINE_SECRET
pasclaw gateway --whatsapp                          # also pass $PASCLAW_WHATSAPP_{TOKEN,PHONE_ID,VERIFY_TOKEN,APP_SECRET}
pasclaw gateway --matrix                            # also pass $PASCLAW_MATRIX_HOMESERVER + $PASCLAW_MATRIX_TOKEN
pasclaw gateway --irc                               # also pass $PASCLAW_IRC_{SERVER,NICK,CHANNEL}
pasclaw gateway --no-tools --no-mcp --no-hashline

pasclaw serve
pasclaw serve --addr 0.0.0.0 --port 8088
pasclaw serve --debug
pasclaw serve --max-iter 40
pasclaw serve --no-tools --no-mcp --no-hashline
```

Both commands use the same `TGatewayServer` implementation. `gateway` starts the full surface and can also run the Telegram long-poll channel. `serve` is a focused wrapper for OpenAI-compatible clients and prints copy-pasteable client configuration.

OpenAI-compatible client example:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8088/v1", api_key="sk-pasclaw")
response = client.chat.completions.create(
    model="claude-opus-4-7",
    messages=[{"role": "user", "content": "hello"}],
)
print(response.choices[0].message.content)
```

Curl examples:

```sh
curl http://127.0.0.1:8088/v1/health
curl http://127.0.0.1:8088/v1/tools
curl http://127.0.0.1:8088/v1/chat \
  -H 'Content-Type: application/json' \
  -d '{"message":"hello"}'
curl http://127.0.0.1:8088/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-7","messages":[{"role":"user","content":"hello"}]}'
curl http://127.0.0.1:8088/v1/responses \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-7","input":"hello"}'
```

The gateway routes implemented in `src/pkg/gateway/` are:

| Route | Method | Purpose |
|-------|--------|---------|
| `/` | `GET` | Embedded single-page web UI from `src/pkg/gateway/webui.html`. Tabs for chat (with streaming + tool-call rendering + localStorage session history), memory browser, file browser, MCP servers, cron entries, skills, log tail (SSE), and a read-only config viewer. |
| `/v1` | `GET` | JSON index listing gateway routes. |
| `/v1/health` | `GET` | Health check with PasClaw version. |
| `/v1/version` | `GET` | Version and build metadata. |
| `/v1/status` | `GET` | Default provider/model plus provider, MCP, cron, skill, and tool counts. |
| `/v1/tools` | `GET` | Registered tool descriptors. |
| `/v1/mcp` | `GET` | Configured MCP servers (`name`, `cmd`, `args`, `enabled`). |
| `/v1/cron` | `GET` | Cron entries (`id`, `spec`, `skill`, `args`, `channel_*`, `enabled`). |
| `/v1/skills` | `GET` | Installed skills (`name`, `description`, `kind`, `path`, `dir`). |
| `/v1/memory` | `GET` | Files in `workspace/memory/` with sizes. |
| `/v1/memory/<name>` | `GET` | Contents of one memory file (rejects path-traversal). |
| `/v1/config` | `GET` | Full config with `providers[].api_key` masked to `•••`. |
| `/v1/fs?path=…` | `GET` | Directory listing (entries + sizes + dir-flag); defaults to `$PASCLAW_HOME`. |
| `/v1/fs/read?path=…` | `GET` | File contents capped at 256 KB; `truncated` flag on response. |
| `/v1/logs` | `GET` | SSE tail of the gateway log buffer (1000-entry ring); recent buffer dumps first, then live. |
| `/v1/chat` | `POST` | PasClaw JSON chat endpoint accepting `{"message":"..."}`. |
| `/v1/chat/completions` | `POST` | OpenAI Chat Completions-compatible endpoint; supports streaming with `stream: true`. |
| `/v1/responses` | `POST` | OpenAI Responses-compatible endpoint accepting string or message-array `input`; non-streaming only. |
| `/v1/models` | `GET` | OpenAI-compatible model list containing the configured default model. |

When `/v1/chat/completions` runs with `stream: true`, the tool loop executes
server-side and each tool call is surfaced to the client as a visible
content delta in a Claude-Code-style transcript — the tool name with its key
argument, followed by a short result summary on the next line:

```
⏺ fs_read(README.md)
  ⎿ 312 lines, 12044 bytes — ¶README.md#a1b2
⏺ shell_exec(ls -la)
  ⎿ exit=0
```

Known tools (`fs_read`, `fs_write`, `fs_list`, `fs_grep`,
`fs_edit_hashline`, `shell_exec`, `memory_search`, `web_search`, `web_fetch`)
surface their most meaningful argument;
MCP and other tools fall back to a compact one-line dump of the raw
arguments. The full argument and result text also go to the SSE comment
lines (`: tool_call ...` / `: tool_result ...`) for consumers that log
structured activity, and to the server debug log when `--debug` is set.
The formatter lives in `src/pkg/gateway/PasClaw.Gateway.ToolView.pas`
(unit-tested via `make test-toolview`).

Manual `/v1/responses` verification examples:

```sh
# string input
curl http://127.0.0.1:8088/v1/responses \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-7","input":"hello"}'

# message-array input
curl http://127.0.0.1:8088/v1/responses \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-7","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}'

# missing or empty input should return invalid_request_error
curl http://127.0.0.1:8088/v1/responses \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-7","input":""}'

# streaming is intentionally unsupported on this route
curl http://127.0.0.1:8088/v1/responses \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-7","input":"hello","stream":true}'
```

Channel posting commands:

```sh
pasclaw post discord <webhook-url> "hello"
pasclaw post slack <webhook-url> "hello"
```

### Embedding in your own app

`TPasClawAgent` (unit `PasClaw.Agent`) is a `TComponent` you can drop on a form or instantiate from code to embed the full agent — provider auth, tools, MCP, skills — inside a standalone Delphi or FPC binary, without shelling out to the CLI.

Code-driven (one-liner) form:

```pascal
uses PasClaw.Agent, PasClaw.Tools;

var
  Agent: TPasClawAgent;
begin
  Agent := TPasClawAgent.Create('claude-opus-4-7');
  try
    Agent.SetProvider('anthropic', GetEnvironmentVariable('ANTHROPIC_API_KEY'));
    Agent.RegisterTool(TWebSearchTool.Create);
    Agent.RegisterTool(TWebFetchTool.Create);
    Agent.RegisterTool(TFileSystemTool.Create);
    WriteLn(Agent.Run('Summarize the latest Delphi release notes.'));
  finally
    Agent.Free;
  end;
end;
```

`SetProvider(Kind, APIKey)` builds a `TProviderConfig` in-memory from the catalog entry for `Kind` (`anthropic`, `openai`, `gemini`, `groq`, `ollama`, etc. — see `PasClaw.Providers.Catalog`) plus the API key the caller hands in. The catalog supplies the default base URL and default model; both can be overridden via the three-arg and four-arg `SetProvider` overloads. This lets an embedded binary run without ever touching `~/.pasclaw/config.json` — set the env var, ship the binary, done.

`Run` raises `EPasClawRun` on failure; use `Chat(prompt, reply, err): Boolean` when you'd rather not unwind exceptions. `RegisterTool` takes ownership of the `TPasClawTool` instance and frees it with the agent.

Form-designer / property-driven form (back-compat — `Create(nil)`, set published properties, wire events):

```pascal
PC := TPasClawAgent.Create(nil);
PC.Model       := 'claude-opus-4-7';
PC.SystemPrompt := 'You are a Pascal expert.';
PC.OnText := MyTextHandler;
if PC.Chat('hi', Reply, Err) then WriteLn(Reply);
```

Built-in tools available as classes: `TWebSearchTool`, `TWebFetchTool`, `TFileSystemTool` (bundle: fs_read/write/grep/list/edit), `TShellTool`, `TMemoryTool`. Custom tools subclass `TPasClawTool` (unit `PasClaw.Tools.Obj`) and override `Name` / `Description` / `Schema` / `Run`.

`TPasClawServer` (same unit) hosts the full HTTP gateway inside the calling process. Same OOP shape as `TPasClawAgent`:

```pascal
uses PasClaw.Agent, PasClaw.Tools;

var
  Server: TPasClawServer;
begin
  Server := TPasClawServer.Create('0.0.0.0', 8088);
  try
    Server.SetProvider('anthropic', GetEnvironmentVariable('ANTHROPIC_API_KEY'));
    Server.RegisterTool(TWebSearchTool.Create);
    Server.Run;  { blocks until Stop is signalled from another thread }
  finally
    Server.Free;
  end;
end;
```

`SetProvider` works the same way as on `TPasClawAgent` — call it before `Start` and the gateway boots with the in-memory provider config.

`Run` does `Start + WaitForStop` in one call and raises `EPasClawRun` if startup fails. Use `Start` / `WaitForStop` / `Stop` separately when you need to do something between binding the socket and entering the wait. SIGINT handling is the embedder's problem — most hosting apps already have their own signal-handling strategy, so the component doesn't install one.

`samples/component-console/` ships three sample binaries:

```sh
cd samples/component-console
make get-indy   # only needed once, from repo root
make            # builds all three (SampleConsole, SampleSimple, SampleServer)
make simple     # just the agent code-form sample
make server     # just the server sample
```

`PasClaw.Component` is still available as the legacy unit name — it now re-exports everything from `PasClaw.Agent`, so existing code keeps compiling.

### Maintenance and diagnostics

```sh
pasclaw status
pasclaw version
pasclaw migrate
pasclaw update --check
pasclaw update --repo owner/name
pasclaw membench --records 1000 --content 128
pasclaw membench --records 1000 --content 128 --keep --out /tmp
```

## Providers

Provider definitions live in `src/pkg/providers/PasClaw.Providers.Catalog.pas`. `pasclaw onboard` uses the catalog to populate provider `kind`, default API base URL, default model, and auth scheme.

Implemented protocol families:

- `pfAnthropic`: Anthropic Messages API using `x-api-key`.
- `pfOpenAI`: OpenAI Chat Completions-compatible HTTP API. This powers OpenAI and most compatible hosted/local providers.
- `pfGemini`: Google Gemini `generateContent` REST API using `x-goog-api-key`.
- `pfPlaceholder`: catalog placeholder for known future provider families that are not wired into this build.

Auth schemes:

- `asBearer`: `Authorization: Bearer <key>`.
- `asNone`: no auth header, used for local Ollama/vLLM deployments.
- `asHeader`: raw key in the catalog-specified header name.

Current catalog entries:

| Provider | `kind` | Family | Default base | Default model | Auth |
|----------|--------|--------|--------------|---------------|------|
| Anthropic | `anthropic` | Anthropic | `https://api.anthropic.com` | `claude-opus-4-7` | `x-api-key` header |
| OpenAI | `openai` | OpenAI-compatible | `https://api.openai.com` | `gpt-4o-mini` | Bearer |
| OpenRouter | `openrouter` | OpenAI-compatible | `https://openrouter.ai/api` | provider-selected | Bearer |
| Zhipu (GLM) | `zhipu` | OpenAI-compatible | `https://open.bigmodel.cn/api/paas` | `glm-4` | Bearer |
| DeepSeek | `deepseek` | OpenAI-compatible | `https://api.deepseek.com` | `deepseek-chat` | Bearer |
| Volcengine (Doubao/Ark) | `volcengine` | OpenAI-compatible | `https://ark.cn-beijing.volces.com/api` | provider-selected | Bearer |
| Qwen (DashScope) | `qwen` | OpenAI-compatible | `https://dashscope.aliyuncs.com/compatible-mode` | `qwen-max` | Bearer |
| Groq | `groq` | OpenAI-compatible | `https://api.groq.com/openai` | provider-selected | Bearer |
| Moonshot (Kimi) | `moonshot` | OpenAI-compatible | `https://api.moonshot.cn` | `moonshot-v1-32k` | Bearer |
| MiniMax | `minimax` | OpenAI-compatible | `https://api.minimax.chat` | provider-selected | Bearer |
| Mistral | `mistral` | OpenAI-compatible | `https://api.mistral.ai` | `mistral-large-latest` | Bearer |
| NVIDIA NIM | `nvidia` | OpenAI-compatible | `https://integrate.api.nvidia.com` | provider-selected | Bearer |
| Cerebras | `cerebras` | OpenAI-compatible | `https://api.cerebras.ai` | provider-selected | Bearer |
| Novita AI | `novita` | OpenAI-compatible | `https://api.novita.ai` | provider-selected | Bearer |
| Xiaomi MiMo | `mimo` | OpenAI-compatible | set `api_base` in config | provider-selected | Bearer |
| Ollama (local) | `ollama` | OpenAI-compatible | `http://localhost:11434` | required during onboarding | none |
| vLLM (local) | `vllm` | OpenAI-compatible | `http://localhost:8000` | required during onboarding | none |
| LiteLLM proxy | `litellm` | OpenAI-compatible | set `api_base` in config | provider-selected | Bearer |
| Google Gemini | `gemini` | Gemini | `https://generativelanguage.googleapis.com` | `gemini-1.5-flash` | `x-goog-api-key` header |

Minimal local provider examples:

```json
{
  "default_provider": "ollama",
  "default_model": "llama3.1:8b",
  "gateway": { "log_level": "info", "bind_addr": "127.0.0.1", "port": 8088 },
  "providers": [
    {
      "name": "ollama",
      "kind": "ollama",
      "api_base": "http://localhost:11434",
      "api_key": "",
      "model": "llama3.1:8b"
    }
  ],
  "mcp_servers": [],
  "crons": [],
  "skills": []
}
```

```json
{
  "default_provider": "vllm",
  "default_model": "your-model",
  "gateway": { "log_level": "info", "bind_addr": "127.0.0.1", "port": 8088 },
  "providers": [
    {
      "name": "vllm",
      "kind": "vllm",
      "api_base": "http://localhost:8000",
      "api_key": "",
      "model": "your-model"
    }
  ],
  "mcp_servers": [],
  "crons": [],
  "skills": []
}
```

## 🔒 Security / sandbox

PasClaw's filesystem and shell tools are guarded by an opt-in workspace boundary plus an always-on shell denylist (`src/pkg/tools/PasClaw.Tools.Sandbox.pas`). Configure via the `sandbox` block in `~/.pasclaw/config.json`:

```json
"sandbox": {
  "restrict_to_workspace":        true,
  "allow_read_outside_workspace": false,
  "workspace":                    "/home/me/my-project",
  "allow_read_paths":  ["^/usr/(include|share)/.*"],
  "allow_write_paths": ["^/tmp/agent/.*"],
  "custom_shell_deny": ["scp ", "rsync "],
  "shell_deny_enabled":           true
}
```

| Field | Default | Effect |
|---|---|---|
| `restrict_to_workspace` | `false` | When `true`, `fs_read` / `fs_write` / `fs_list` / `fs_edit_hashline` / `fs_grep` refuse paths outside `workspace`. `shell_exec` refuses absolute paths outside it AND tokens containing `..`, pins the shell's cwd to the workspace, and bans `cd` / `chdir` / `pushd` / `popd`. |
| `allow_read_outside_workspace` | `false` | When `true`, reads are allowed anywhere even while writes stay restricted. Useful for letting the agent pull from `/usr/include/` while still locking down writes. |
| `workspace` | `""` (cwd at startup) | Absolute path the agent may operate inside. Empty means "use the current working directory at the time `pasclaw` was invoked", which is the picoclaw / Claude Code convention. |
| `allow_read_paths` | `[]` | **PCRE regex** patterns that *also* count as readable. Same syntax picoclaw's `tools.allow_read_paths` accepts — anchors (`^` `$`), character classes, alternation. |
| `allow_write_paths` | `[]` | Same for writes. |
| `custom_shell_deny` | `[]` | Extra substrings appended to the built-in shell denylist. Case-insensitive. |
| `shell_deny_enabled` | `true` | Master switch for the shell denylist. Set `false` only for trusted automation — doing so re-enables `sudo`, `rm`, `dd`, `mkfs`, `$( )`, `curl \| sh`, `format c:`, PowerShell `-EncodedCommand`, etc. |
| `block_private_networks` | `true` | When `true`, `web_fetch` refuses URLs whose host resolves to a private / loopback / link-local IPv4 address (RFC1918, `127.0.0.0/8`, `169.254.0.0/16` — including the cloud-metadata endpoint `169.254.169.254`, CGNAT, IETF-reserved). Initial URL and every redirect hop are both checked. Flip to `false` only when you actually need the model to reach private addresses. See `PasClaw.Net.SSRF` for the full blocklist. |

**Cross-target regex**: `PasClaw.Tools.Regex` wraps FPC's `RegExpr` and Delphi's `System.RegularExpressions` behind one call, so `allow_*_paths` patterns are full PCRE on either toolchain. Invalid patterns return False (the sandbox falls through to the workspace boundary) rather than crashing.

**Built-in shell denylist** (always on unless `shell_deny_enabled` is false):

- **POSIX tokens**: `sudo`, `su`, `rm`, `chmod`, `chown`, `pkill`, `killall`, `kill`, `shutdown`, `reboot`, `poweroff`, `halt`, `eval`, `mkfs`, `diskpart`.
- **Windows tokens**: `del`, `erase`, `rd`, `rmdir`, `format`, `attrib`, `takeown`, `icacls`, `runas`.
- **cwd-change tokens** (when `restrict_to_workspace`): `cd`, `chdir`, `pushd`, `popd`. Any token containing `..` is also rejected.
- **Substrings**: `dd if=`, `:(){:|`, `<<EOF`, `$( )`, `${ }`, backticks, `| sh`, `| bash`, `apt install/remove/purge`, `yum install/remove`, `dnf install/remove`, `npm install -g`, `pip install --user`, `docker run/exec`, `git push`, `git force`, `format c:`.
- **PowerShell** (matched lowercased): `powershell -e/-en/-enc/-ec`, `-encodedcommand`, `iex (`, `invoke-expression`, `[convert]::frombase64`, `[text.encoding]`, `.getstring([byte[]`, `set-executionpolicy`.
- **Device writes**: `> /dev/sd*` / `/hd*` / `/vd*` / `/xvd*` / `/nvme*` / `/mmcblk*` / `/loop*` / `/md*`.
- **Always-safe paths**: `/dev/null`, `/dev/zero`, `/dev/{,u}random`, `/dev/std{in,out,err}` — picoclaw's `safePaths`.

**Workspace-pin**: when `restrict_to_workspace=true`, `Tool_Shell` invokes `RunOneShot` with `WorkingDir = workspace` so the child shell starts inside the boundary. Combined with the `cd` token ban and `..` traversal check, a sandboxed model has no relative-path escape — even if a future denylist gap let a command through, the shell still starts in the workspace, not wherever `pasclaw` was launched from.

**Known limitation**: path canonicalisation uses `ExpandFileName`, which resolves `..` but not symlinks. Picoclaw's equivalent (`os.OpenRoot` in Go 1.24+) enforces the boundary at the syscall layer; PasClaw runs on FPC and Delphi RTLs that have no equivalent. **Do not place symlinks inside `workspace` that point outside it** — they would let the agent escape.

**`--no-tools`** remains the strongest option: it disables the tool registry entirely, so neither `fs_*` nor `shell_exec` is registered. The system prompt automatically reflects this (no SKILLS section, no "ALWAYS use tools" rule).

## Repository layout

```text
src/
  pasclaw/          Program entry point (`PasClaw.dpr`)
  cmd/              CLI command units and root dispatcher
  pkg/
    agent/          Agent execution and prompts
    channels/       Telegram, Discord, Slack, Teams, generic webhook, LINE, WhatsApp, Matrix, IRC
    cliui/          ANSI styling, banner, command help rendering
    component/      Shared components
    config/         Version constants and on-disk config model
    cron/           Cron scheduler
    gateway/        Indy HTTP server, OpenAI-compatible API, embedded web UI
    hashline/       Hashline patch/edit support
    json/           Project JSON abstraction
    logger/         Levelled logging
    mcp/            MCP stdio/HTTP clients and tool bridge
    membench/       Memory benchmark helpers
    memory/         Memory log storage
    net/            SSRF guard (IPv4 blocklist + DNS re-resolution)
    platform/       Platform helpers
    providers/      Provider catalog and LLM HTTP clients
    search/         Web-search providers (DuckDuckGo, Brave, Tavily, SearXNG, Perplexity, Gemini) + HTML→text
    skills/         Skill manifest loading and tool registration
    tokenizer/      Token counting helpers
    tools/          Built-in tool registry, filesystem, shell, and tool loop
    tui/            Full-screen terminal UI
    updater/        GitHub release update support
    utils/          Path, file, and string helpers
```

## License

MIT. See `LICENSE`.
