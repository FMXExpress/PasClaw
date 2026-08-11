# PasClaw documentation

PasClaw is an ultra-lightweight personal AI agent in Delphi Object Pascal — a CLI assistant, HTTP gateway, OpenAI-compatible API, embedded web UI, MCP integration, scheduled tasks, skills, and channel bots, all in one binary.

The main `README.md` at the repo root is the landing page. These docs go deeper.

## Getting started

- [Getting started](./getting-started.md) — install with FPC or Delphi, run `pasclaw onboard`, send your first message.
- [Configuration](./configuration.md) — `~/.pasclaw/config.json` shape, environment variables, `$PASCLAW_HOME` layout.
- [Commands](./commands.md) — the top-level commands, their flags, and what each one writes to disk.

## Capabilities

- [Providers](./providers.md) — the 19-entry catalog (Anthropic / OpenAI / Gemini / Groq / DeepSeek / OpenRouter / Ollama / vLLM / ...), fallback chain, prompt caching.
- [Tools](./tools.md) — built-in tools the model sees on every turn (`fs_read`, `fs_write`, `fs_grep`, `shell_exec`, `web_search`, `web_fetch`, `memory_search`, `session_search`, `kb_*`, `vault_*`, `send_message`, `execute_code`, `spawn`, `tool_output_get`).
- [Web search](./web-search.md) — `web_search` / `web_fetch` providers and configuration.
- [Memory](./memory.md) — `workspace/memory/`, FTS5 + hybrid vector backend, `memory_fetch`.
- [Knowledgebase](./knowledgebase.md) — `pasclaw kb` for indexing reference documents (markdown / source code / HTML).
- [Skills](./skills.md) — `$PASCLAW_HOME/workspace/skills/`, GitHub + ClawHub install, SKILL.md format.
- [Sessions](./sessions.md) — persistence, resume, `/new` / `/reset` / `/compact`, mid-loop `pasclaw steer`.
- [Checkpoints](./checkpoints.md) — `/undo` / `/redo` for file-edit rewind via the zpaq-backed snapshot journal.
- [MCP servers](./mcp.md) — stdio + streamable-HTTP transports, `pasclaw mcp catalog`, the bundled built-in list.
- [Cron](./cron.md) — scheduled tasks, at-least-once delivery, per-job channel sinks.

## Interfaces

- [Gateway and OpenAI-compatible API](./gateway.md) — `/v1/chat/completions`, `/v1/responses`, `/v1/mcp`, embedded web UI, route table.
- [Desktop](./desktop.md) — the desktop client: workspaces, projects/tasks/jobs, the app factory, answer pages, and the system suite.
- [Chat channels](./channels.md) — Telegram, Discord, Slack, Teams, LINE, WhatsApp, Matrix, IRC, Email.
- [Embedding in your own app](./embedding.md) — `TPasClawAgent` / `TPasClawServer` `TComponent`s for VCL/FMX/CLI binaries.

## Operations

- [Security and sandbox](./security.md) — workspace boundary, shell denylist, SSRF guard, hashline race-safety.
- [Observability](./observability.md) — OpenTelemetry tracing, `/v1/stats`, TUI `/stats` overlay.
- [Troubleshooting](./troubleshooting.md) — common errors and what to check.

## Inside PasClaw

- [Architecture](./architecture.md) — how the agent loop, tool dispatch, fallback walk, and hooks fit together.
- [Contributing](./contributing.md) — repo layout, build conventions, test conventions, PR style.
- [Changelog](./changelog.md) — feature-by-feature history.

## Specialised

- [container2wasm browser build](./c2w.md) — make PasClaw run in a browser tab via container2wasm.

---

*Looking for the high-level pitch?* See the root [`README.md`](../README.md).
