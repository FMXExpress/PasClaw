# Getting started

This page takes you from "I just cloned the repo" to "the agent is answering me" in a few minutes.

## Prerequisites

- **Free Pascal 3.2+ in Delphi mode**, OR **Delphi / RAD Studio 12+**.
- **Indy** (`TIdHTTP`, `TIdHTTPServer`) for HTTP. Delphi ships it; FPC needs it vendored (see below).
- **OpenSSL** runtime libraries on `PATH` for HTTPS provider / MCP calls.

Optional, only when you use the relevant feature:
- **SQLite** (FTS5 build) for `memory_search` / `session_search` / `kb_*`.
- **Docker** for the docker shell backend (`shell_backend: docker`).
- **`pdftotext`** for indexing PDF docs into the KB (PasClaw does not parse PDFs directly).

## Build

### Delphi / RAD Studio

```bat
build-delphi.bat
```

Or open `src/pasclaw/PasClaw.dproj` in the IDE and hit build. The project file carries all unit-search paths.

### Free Pascal

```sh
make get-indy   # one-time: clones IndySockets/Indy into vendor/Indy
make            # builds build/pasclaw
```

`make` autodetects unit paths for FPC's `fcl-db`, `sqlite`, and Lazarus's `lazutils` (the `Masks` unit). Overrides:

```sh
make FCLDB_DIR=/opt/fpc/units/x86_64-linux/fcl-db \
     SQLITE_DIR=/opt/fpc/units/x86_64-linux/sqlite \
     LAZUTILS_DIR=/usr/lib/lazarus/3.0/components/lazutils
```

Cross-compile for Windows-on-ARM64:

```sh
make CROSS_TARGET=aarch64-win64 \
     FPC_UNITS_DIR=/opt/fpc/units/aarch64-win64 \
     FPC='fpc -Twin64 -Paarch64' \
     BIN=build/pasclaw-arm64.exe
```

In-browser wasm build:

```sh
make C2W=1 browser
```

See [`c2w.md`](./c2w.md) for the container2wasm pipeline.

## First-run setup

```sh
./build/pasclaw onboard
```

The wizard:

1. Creates `$PASCLAW_HOME` (default `~/.pasclaw/`) with the workspace skeleton.
2. Asks which provider you want and prompts for an API key — auto-discovers the live `/v1/models` roster and presents a picker.
3. Optionally enables any of the 5 bundled MCP servers (`replicate`, `digitalocean-apps`, `digitalocean-databases`, `runpod-docs`, `huggingface`).
4. Optionally toggles `vault_tools_enabled`, `vector_search_enabled`, `web_fetch_enabled`, `auto_router.enabled`, `stats_collection_enabled`, the heartbeat daemon, and the docker shell backend.

Re-run any time to change settings; the wizard preserves any keys you set out of band.

## First chat

```sh
pasclaw agent -m "what does this repo do?"          # one-shot, persists nothing
pasclaw agent                                       # interactive, auto-saves under workspace/sessions/
pasclaw tui                                         # full-screen TUI with session list pane (Delphi build)
```

Machine-readable single-turn output (Replicate, Lambda, curl pipelines):

```sh
answer=$(pasclaw agent --quiet -m "ping")
echo "$answer"
```

`--quiet` drops the banner, the `assistant (provider/model):` header, per-tool decoration lines, and the trailing `[tokens in=... out=...]` summary, and clamps the logger to error-level. Exit code is 0 on a successful turn, non-zero on provider misconfiguration or a failed tool loop.

## Try the gateway and the web UI

```sh
pasclaw gateway
```

Opens an HTTP server (default `127.0.0.1:8088`) with:

- An embedded single-page web UI at `/` (chat, memory, files, MCP, cron, skills, logs, settings).
- OpenAI-compatible `/v1/chat/completions` and `/v1/responses` for any OpenAI client.
- Read-only inspection endpoints (`/v1/mcp`, `/v1/cron`, `/v1/skills`, `/v1/memory`, `/v1/fs`, `/v1/status`, `/v1/stats`).

See [Gateway and OpenAI-compatible API](./gateway.md) for the full route table.

## Next steps

- Add a [skill](./skills.md): `pasclaw skills install owner/repo` or `pasclaw skills install clawhub:<slug>`.
- Hook up an [MCP server](./mcp.md): `pasclaw mcp install replicate` (or any catalog entry).
- Lock the agent into a [sandbox](./security.md): set `restrict_to_workspace: true` in `config.json`.
- Wire a [chat channel](./channels.md) so the agent answers Telegram / Slack / Matrix / Discord.
- Index your [reference docs](./knowledgebase.md): `pasclaw kb add ~/docs/`.

## What gets created where

```
$PASCLAW_HOME/                       (default ~/.pasclaw/)
├── config.json                      ← the only required file; everything else is opt-in
├── workspace/
│   ├── memory/                      ← markdown notes; FTS5-indexed for memory_search
│   │   ├── MEMORY.md
│   │   ├── SCARS.md                 ← created by `pasclaw learn --write-scars`
│   │   └── fetched-*.md             ← written by memory_fetch
│   ├── sessions/                    ← one JSON file per session (interactive auto-saves here)
│   │   ├── 20260601T093015-<hex>.json
│   │   └── .search.db               ← session_search FTS5 index
│   ├── skills/                      ← installed skills (SKILL.md per directory)
│   ├── cron/state.json              ← last-fire timestamps
│   ├── steering/<session-id>.jsonl  ← mid-loop steering queue
│   ├── kb.db, kb.db.vec             ← knowledgebase FTS5 + vector sidecar
│   ├── heartbeat.md                 ← polled by the heartbeat daemon (opt-in)
│   └── stats/                       ← persisted gateway endpoint counters (opt-in)
├── cache/
│   ├── models/<provider>.json       ← live /v1/models cache
│   └── localvector/                 ← sqlite-vec + ONNX Runtime + MiniLM (after `memory provision`)
├── run/tool-rpc.json                ← execute_code loopback RPC handshake
└── tmp/exec-*.{sh,ps1}              ← execute_code script bodies (cleaned up per call)
```
