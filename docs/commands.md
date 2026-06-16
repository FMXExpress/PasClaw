# Commands

Top-level commands are dispatched by `src/cmd/PasClaw.Cmd.Root.pas`. Run `pasclaw --help` for the live listing; this page is the authoritative reference.

## Global flags

| Flag | Effect |
|---|---|
| `--no-color` (or `NO_COLOR=1`) | Disable ANSI colour output. |
| `--quiet` / `-q` | Suppress the banner, agent-loop decorations, and clamp the logger to `error`. Designed for Replicate / Lambda / curl pipelines that want only the model's reply on stdout. See [Getting started](./getting-started.md#first-chat). |
| `-h` / `--help` | Print help. |

## Command list

| Command | Purpose |
|---------|---------|
| [`config`](#config) | View or reset the JSON configuration. |
| [`onboard`](#onboard) | Initialise `$PASCLAW_HOME`, workspace folders, and provider settings. |
| [`agent`](#agent) | Chat with the assistant (interactive or one-shot). |
| [`tui`](#tui) | Chat in the full-screen TUI. |
| [`auth`](#auth) | Store, clear, or inspect provider API keys. |
| [`gateway`](#gateway) | Start the HTTP gateway, embedded web UI, cron, and optional channels. |
| [`serve`](#serve) | Start a focused OpenAI-compatible API server. |
| [`status`](#status) | Show provider, model, gateway, MCP, cron, and skill status. |
| [`cron`](#cron) | Manage scheduled tasks. |
| [`mcp`](#mcp) | Manage MCP server entries. |
| [`migrate`](#migrate) | Run data migrations for older versions. |
| [`skills`](#skills) | List, install, search, or remove skills. |
| [`vault`](#vault) | Search / fetch / install pasclaw.dev Code Vault entries. |
| [`model`](#model) | Show, set, add, or refresh model entries. |
| [`post`](#post) | Send a one-shot message to a channel. |
| [`membench`](#membench) | Benchmark the memory log subsystem. |
| [`memory`](#memory) | Provision the hybrid `memory_search` runtime. |
| [`kb`](#kb) | Manage the knowledgebase (RAG corpus). |
| [`learn`](#learn) | Mine sessions for recurring tool failures. |
| [`export`](#export) | Render PasClaw state into agent-runtime rules files. |
| [`init`](#init) | Scan cwd + ask the model for a starter `AGENTS.md` (one-shot, no tool loop). |
| [`runbook`](#runbook) | Tool-driven variant of `init`: agent loop probes the repo via `execute_code`. |
| [`session`](#session) | List, show, delete, export saved sessions. |
| [`resume`](#resume) | Alias: `agent --session <id>`. |
| [`steer`](#steer) | Push a mid-loop follow-up into a running agent. |
| [`heartbeat`](#heartbeat) | Run the periodic wake-up daemon. |
| [`update`](#update) | Check or self-update from GitHub releases. |
| [`version`](#version) | Show version and build info. |

---

## config

```sh
pasclaw config                   # print the current JSON
pasclaw config path              # print the resolved config path
pasclaw config reset             # write a default config
```

See [Configuration](./configuration.md) for the full schema.

## onboard

```sh
pasclaw onboard
```

Interactive setup wizard. Idempotent: re-running preserves any keys you've set out of band.

## agent

```sh
pasclaw agent                                               # interactive
pasclaw agent -m "hello"                                    # one-shot
pasclaw agent --model claude-opus-4-7 --provider anthropic -m "..."
pasclaw agent --system "Be concise" --thinking medium \
              --max-tokens 2048 --max-iterations 25
pasclaw agent --no-tools --no-mcp --no-hashline
pasclaw agent --session 20260601T093015-1a2b3c4d            # resume by id
pasclaw agent --quiet -m "..."                              # machine-readable
pasclaw agent --backend docker -m "..."                     # per-run override
pasclaw agent --plan -m "review the gateway auth flow"      # read-only Plan mode
pasclaw agent --mode build -m "..."                         # full-access (default)
```

Persists conversation history to `$PASCLAW_HOME/workspace/sessions/<id>.json` after every turn by default. Interactive slash commands: `/help`, `/status`, `/new`, `/reset`, `/compact`, `/think`, `/tools`, `/mode [plan|build]`, `/steer <msg>`, `/quit`. See [Sessions](./sessions.md).

### Plan / Build mode

Two operator-facing modes that gate the tool surface:

- **`build`** (default) — full tool access; every registered tool dispatches normally. Historical behaviour.
- **`plan`** — read-only. Tools categorised as mutating (`fs_write`, `fs_edit_hashline`, `shell_exec`, `execute_code`, `delphi_build`, `send_message`, `web_fetch`, `memory_fetch`, `skills_manage`, `kb_upload`, …) are refused at the dispatch layer with a `refused: tool "X" needs build mode` message; read-only tools (`fs_read`, `fs_list`, `fs_grep`, `memory_search`, `kb_search`, `web_search`, `vault_search`, `vault_get`, `session_search`, `skills_list`, `skills_view`, …) work normally. Note: `web_fetch` and `memory_fetch` are mutating because their `save_to` path writes to the workspace; for a pure URL read, use the search tools or switch to Build. The model is also told it is in plan mode in the system prompt so it produces analysis rather than attempting refused tools.

Mode plumbing per surface:

| Surface | How to switch |
|---|---|
| CLI | `--mode plan\|build`, or the short forms `--plan` / `--build`. In the interactive REPL: `/mode plan`, `/mode build`, or bare `/mode` to show the current value. |
| TUI | **Ctrl-B** cycles Plan ↔ Build (works in either pane). Tab still swaps focus between the session list and chat. A `[plan]` / `[build]` badge in the header bar shows the current value. Slash commands also work: `/mode`, `/mode plan`, `/mode build`. |
| Web UI | The **🛠 build / 📋 plan** toggle in the top nav; per-tab, persisted in `localStorage`. |
| `/v1/chat`, `/v1/chat/completions`, `/v1/responses` | Optional `"mode": "plan"` (or `"build"`) field in the JSON request body. Absent / unknown values default to `build` so existing OpenAI-compatible clients keep working unchanged. |

## tui

```sh
pasclaw tui
pasclaw tui --session 20260601T093015-1a2b3c4d
pasclaw tui --provider openai --model gpt-4o-mini
pasclaw tui --theme matrix
```

Full-screen terminal UI. **Delphi build**: positioned two-pane (`MVCFramework.Console`-backed) — session list on the left, chat history + input on the right. **Tab** swaps focus; in the session pane **Up/Down** navigates, **Enter** loads, **N** new session, **D** then **Y** deletes, **R** refreshes. Background-thread turn runs (UI keeps redrawing). `/theme`, `/model`, `/stats` modals. **FPC build** stays on the original line-based ANSI renderer (no session list pane yet).

## auth

```sh
pasclaw auth status
pasclaw auth login anthropic
pasclaw auth logout anthropic
```

The fallback provider chain is set by editing the `fallbacks` array in `config.json` directly (`"fallbacks": ["openai", "gemini"]`).

Prompts for an API key and stores it in the matching provider entry. See [Providers](./providers.md).

## gateway

```sh
pasclaw gateway
pasclaw gateway --addr 0.0.0.0 --port 8088
pasclaw gateway --telegram --token <BOT_TOKEN>
pasclaw gateway --line                              # also $PASCLAW_LINE_TOKEN + $PASCLAW_LINE_SECRET
pasclaw gateway --whatsapp                          # also $PASCLAW_WHATSAPP_{TOKEN,PHONE_ID,VERIFY_TOKEN,APP_SECRET}
pasclaw gateway --matrix                            # also $PASCLAW_MATRIX_HOMESERVER + $PASCLAW_MATRIX_TOKEN
pasclaw gateway --irc                               # also $PASCLAW_IRC_{SERVER,NICK,CHANNEL}
pasclaw gateway --email                             # SMTP send + IMAP poll
pasclaw gateway --mcp-port 9090                     # spawn a second MCP-only listener
pasclaw gateway --no-tools --no-mcp --no-hashline
```

Discord and Slack are currently outbound-only via `pasclaw post discord <url> "..."` / `pasclaw post slack <url> "..."` and the `send_message` model-facing tool — no `--discord` / `--slack` flag on the gateway yet.

Starts the full surface: HTTP server, embedded web UI, OpenAI-compatible endpoints, cron, optional chat-channel bots. See [Gateway and OpenAI-compatible API](./gateway.md) for the route table and [Channels](./channels.md) for channel wiring.

## serve

```sh
pasclaw serve
pasclaw serve --addr 0.0.0.0 --port 8088
pasclaw serve --debug
pasclaw serve --max-iter 40
pasclaw serve --no-tools --no-mcp --no-hashline
```

Focused wrapper around the same `TGatewayServer` for OpenAI-compatible clients. Prints copy-pasteable client config on startup.

## status

```sh
pasclaw status
```

Prints provider + model + gateway + MCP + cron + skill counts. Read-only.

## cron

```sh
pasclaw cron list
pasclaw cron add daily-summary "0 9 * * *" summarize "workspace/memory"
pasclaw cron add ping-discord "*/15 * * * *" healthcheck "--channel discord:..."
pasclaw cron disable daily-summary
pasclaw cron enable  daily-summary
pasclaw cron remove  daily-summary
```

See [Cron](./cron.md).

## mcp

```sh
pasclaw mcp list
pasclaw mcp add filesystem npx -y @modelcontextprotocol/server-filesystem /tmp
pasclaw mcp add remote https://example.com/mcp
pasclaw mcp show filesystem
pasclaw mcp test filesystem
pasclaw mcp remove filesystem
pasclaw mcp edit

pasclaw mcp catalog                  # curated public MCP servers
pasclaw mcp search <query>           # search the pasclaw.dev hub
pasclaw mcp install <slug>           # install from hub or bundled catalog
```

See [MCP servers](./mcp.md).

## migrate

```sh
pasclaw migrate
```

Re-runs schema upgrades for the memory and session stores. Safe to run any time; idempotent.

## skills

```sh
pasclaw skills list
pasclaw skills install owner/repo                         # GitHub repo root
pasclaw skills install owner/repo/path/to/skill           # GitHub subdirectory
pasclaw skills install owner/repo/path/to/skill@v1.2.3    # GitHub at pinned ref
pasclaw skills install clawhub:code-review                # ClawHub
pasclaw skills install clawhub:code-review@1.2.3
pasclaw skills install my-skill                           # legacy: record name in config.json
pasclaw skills search "code review"                       # ClawHub + pasclaw.dev hub
pasclaw skills remove my-skill
```

See [Skills](./skills.md).

## vault

```sh
pasclaw vault search <query>
pasclaw vault show <slug>
pasclaw vault install <slug> [<dest>]    # git clone into workspace/vault/<slug>
```

`vault_search` and `vault_get` are model-facing tools, registered only when `vault_tools_enabled: true`. See [Tools](./tools.md).

## model

```sh
pasclaw model show
pasclaw model set claude-opus-4-7
pasclaw model add openai gpt-4o-mini
pasclaw model refresh anthropic              # GET /v1/models → cache
pasclaw model refresh --all
pasclaw model list openai
```

## post

```sh
pasclaw post discord  <webhook-url> "hello"
pasclaw post slack    <webhook-url> "hello"
pasclaw post teams    <webhook-url> "hello"
pasclaw post webhook  <url>         "hello"
pasclaw post line     <userId>      "hello"
pasclaw post whatsapp <phone>       "hello"
```

One-shot send to a channel, no agent loop.

## membench

```sh
pasclaw membench --records 1000 --content 128
pasclaw membench --records 1000 --content 128 --keep --out /tmp
```

Benchmark the FTS5 memory log subsystem. `--keep` keeps the generated db file for inspection.

## memory

```sh
pasclaw memory provision     # fetch sqlite-vec + ONNX Runtime + MiniLM into cache/localvector/
pasclaw memory status        # show provisioned artifact state
```

Enables hybrid keyword + vector ranking in `memory_search` and `kb_search`. Gated by `vector_search_enabled`. See [Memory](./memory.md).

## kb

```sh
pasclaw kb add ~/docs/delphi-book.md ~/projects/mylib/
pasclaw kb list
pasclaw kb search "constructor constraints in generics"
pasclaw kb sync
pasclaw kb status
pasclaw kb remove ~/projects/mylib/
```

See [Knowledgebase](./knowledgebase.md).

## learn

```sh
pasclaw learn --min 2 --since 30
pasclaw learn --write           # append a dated block to MEMORY.md
pasclaw learn --write-scars     # also emit SCARS.md with stable §ANCHOR ids
```

Mines `workspace/sessions/*.json` for recurring tool failures, normalises into clustering signatures (paths/pids/hashes stripped), groups by pattern.

## export

```sh
pasclaw export                  # writes AGENTS.md, CLAUDE.md, .cursor/rules/agent.mdc, GEMINI.md, .zed/agent.md
pasclaw export claude           # single target
pasclaw export agents
pasclaw export cursor
pasclaw export gemini
pasclaw export zed
pasclaw export --stdout         # print rendered body instead of writing
pasclaw export --to <dir>
```

Renders MEMORY.md + SCARS.md + skill manifests + sandbox policy into rules files Claude Code / Cursor / Gemini CLI / Zed AI / the cross-runtime AGENTS.md convention already look for. Files carry a `<!-- generated by: pasclaw export -->` marker on the first line — re-runs clobber.

## init

```sh
pasclaw init                    # writes ./AGENTS.md
pasclaw init path/to/proj
pasclaw init --force            # overwrite an existing AGENTS.md
pasclaw init --model gpt-5 --provider openai
```

Scans the working directory in-Pascal (file tree to depth 3, plus first 4 KB of well-known config files: README, package.json, Cargo.toml, Makefile, go.mod, ...), packages it as a digest, and asks the configured model in **one Chat() call** for a starter `AGENTS.md`. No tool loop, no shell exec — the only thing that touches disk is the final `AGENTS.md` write. Fast, trust-minimal, and works against any provider.

PasClaw reads the resulting `AGENTS.md` back into the system prompt at session start (see [`docs/getting-started.md`](getting-started.md#project-rules-agentsmd)). The file follows the cross-tool convention shared by **opencode, Codex, Cursor, Zed AI, and Claude Code** — committing it benefits any agent your collaborators use.

Inside the TUI: `/init` runs the same flow. Pass flags after the slash exactly as on the CLI (`/init --force`, `/init --model gpt-5`).

For a deeper, model-driven probe see [`runbook`](#runbook) below.

## runbook

```sh
pasclaw runbook                 # writes ./AGENTS.md
pasclaw runbook --to ./RUNBOOK.md
pasclaw runbook --force         # overwrite an existing AGENTS.md
```

Tool-driven variant of `init`. Spins the full agent loop with `execute_code` so the **model** runs the probe (`ls -la`, `cat Makefile`, parse package.json, `git log --oneline -10`, etc.) and writes the file via `fs_write`. Produces richer output than `init` because the model can chase whatever the project shape needs; takes longer and requires `shell_exec` to be allowed.

## session

```sh
pasclaw session list                # id, age, title, msg count
pasclaw session show <id>           # metadata + last 8 messages
pasclaw session export <id>         # raw JSON to stdout
pasclaw session delete <id>
```

See [Sessions](./sessions.md).

## resume

```sh
pasclaw resume 20260601T093015-1a2b3c4d
```

Shorthand for `pasclaw agent --session 20260601T093015-1a2b3c4d`.

## steer

```sh
pasclaw steer <session-id> "actually skip X, focus on Y"
pasclaw steer <session-id> --list        # show pending count
pasclaw steer <session-id> --clear       # drop the queue
```

Push a mid-loop follow-up into a running agent. The running agent drains the queue at the top of its NEXT tool-loop iteration and folds each pending message into history as a `[user steering] ...` system note. Up to 4 messages per iteration (`MaxSteeringPerTurn`). Storage: `$PASCLAW_HOME/workspace/steering/<id>.jsonl`. See [Sessions](./sessions.md#mid-loop-steering).

## heartbeat

```sh
pasclaw heartbeat
pasclaw heartbeat --force        # bypass `heartbeat.enabled: false`
```

Polls `workspace/heartbeat.md` every `heartbeat.interval_mins` minutes, runs the agent loop on the body, posts to `heartbeat.channel` if set. Empty / missing file = skip the tick.

## update

```sh
pasclaw update --check
pasclaw update                      # download + replace
pasclaw update --repo owner/name    # override the source repo
```

## version

```sh
pasclaw version
```

Prints version + build commit + FPC/Delphi compiler info.

## Internal subcommands (not in `--help`)

- `pasclaw __tool <name> '<json-args>'` — loopback tool-RPC used by `execute_code` scripts. See [Tools](./tools.md#tool-rpc-callback).
