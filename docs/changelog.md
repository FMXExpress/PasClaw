# Changelog

Notable feature additions, newest first. Bug fixes and review follow-ups are in the [full git log](https://github.com/FMXExpress/PasClaw/commits/main).

This file mirrors the changelog section at the top of the root `README.md`. When a PR ships a feature worth surfacing here, append a one-line entry with the date and a PR link.

## 2026-06

- **2026-06-13** — `pasclaw agent --quiet` clamps the logger to `llError` so `[info]` startup noise (web_search disabled, MCP cache hit, ...) stays off the stdout pipeline scripts read. ([#244])
- **2026-06-12** — `dcc64 F2613 Unit 'PasClaw.Otel' not found` fixed by appending `..\pkg\otel` to the Delphi project's `DCC_UnitSearchPath`. ([#243])
- **2026-06-12** — `pasclaw agent --quiet` / `-q` for machine-readable single-turn output: drops banner, assistant header, per-tool decoration, token line; exit code is non-zero on provider misconfig or failed loop. ([#243])
- **2026-06-12** — OpenTelemetry traces (OTLP/HTTP+JSON) on the agent loop + gateway HTTP server, off by default. Mirrors openclaw v2026.2+'s span shape so Langfuse / Tempo / Jaeger / Honeycomb / Datadog dashboards work without remapping. `OTEL_EXPORTER_OTLP_ENDPOINT` env var alone flips it on. ([#242])
- **2026-06-12** — `fs_grep` ripgrep tier 5+6: byte walker replacing `TStringList`/`StringReplace`/per-line `LowerCase`, and Boyer-Moore-Horspool substring search replacing `Pos()`. 3-5x faster on the per-file path; 3-10x fewer text-byte reads on typical queries. ([#241])
- **2026-06-12** — `fs_grep` ripgrep tier 1-4: deferred file hashing, hardcoded VCS/build/deps skip-dirs, NUL-byte binary sniff, 10 MiB size cap. ([#240])
- **2026-06-10** — TUI: subagents wired in (`spawn` + the background quartet register when config.json declares subagents — previously CLI-agent-only) and the `/stats` + `/model` overlays no longer flicker.
- **2026-06-10** — Background subagents (Claude Code shape): `spawn_background(agent, prompt)` returns a handle and the parent loop keeps working; finished results land in the next iteration as a `[background subagent results]` system-prompt block.
- **2026-06-10** — `session_search` tool: FTS5 keyword search over the full text of every SAVED session. Index lazily rebuilt from JSON transcripts.
- **2026-06-10** — Tool-RPC callback from `execute_code`: the model can call back into the same tool registry via `pasclaw __tool <name> '<args>'` inside a bash/PowerShell script.
- **2026-06-09** — Gateway stats buckets for stateless `/v1/chat`, `/v1/chat/completions`, `/v1/responses` calls so the web UI Stats tab actually ticks when the operator uses the web chat.
- **2026-06-09** — Auto-router (UltraCode-Shim shape): heuristic classifies each user message as easy/abstain/hard and routes "easy" turns to a cheap-tier fallback provider.
- **2026-06-09** — Per-session stats persistence + `/v1/stats` endpoint + web UI Stats tab. Opt-in via `stats_collection_enabled`.
- **2026-06-09** — `execute_code` tool: model writes a multi-line bash or PowerShell script; PasClaw materialises and runs it.
- **2026-06-09** — `pasclaw runbook` asks the agent to probe the current project and write a starter `./AGENTS.md`. Pairs with `execute_code` so the probe is one tool call.
- **2026-06-09** — `pasclaw learn --write-scars` emits/refreshes `workspace/memory/SCARS.md` with Atlas-style stable `§ANCHOR-NAME` ids per recurring failure.
- **2026-06-09** — `pasclaw export [agents|claude|cursor|gemini|zed|all]` renders operator state into the rules files Claude Code / Cursor / Gemini CLI / Zed AI / the AGENTS.md convention look for.
- **2026-06-08** — Server-side `call_id` → `thoughtSignature` cache on `/v1/responses` so stock OpenAI-Responses clients round-trip Gemini 3's signed function calls across turns. ([#194])
- **2026-06-08** — `memory_fetch` URL auto-dedup: a second fetch against the same URL within 24h short-circuits the HTTP and returns the cached path. ([#192])
- **2026-06-08** — `pasclaw learn` mines session transcripts for recurring tool failures and normalises into clustering signatures. ([#190])
- **2026-06-08** — Per-command shell output filters with tee-on-failure: git, test runners, grep, recursive listings, tabular CLIs, docker build, log tails, compile walls, linters, package managers, build systems, IaC, aws JSON. ([#189])
- **2026-06-08** — In-browser wasm build via container2wasm: `make C2W=1 browser` produces a single-page agent UI with fetch-proxy networking. ([#185], [#186], [#187], [#188])
- **2026-06-08** — TUI session pane sorted newest-first by `UpdatedAt`, assistant markdown rendered as ANSI in the chat pane, `pasclaw tui` resumes the newest session on launch. ([#182], [#184])
- **2026-06-08** — Context-mode follow-ups: `memory_fetch` tool, per-session working-state snapshot re-injected after compaction, think-in-code steering rule. ([#180])
- **2026-06-08** — Per-tool-result output truncation cache (`tool_output_cap`) with `tool_output_get(handle, offset, len)` retrieval. ([#176])
- **2026-06-07** — Live `/v1/models` discovery with on-disk cache, onboarding picker, TUI `/model` modal switcher with inline auto-refresh. ([#171], [#173], [#175])

## 2026-06-06

- Hybrid FTS5 + local-vector `memory_search` backend with in-tree localvector port and `pasclaw memory provision`. ([#165], [#166])
- Catalog adds xAI (Grok) + LM Studio entries; Moonshot default bumped to `kimi-k2.6`. ([#163])
- `vector_search_enabled` config flag + onboarding question for the hybrid memory backend. ([#164])

## 2026-06-05

- Gemini server-side `google_search` grounding, default-on with Gemini-3-or-later gating. ([#158])
- Gemini 3 `thoughtSignature` round-trip on `functionCall` parts. ([#154])
- Markdown rendered as ANSI-styled text in the terminal for agent + TUI surfaces. ([#155])
- OpenAI server-side `web_search_options` support, default-on for genuine OpenAI endpoints only. ([#146])
- `web_fetch` tool gated behind explicit `web_fetch_enabled` opt-in. ([#144])

## 2026-06-04

- pasclaw.dev Code Vault tools (`vault_search` / `vault_get`) for Object Pascal sample discovery. ([#130])
- MCP catalog + hub with one-command built-in server installs. ([#131], [#134])
- Onboarding prompt for built-in MCP servers. ([#126])

## 2026-06-01

- TUI themes, widgets, and chat layout polish. ([#122], [#123], [#124])
- Docker image and Dockerfile for containerised deployment. ([#121])
- Persistent sessions, resume, and mid-loop `steer` follow-ups. ([#117], [#120])
- Anthropic prompt-caching toggle with TTL config. ([#118])
- Channel sender identity + allowlist gating. ([#119])
- Windows ARM64 cross-build target. ([#115])
- Agent hooks and steering API. ([#113])

## 2026-05-30

- Tier-1 features: parallel tool dispatch, code-driven provider config, Delphi sample projects. ([#98], [#96], [#95], [#101])
- MCP catalog of built-in servers. ([#91])
- Web UI with chat / sessions / memory / MCP / skills / vault tabs. ([#88])

## 2026-05-29

- Channels: Matrix + IRC + WhatsApp + LINE bots in addition to Telegram. ([#75], [#76], [#77], [#86])
- Web search across DuckDuckGo / Brave / Tavily / SearXNG / Perplexity / Gemini. ([#80], [#81], [#82])
- SSRF guard blocking cloud-metadata + RFC1918 + loopback in `web_fetch`. ([#85])
- Workspace sandbox with `cd`-gating and shell denylist. ([#84])
- Cron persistent state + per-job channel sinks. ([#79])
- FTS5-backed `memory_search` tool. ([#74])

## 2026-05-28

- OpenAI Responses API on the gateway. ([#62])
- Skills system: `SKILL.md` manifests, GitHub install, ClawHub install. ([#55], [#56], [#59])
- Gemini provider (generateContent REST). ([#48])

## 2026-05-27

- `pasclaw serve` — OpenAI-compatible HTTP server with SSE streaming. ([#20])
- Provider catalog (19+ kinds: Anthropic, OpenAI, Groq, OpenRouter, Mistral, ...). ([#40])
- Delphi visual component (`TPasClawAgent`). ([#37])
- Hashline diff format port for `fs_edit_hashline`. ([#26])
- TUI (full-screen interactive console). ([#24])

## 2026-05-26

- Initial Delphi/FPC port of picoclaw. ([#2])

[#2]:   https://github.com/FMXExpress/PasClaw/pull/2
[#20]:  https://github.com/FMXExpress/PasClaw/pull/20
[#24]:  https://github.com/FMXExpress/PasClaw/pull/24
[#26]:  https://github.com/FMXExpress/PasClaw/pull/26
[#37]:  https://github.com/FMXExpress/PasClaw/pull/37
[#40]:  https://github.com/FMXExpress/PasClaw/pull/40
[#48]:  https://github.com/FMXExpress/PasClaw/pull/48
[#55]:  https://github.com/FMXExpress/PasClaw/pull/55
[#56]:  https://github.com/FMXExpress/PasClaw/pull/56
[#59]:  https://github.com/FMXExpress/PasClaw/pull/59
[#62]:  https://github.com/FMXExpress/PasClaw/pull/62
[#74]:  https://github.com/FMXExpress/PasClaw/pull/74
[#75]:  https://github.com/FMXExpress/PasClaw/pull/75
[#76]:  https://github.com/FMXExpress/PasClaw/pull/76
[#77]:  https://github.com/FMXExpress/PasClaw/pull/77
[#79]:  https://github.com/FMXExpress/PasClaw/pull/79
[#80]:  https://github.com/FMXExpress/PasClaw/pull/80
[#81]:  https://github.com/FMXExpress/PasClaw/pull/81
[#82]:  https://github.com/FMXExpress/PasClaw/pull/82
[#84]:  https://github.com/FMXExpress/PasClaw/pull/84
[#85]:  https://github.com/FMXExpress/PasClaw/pull/85
[#86]:  https://github.com/FMXExpress/PasClaw/pull/86
[#88]:  https://github.com/FMXExpress/PasClaw/pull/88
[#91]:  https://github.com/FMXExpress/PasClaw/pull/91
[#95]:  https://github.com/FMXExpress/PasClaw/pull/95
[#96]:  https://github.com/FMXExpress/PasClaw/pull/96
[#98]:  https://github.com/FMXExpress/PasClaw/pull/98
[#101]: https://github.com/FMXExpress/PasClaw/pull/101
[#113]: https://github.com/FMXExpress/PasClaw/pull/113
[#115]: https://github.com/FMXExpress/PasClaw/pull/115
[#117]: https://github.com/FMXExpress/PasClaw/pull/117
[#118]: https://github.com/FMXExpress/PasClaw/pull/118
[#119]: https://github.com/FMXExpress/PasClaw/pull/119
[#120]: https://github.com/FMXExpress/PasClaw/pull/120
[#121]: https://github.com/FMXExpress/PasClaw/pull/121
[#122]: https://github.com/FMXExpress/PasClaw/pull/122
[#123]: https://github.com/FMXExpress/PasClaw/pull/123
[#124]: https://github.com/FMXExpress/PasClaw/pull/124
[#126]: https://github.com/FMXExpress/PasClaw/pull/126
[#130]: https://github.com/FMXExpress/PasClaw/pull/130
[#131]: https://github.com/FMXExpress/PasClaw/pull/131
[#134]: https://github.com/FMXExpress/PasClaw/pull/134
[#144]: https://github.com/FMXExpress/PasClaw/pull/144
[#146]: https://github.com/FMXExpress/PasClaw/pull/146
[#154]: https://github.com/FMXExpress/PasClaw/pull/154
[#155]: https://github.com/FMXExpress/PasClaw/pull/155
[#158]: https://github.com/FMXExpress/PasClaw/pull/158
[#163]: https://github.com/FMXExpress/PasClaw/pull/163
[#164]: https://github.com/FMXExpress/PasClaw/pull/164
[#165]: https://github.com/FMXExpress/PasClaw/pull/165
[#166]: https://github.com/FMXExpress/PasClaw/pull/166
[#171]: https://github.com/FMXExpress/PasClaw/pull/171
[#173]: https://github.com/FMXExpress/PasClaw/pull/173
[#175]: https://github.com/FMXExpress/PasClaw/pull/175
[#176]: https://github.com/FMXExpress/PasClaw/pull/176
[#180]: https://github.com/FMXExpress/PasClaw/pull/180
[#182]: https://github.com/FMXExpress/PasClaw/pull/182
[#184]: https://github.com/FMXExpress/PasClaw/pull/184
[#185]: https://github.com/FMXExpress/PasClaw/pull/185
[#186]: https://github.com/FMXExpress/PasClaw/pull/186
[#187]: https://github.com/FMXExpress/PasClaw/pull/187
[#188]: https://github.com/FMXExpress/PasClaw/pull/188
[#189]: https://github.com/FMXExpress/PasClaw/pull/189
[#190]: https://github.com/FMXExpress/PasClaw/pull/190
[#192]: https://github.com/FMXExpress/PasClaw/pull/192
[#194]: https://github.com/FMXExpress/PasClaw/pull/194
[#240]: https://github.com/FMXExpress/PasClaw/pull/240
[#241]: https://github.com/FMXExpress/PasClaw/pull/241
[#242]: https://github.com/FMXExpress/PasClaw/pull/242
[#243]: https://github.com/FMXExpress/PasClaw/pull/243
[#244]: https://github.com/FMXExpress/PasClaw/pull/244
