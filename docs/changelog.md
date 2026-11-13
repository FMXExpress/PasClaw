# Changelog

Notable feature additions, newest first. Bug fixes and review follow-ups are in the [full git log](https://github.com/FMXExpress/PasClaw/commits/main).

This file mirrors the changelog section at the top of the root `README.md`. When a PR ships a feature worth surfacing here, append a one-line entry with the date and a PR link.

## 2026-11

- **2026-11-13** — `pasclaw agent -m "..." --session ID` is a turn on that session. Before, it sent the model the new prompt alone and saved that turn's history over the session file, so the reply was never saved, the model never saw the conversation so far, and an interactive session passed to it lost its transcript. The one-shot path now runs the turn the way the interactive prompt resumes a session: the stored messages go first, the prompt, tool calls, results and reply are appended, a provider refusal's error text is printed and not saved as a reply, the session's own prompt (where a compaction summary lives) is used and saved back, and the turn works in the session's directory, as `pasclaw resume` does. Without `--session` a one-shot still saves nothing. ([#641])
- **2026-11-13** — Stats totals are right again, and can be reset. The OpenAI, Anthropic and Gemini `Chat` functions returned a record whose unset fields held leftover memory, so the Stats tab, `/v1/stats` and the saved stats of `pasclaw agent` sessions showed token counts no provider had reported, in the billions or negative. The three now start from an empty response and `ParseOAIResponse` clears its counters first. Totals saved by earlier builds are not corrected; **Reset totals** on the Stats tab (`POST /v1/stats/reset`, token-gated like the rest of `/v1/*`) asks first, then sets every saved counter to zero and keeps conversations. A conversation with a turn running on the gateway is skipped and the reply says how many were; `prompt_cache_warm_pings` is not reset; a reset cannot be undone. A `/v1/stats` answer computed before a reset is no longer cached after it, and the tab draws only its newest request's answer. ([#639], [#640], [#641])
- **2026-11-13** — Web UI redesign (`webui.html`). The neon look gives way to a stylesheet built on a small set of tokens: one neutral surface scale, one accent, three status colours, sans for the interface and mono for code, paths, config keys and tool output, and one SVG icon set in place of emoji. `html.lite` is a real light theme that swaps the tokens (it was a CSS invert filter), and the theme follows the OS until the theme button is used. A slim app bar with a status chip, a chat transcript in a readable column with per-message actions under the message, and a narrow-screen layout where the tab strip scrolls sideways and the chat list opens over the transcript. No features added or removed; `desktop.html` is not touched. ([#638])
- **2026-11-13** — The markdown renderer in `webui.html` and `desktop.html` no longer freezes the tab on CRLF text. A heading or fence line ending in `\r` failed the block test but matched the paragraph loop's stop test, so `renderMarkdown` looped forever; the web UI reopens the last chat on load, so a reload froze it again. The Delphi build's Anthropic provider joins a reply's text blocks with CRLF, which was enough. Line endings (`\r\n`, `\r`, U+2028, U+2029) are now normalised before splitting, and the paragraph branch always takes its line. ([#637])
- **2026-11-13** — Context breakdown in the web UI, the equivalent of Claude Code's `/context`. A context button in the chat toolbar shows the running total; it or `/context` opens a panel with a segmented bar against the model's window, each part's tokens and share (system prompt, memory, project rules, skills, built-in tools, MCP tools, messages, free space), how far the conversation is from compaction, and expandable lists of system prompt sections, tools per MCP server and the largest messages. It is served by `POST /v1/context`, which takes the `/v1/chat/completions` body and assembles it with the chat route's own code without calling a model (`text: true` adds each section's text). New display-only key `context_window`; without a window the bar is drawn against the compaction threshold. Every number is a chars/4 estimate, and the report says so. ([#636])
- **2026-11-13** — A provider refusal is an error, not the assistant's reply. `/v1/chat/completions` used to return the provider's error text as an HTTP 200 answer, and `PersistGatewaySession` saved it as an assistant message, so on the next turn the model was told it had said it. A refusal now gets HTTP 502 `{"error": {message, type: "provider_error", upstream_status}}` (or, with `stream: true`, an OpenAI error frame then `[DONE]`), no saved session gets the error as a reply, and the web UI shows it as an error turn with **retry** that is never sent to the model. Same PR: the MCP bridge registered tools through `RegisterDeferred`, the one path that did not reset `Hidden`, so leftover stack bytes decided whether an MCP tool's schema ever reached the model; it now always does. ([#636])
- **2026-11-12** — `pasclaw acp` runs PasClaw as an [Agent Client Protocol](https://agentclientprotocol.com) agent, so an editor (Zed, JetBrains IDEs, ACP plugins for Neovim and Emacs) can drive it over newline-delimited JSON-RPC on stdin and stdout, with the same loop, tools, `permissions` rules, sessions, modes and providers as `pasclaw agent`. The editor gets each tool call with its kind, title and file location, a before/after diff for `write_file` / `edit_file` / `append_file`, `todo_write` as a `plan`, `ask` rules as `session/request_permission` (Allow once / Allow for this session / Deny), `session/cancel`, the four modes through `session/set_mode` (which now reaches the system prompt after the first turn, as the REPL's `/mode` now does too), and `session/load` replay. The editor's `cwd` is the session's project: tools, the shell, the system prompt and its `AGENTS.md` follow it, and it is recorded as the session's location for `pasclaw resume`. Editor-supplied stdio MCP servers connect once per name. Under the Docker backend each session runs in its own container, including its background jobs, with the editor's project mounted (POSIX). Replies stream token by token: OpenAI-compatible providers now really stream (which also makes the gateway's streamed `/v1/responses` stream for them), Anthropic streams with per-call state and every block kept, and thinking (Anthropic, or a compatible server's `reasoning_content` / `reasoning`) reaches the editor as `agent_thought_chunk`. Gemini and the relay provider still send each round whole. Not supported yet: images and audio, HTTP and SSE MCP servers from the editor, the editor's file system and terminals, authentication methods. See `docs/acp.md`. ([#630], [#631], [#632], [#633], [#634], [#635])
- **2026-11-06** — Gateway: an unset token is no token, and a token-less gateway refuses browsers from other sites. With `"token": "${PASCLAW_GATEWAY_TOKEN}"` (the DigitalOcean template) and the variable unset, the literal marker was accepted as the bearer; it now means no token, and the log says bearer auth is disabled. With no token, any web page could POST `text/plain` to `/v1/chat` and drive the agent and its shell, and a DNS-rebinding page could read `/v1/config`. A token-less gateway now answers 403 to an `Origin` from another site (another site, another port, `null`, or the `--apps-port` origin) and to a `Host` that is a domain name other than `localhost`, `*.localhost` or a name in the new `gateway.allowed_hosts`. Any IP `Host` is fine, and CLI tools, SDKs, MCP clients, the web UI, the desktop and app iframes are unaffected. Without the relay token, `/v1/relay/*` answers only the gateway's own pages and non-browsers. A token-less gateway on a non-loopback bind now says at startup that it answers any client that can reach it, `docker/README.md` and `make -C digitalocean run` publish on `127.0.0.1`, and with `--apps-port` the apps origin now follows the request's `Host`, so a desktop opened under another name shows its app windows. ([#629])
- **2026-11-05** — `pasclaw learn` gives each tool result to the call that made it (the latest call with the id, for servers that number calls per turn), counts misuse notes (`grep_files` given a regex, a definition hunted by guessing its keyword) as patterns of kind **misuse**, and runs inside `pasclaw maintain`, and so `@maintain`, over the last 30 days. The report gains a Recurring section, and `SCARS.md` gets an anchor for each pattern seen in 2+ sessions that it lacks; existing anchors and what the operator wrote under them are left alone, and `--dry-run` only lists. Quoted text (file reads, board and subagent results, SCARS.md and report lines read back) is not mined, a bare status line such as `exit=1` counts a failure but is never a pattern, and credentials are masked as `<redacted>` before a line is kept. `SCARS.md` is still not injected into the prompt. ([#628])
- **2026-11-05** — `code_outline`, a repository map made on demand. `symbol=NAME` lists where a name is declared or defined (not its uses), `path=FILE` a file's declarations with line numbers (Pascal interface first, then the implementation bodies), `path=DIR` each source file's purpose and the names it declares. Line scanners, not parsers, for Pascal, Python, JS/TS (and scripts in `.html`), Go, Rust, Ruby and PHP; read-only, inside the sandbox, capped. On 34 real definition lookups (`make bench-codenav`) it returned 7,021 bytes against 47,690 for `grep_files` on the name, both answering all 34. It is visible rather than deferred, at 406 bytes of schema per request. When a definition-shaped `grep_files` pattern finds nothing, the result names the `code_outline` call. In a live run, with the model's decisions made by stand-ins told nothing about the tool, it was chosen first for a one-line-per-unit directory summary (2 calls instead of 3) and not for two lookup tasks; units whose header comment follows `unit X;` now get a summary line. ([#626], [#627])
- **2026-11-05** — Security Engineer, a team member that follows untrusted input from where it enters to where it is used (SQL built from strings, shell commands, `eval`/`exec`, paths, HTML, fetched URLs, deserializers), then checks secrets, access control, unsafe defaults and crypto. It files only holes it demonstrated, fixes the kind at the boundary with a test that sends the attack, and submits with the attack before and after as evidence. `sec` joins `software-team` on the default tier with a "Security sweep" task that waits on the build; the new `security` template (Foreman + Security Engineer) sweeps an existing project with `pasclaw team up security --project <name>`. `task action=create … cause="sql-injection"` files a finding with a snapshot of the project, and `rule action=draft` can prove a check from one fixed finding. Also fixed: `/v1/decisions` and `/v1/needs-you` were 404 in a running gateway, so Needs you could not show or answer anything. ([#625])

## 2026-10

- **2026-10-30** — Software Factory, and teams that work without config. **Start → Software Factory** takes a sentence and a team template (Software Team by default, Duo for small things); Ask's new **Build with a team**, New Team… and the model's own `team_up` open it too. The factory window puts the conversation with the team's lead beside its live board: a timeline of what you told the lead, the lead's replies and the board's events; Accept / Reject, Edit and + Task; whether the team is working, waiting, parked or finished, what waits in each mailbox, and any question for you. New `GET /v1/teams/<name>/feed`. A standing agent now always has the board tools and the `agent` tool. An ordinary chat (CLI, project chats, Ask) finds them with `tool_search` and is asked (Allow once / Allow for this session / Deny) before calling one or `team_up`, and is refused when there is nobody to ask; `desktop_tools_enabled` and `agent_tools_enabled` still mean "yes, every chat" for configs that set them. ([#624])
- **2026-10-29** — Team boards hold their own rules. A new `review` status is reached only through `task action=submit` with evidence and left only through a verdict from the operator or, via `task action=verdict`, a listed reviewer who is neither the submitter nor the owner (a reject goes back to the owner with the reason); `team up` turns review on for its board, and an agent's `done` there is refused. `criteria` freeze once work starts, `projects/<p>/activity.jsonl` records every change (`GET /v1/projects/<p>/activity`), held-out checks under `$PASCLAW_HOME/scenarios/` must pass before a submit is accepted, and the file tools cannot write the board's own files. Tasks can wait on others (`waits_on`), `task action=next` claims the oldest ready task under one lock, and leases (`teams.claim_lease_minutes`, default 120) hand back work whose holder's run died. **Needs you**: `agent action=ask_operator`, a desktop window for decisions, pending permission requests and operator-only reviews, `/v1/decisions` and `/v1/needs-you`, and `decisions.channel` with `D12 yes` replies accepted from `decisions.answer_from`. A cause rejected twice can become a proven rule: `rule action=draft` must fail on the rejected snapshot and pass on the accepted one. Template agents can be given `lane` path globs that refuse file writes elsewhere. Follow-ups from a live run: `task create` keeps `assignee`, owners and leads are told about ready and new work, mail wakes the team tick (a handoff in `make bench-teamboard` went from 29.5–29.9 s to 0.5–0.8 s), a team the board parked resumes when work arrives, and the desktop gets a task form. An empty reviewer list now means only the operator can give the verdict. ([#622], [#623], [#627])
- **2026-10-26** — Held-out verification. `verification.scenarios` names a directory of executable checks the agent never sees. After the model's final answer the tool loop runs them in the workspace through the active shell backend, under `shell_timeout_sec`; a failing round becomes one more user turn naming the failed check and its output ("fix the cause, not the check"), up to `verification.max_rounds` (default 2). `/v1/chat` returns a `verification` object, `/v1/chat/completions` and `/v1/responses` end an unverified answer with a NOT verified notice, the CLI prints the summary, and `pasclaw agent --scenarios <dir>` overrides config. A missing or empty scenario set is a failure, not a green 0/0. ([#618])
- **2026-10-26** — Two seconds off every agent turn. `DrainSteering` took its `mkdir` lock before checking for a queue file, and in a home nobody had steered the steering directory did not exist, so the lock wait ran out at 2,000 ms on every iteration of every session, on the gateway, the CLI and the TUI. It now returns at once when there is no queue file and no lock held. Six turns against an instant relay model went from 12.2 s to 0.1 s. ([#617])
- **2026-10-26** — Fewer turns per task. Rule 7 of the system prompt now says what the loop does: every call in a response runs, in the order listed, before the model is asked again, so independent writes and the check that depends on them can go in one response. The Workspace section lists the workspace's top-level entries (sorted, directories slashed, hidden ones skipped, capped at 40), each name scrubbed of control and bidi characters and quoted as data. The RAG build bench went from 6 turns and 146,734 request bytes to 2 turns and 49,218. ([#616])
- **2026-10-26** — `--no-mcp` keeps the built-in long tail deferred. The gateway, `serve` and the TUI only reached built-in progressive disclosure through MCP setup, so under `--no-mcp` they carried all 36 schemas and had no `tool_search`; all four surfaces now share one entry, and `tool_search` registers only when `builtin_progressive_disclosure` is on. `desktop` is deferred until a desktop subscribes to `/v1/desktop/events`, which reveals it. `memory_write`, `shell_background` and `memory_fetch` stay visible. On the RAG bench a `--no-mcp` request is 34% smaller. ([#615])
- **2026-10-23** — Skill arguments and slash commands, an `instructions` list, and a prompt-cache keep-alive. Prompt skill templates take `$ARGUMENTS` and `$1`..`$9` (split like a shell, the highest `$N` absorbing the rest) beside `{{key}}`, and frontmatter gains `agent:`, `model:` and `subagent:`. In `pasclaw agent` and both TUI builds, `/name rest of line` runs the installed prompt skill (built-ins win on a clash; `/help` lists the skills), and `model:` applies to that run only, untouched by the auto-router. Config `instructions` lists files, globs and http(s) URLs whose bodies are appended after the project rules; URLs go through `web_fetch`'s SSRF guard and are cached 24 h. `prompt_cache.warm` (default off) has the gateway send a one-token request every four minutes while idle, until thirty minutes after the last turn, so the cached prefix stays warm; each ping is billed and counted as `prompt_cache_warm_pings` in `/v1/stats`. ([#614])
- **2026-10-23** — Attach mode. `pasclaw gateway` / `serve` write `$PASCLAW_HOME/run/gateway.json` while running (`pasclaw status` reports running / stale / none) and now stop cleanly on the first SIGINT / SIGTERM / Ctrl-C, with a second one killing. `pasclaw agent --attach` and `pasclaw tui --attach` run nothing locally: each line is one turn on the gateway's session through `/v1/chat/completions`, `/sessions`, `/new`, `/resume <id>` and `/delete <id>` go through `/v1/sessions`, `--plan` / `--mode`, `--model`, `--system`, `--max-tokens` and `--no-tools` are forwarded, and flags a gateway turn cannot carry are refused by name with exit 2. `cli.attach: off|auto|on` (default `off`) makes it automatic. ([#613])
- **2026-10-23** — Git worktrees. `worktree_create(branch, base?)`, `worktree_list` and `worktree_remove(path, force?)` run git through the active shell backend, by default into `<repo>-worktrees/<branch>`. `spawn` / `spawn_background` take `worktree: "<branch>"`: the child's relative file writes, workspace boundary and shell cwd follow the worktree, and the parent's threads never see it. Sessions record their `Location`, shown by `session list` / `show`, and `pasclaw resume` makes it the workspace again when it still exists. Under Docker the worktree directory is bind-mounted at the same path (POSIX), and a worktree the host cannot see is refused and rolled back. `worktree.enabled: false` removes the tools and the `worktree` argument. ([#612])
- **2026-10-23** — Ordered permissions. One `permissions` list of `{tool, resource?, effect}` rules, with globs over the tool name and the call's primary resource; the last match wins and an empty list changes nothing. `deny` refuses with a result the model can read; `ask` goes to the surface's asker (TUI footer, CLI prompt, a `permission_request` desktop event answered by `POST /v1/permissions/<id>`, the component's `OnAsk`) with allow once / allow for the session / deny, and with no asker the answer is deny. `<home>/policies.json` holds a second list of the same shape, evaluated first, that `PUT /v1/config` cannot write. `pasclaw permissions list` / `test <tool> [resource]` show the lists in order and what the gate would decide. ([#611])
- **2026-10-23** — Background shell jobs. `shell_background(command, cwd?, timeout_sec?)` returns an `sh-<hex>` handle at once; the output reaches the model at the top of its next turn as a `[background shell results]` block, and `spawn_status` / `spawn_wait` / `spawn_cancel` work on it, cancel killing the command and everything it started. It registers whatever `subagents_enabled` says. A completion flashes in the TUI and is published as a `background_done` desktop event. `background_jobs_max` (default 6) caps subagent and shell jobs together, replacing the compile-time 4. Cancel, timeout and the output cap now kill the whole process tree, through `/proc` where it exists and `ps` on macOS and the BSDs. ([#619])
- **2026-10-23** — Code Mode for MCP servers, on by default (`mcp_codemode_default: true`, or `codemode` per server). A code-mode server's tools are never sent to the model as schemas; the model calls them from an `execute_code` script through a one-line `tool` helper (`tool github__list_issues '<json>' | jq ...`), so only the script's output enters the conversation. The prompt's Deferred Tools section names each code-mode server with its tool count and the recipe, `code_catalog(server?)` (and `tool --catalog` inside a script) returns their schemas, and script calls pass the same dispatch gates as direct ones. Under the Docker backend the script reaches the host's RPC listener through `host.docker.internal`. ([#609])
- **2026-10-22** — Scripts and shell skills no longer walk around the tool gates, and `shell_exec` has a timeout. An `execute_code` script's `pasclaw __tool` call now goes through the tool loop's dispatcher (mode gates, `BeforeToolCall` hooks, preflight, promptware scan, output cap), so plan mode refuses a mutation made from a script; a subagent's script reaches only the subagent's tools; `kind: shell` skills pass the denylist, run through the active shell backend and are mutating. New `shell_timeout_sec` (default 600, `0` = none) kills a command on expiry with `exit=124`, and `shell_exec` takes a per-call `timeout_sec`. Background subagent results now reach gateway sessions, `TPasClawClient.Chat` can send `X-PasClaw-Session` and `session_context`, and the TUI builds the real system prompt (memory, facts, `AGENTS.md`, skills catalog) like the CLI and gateway. ([#608])
- **2026-10-17** — Memory tiers, a nightly maintenance pass, backup/restore, and a cheap tier for background work. The always-loaded memory files (`SOUL.md`, `USER.md`, `MEMORY.md`, two daily notes) are each capped by `memory_core_budget_bytes` with an elided note, and the prompt carries the six-months test. `pasclaw maintain` sweeps expired facts (`IFactStore.Sweep`), sizes the core files, summarises the day's sessions, audits skills for unused and duplicate ones, optionally asks the model for a critique and backs up; schedule it with the reserved cron skill `@maintain`. `pasclaw backup` / `restore` write archives with `config.json` and a `RESTORE.md` inside, rotated 7 / 4 / 6 (`--redact` for a masked config). `background_model` carries distillation, compaction, heartbeat, judge and review on the default provider; `pasclaw route report` shows the split. ([#606])
- **2026-10-17** — PasClaw Browser (`browser-desktop/`): a WebView2 desktop browser where every tab has a PasClaw chat beside it that can read the page and change it. One in-process `TPasClawAgent` for the app (the component is one-per-process), six page tools (`browser_page` / `browser_find` / `browser_navigate` / `browser_click` / `browser_fill` / `browser_eval`) registered once against a tested `TSwitchingBridge`, a single worker thread running tabs' turns in order, a page-context hook that stamps every message with the tab's URL, title and selection, and a confirm-before-mutate gate. Each tab is its own session, persisted under `workspace/browser/`. Everything below the FMX form compiles under FPC and runs in `make test`. ([#604])

## 2026-09

- **2026-09-08** — Memory gains a dependency-free embedding tier and a `memory_write` tool. `PasClaw.Memory.Embed.Static` (`hash-ngram-v2@256`) is feature hashing over word unigrams and character 4-grams — no model file, no vocabulary, no native runtime — so a host that has never run `pasclaw memory provision` still gets a vector column instead of keyword-only retrieval. It is **lexical, not semantic** (`car` and `automobile` score near zero) and registers with semantic dedup disabled: it ranks, it never merges. `memory_write` records one durable fact deliberately — `tcMutating`, so plan mode refuses it and MCP exposes it only under `--mcp-allow-write` — which lets an external MCP client contribute to the store it could already read. Underneath both, every stored vector now carries the id of the embedder that produced it, so two embedding spaces are never compared and a model switch triggers a backfill instead of silently wrong neighbours. ([#600])

## 2026-06

- **2026-06-24** — `orient_task_aware` (task-aware `MEMORY.md` slicing) reverts to **off on every profile** and gains a per-run CLI flag: `pasclaw agent --orient` enables it for one invocation, `--no-orient` forces whole-file injection (overriding `config.json`). #314 had flipped it on-by-default in `TConfig.Create` + the `stock`/`low-token`/`all-on` profiles while docs, onboarding, and the loop-shaping test still described it as off; this restores whole-file MEMORY injection as the default contract and makes slicing an explicit opt-in. ([#343])
- **2026-06-21** — Relay pull-worker provider: external workers (WebGPU browser tab, phone with mlc-llm, desktop with llama.cpp) connect INBOUND to `pasclaw gateway`, advertise models via `X-Relay-Capabilities`, pull pending requests off PasClaw's in-process queue, run inference locally, POST results back. New endpoints `/v1/relay/poll` (SSE), `/v1/relay/respond/<id>`, `/v1/relay/status`; new catalog row `relay`. Unlocks WebGPU inference without exposed ports, cog-hosted PasClaw served by your phone, shared home GPU across devices. ([#318])
- **2026-06-20** — `pasclaw plan` + `pasclaw build --goal` pairing. `pasclaw plan -d "<task>"` runs in `pmPlan` mode with a dedicated `plan_write` tool and writes `workspace/PLAN.md` (`## Goal / Files / Steps / Open questions / Risks`). `pasclaw build` auto-loads PLAN.md as system-prompt context (stale-check + `--no-plan` opt-out) and archives consumed plans to `workspace/memory/plans/<ts>.md`. `build --goal` parses `## Goal` and seeds the Ralph judge loop. `cog-build/predict.py` gains a 4-choice `mode` Input (`build` / `plan` / `plan build` / `plan build goal`). ([#317])
- **2026-06-20** — Cloudflare AI Gateway catalog rows: `cloudflare` (compat OpenAI-shape endpoint, default `workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast` using the gateway's `<provider>/<model>` routing), `cloudflare-anthropic` and `cloudflare-gemini` (native passthroughs with each provider's own auth header). Catalog-only — existing provider units handle the wire shape once `api_base` is set. ([#316])
- **2026-06-20** — MCP progressive disclosure + Claude Code-style `tool_search` (Hermes Level 0/1 pattern applied to MCP). Default on since fat catalogs (Replicate / GitHub MCP) make eager-reveal expensive. MCP tools register with `IsDeferred=True`; their schemas are stripped from the per-request `tools` array. System prompt lists names under `## Deferred Tools`; `tool_search` loads schemas on demand via `select:Name1,Name2`, `+required keyword1 keyword2`, or plain keyword search. Revealed tools callable next iteration. ([#315])
- **2026-06-20** — Stock-config defaults adopt the bench-grounded lean-edit shape: `web_fetch` / `vault_tools` / `memory_fetch` OFF out-of-box; the six zero-prompt-cost behavioral toggles (`orient_task_aware`, `checkpoints`, `stats`, 1h `prompt_cache.ttl`, `distiller`, `auto_router`) ON. `HashlineEnabled` controls only `fs_edit_hashline` after split-gating; `fs_grep` registers unconditionally (its ripgrep-inspired optimisations beat `shell_exec grep` and Windows has no shell `grep`). ([#314])
- **2026-06-18** — Web UI workspace.zip export + import from the gateway: download a snapshot of `$PASCLAW_HOME` (memory, sessions, kb, checkpoints, skills, scars) for hand-off between machines, re-import to restore. Same shape as the `pasclaw build` workspace handshake but operator-driven through the browser. ([#312])
- **2026-06-18** — Model-callable `cron` tool (opt-in via `cron_tool_enabled: true`; off by default since it grants background autonomy). Lets the agent schedule an installed skill on a cron expression. Schedules persist in `workspace/cron.json`; the scheduler picks them up on the next `pasclaw serve` / `pasclaw gateway` start. ([#310])
- **2026-06-18** — `memory_search` / `kb_search` FTS5 snippet window widened 24 → 60 chars; system prompt nudges the model to follow up with a targeted `fs_read` when a snippet looks relevant but lacks context. ([#309])
- **2026-06-18** — Windows `cmd.exe` quoting fix in `shell_exec` / `execute_code`: embedded double-quote literals (`hello "world"`) now survive `cmd.exe /c`; previously the inner quotes were eaten. ([#307])
- **2026-06-17** — `cog-build` honours `profile=security`'s sandbox tightening (workspace restriction + shell deny + private-network block) by intentionally **not** seeding any sandbox fields in its generated `config.json`. Same PR drops a misleading `web_search` claim in the cog README (the tool only registers when a search provider is configured; the cog doesn't supply one). ([#306])
- **2026-06-17** — `cog-build` defaults `profile` to **`max-build`** (the richest unattended-build toolset). Operators wanting different posture override to `baseline` / `low-token` / `security` / `all-on` / empty. Profile layered UNDER the cog's explicit `config.json` fields so the cog's provider catalog + `checkpoints_enabled` always win. ([#304])
- **2026-06-17** — `cog-build` outputs as `list[Path]` (workspace.zip + reply.txt CDN URLs) instead of a nested-Path `BaseModel` (Cog's older runtimes base64-encoded the nested Path inline). API keys move to `Optional[Secret]` inputs — masked in the UI, never appear in prediction logs. `-q` flag forwarded to `pasclaw build` so the ASCII banner stays out of `reply.txt`. ([#303])
- **2026-06-16** — `cog-build` makes `workspace_in` optional (Cog's `Optional[Path]` plus a `workspace_in_url` string for explicit-URL `pget` parallelism). Empty = fresh run; the cog auto-creates a tempdir `$PASCLAW_HOME`. ([#302])
- **2026-06-16** — `pasclaw build` command + `cog-build/` Replicate cog predictor with **workspace.zip handshake**. `pasclaw build -d "<task>"` orchestrates `pasclaw agent --quiet` with optional `--workspace-in <zip>` (unpack into `$PASCLAW_HOME` before the run) and `--workspace-out <zip>` (pack after). The cog wraps this for Replicate so callers can run long-horizon builds in 30s invocations and round-trip the entire agent brain through one zip URL per call. Default 50 iterations, 4 GiB cap. Sibling to the existing `cog/`. ([#300])
- **2026-06-16** — Checkpoints backend switches to **zpaq**, enabling `/redo` on top of the existing `/undo`. Content-addressable + dedupe-by-default at `workspace/checkpoints/<session>/archive.zpaq` so multi-edit sessions don't bloat history. ([#299])
- **2026-06-16** — `AGENTS.md` project-rules convention (opencode / Codex / Cursor / Zed shape) read from cwd walking up to git root + injected as the system prompt's `## Project Rules` section. New `pasclaw init` command + `/init` slash command scan cwd and ask the model for a starter `AGENTS.md`. ([#298])
- **2026-06-16** — `tool_choice` supports force-a-specific-tool form across providers. Pass a tool / function NAME (anything other than `auto` / `none` / `required`) and each provider emits its native object shape. Gemini ignores `tool_choice` entirely. ([#297])
- **2026-06-16** — Delphi build `IShellBackend` env-injection fix: `ExtraEnv` now reaches spawned children on Delphi/Windows AND Delphi/POSIX (was silently dropped before; FPC paths were already correct). ([#296])
- **2026-06-16** — Knowledgebase native PDF ingest: parses PDF text via FlateDecode + `/ToUnicode` lookup in pure Pascal (no Poppler / `pdftotext` dependency). `pasclaw kb add <file>.pdf` works without preprocessing. Scanned PDFs still need external OCR. ([#295])
- **2026-06-15** — `pasclaw profile diff <a> <b>` (side-by-side comparison of two profiles' resolved field values) + `pasclaw profile bench <profile>` (run the SWE bench fixtures under the named profile, emit aggregated turn-count / tool-call / token stats). Finishes the profile-system follow-ups. ([#292])
- **2026-06-13** — `pasclaw agent --quiet` / `-q` clamps the logger to `llError` so `[info]` startup noise (`web_search disabled`, `mcp[<name>] cache hit`, ...) stays off the stdout pipeline scripts read. Pairs with the banner / assistant-header / per-tool decoration / token-line suppression from PR #243 — Replicate / Lambda / curl callers running `pasclaw agent --quiet -m "..."` now get only the model's reply on stdout. ([#244])
- **2026-06-12** — `dcc64 F2613 Unit 'PasClaw.Otel' not found` fixed by appending `..\pkg\otel` to the Delphi project's `DCC_UnitSearchPath`. Same PR also adds `pasclaw agent --quiet` / `-q` for machine-readable single-turn output: drops banner / assistant header / per-tool decoration / token line; exit code is non-zero on provider misconfiguration or a failed tool loop. ([#243])
- **2026-06-12** — OpenTelemetry traces (OTLP/HTTP+JSON) on the agent loop + gateway HTTP server, off by default. Span hierarchy: `HTTP <method> <route>` (gateway, W3C `traceparent` parsed for parent context) → `openclaw.agent.turn` → `chat <model>` (provider request with `gen_ai.*` attrs) → `execute_tool <name>`. Span shape mirrors openclaw v2026.2+ so Langfuse / Tempo / Jaeger / Honeycomb / Datadog dashboards work without remapping. Flip on via `diagnostics.otel.enabled: true` OR the standard `OTEL_EXPORTER_OTLP_ENDPOINT` env var. ([#242])
- **2026-06-12** — `fs_grep` ripgrep tier 5+6: byte walker replacing `TStringList`/`StringReplace`/per-line `LowerCase` (tier 5), and Boyer-Moore-Horspool substring search replacing `Pos()` (tier 6). 3-5x faster on the per-file path; ~3-10x fewer text-byte reads on patterns the model actually queries (`TODO`, `function`, `class`, `FIXME`). Output byte-identical to the old path. ([#241])
- **2026-06-12** — `fs_grep` ripgrep-inspired tier 1-4 speedups: defer `ComputeFileHash` until the first match in a file (tier 1); skip well-known VCS / build / deps directories by name at walk time — `.git`, `.hg`, `.svn`, `node_modules`, `target`, `build`, `dist`, `vendor`, `.venv`, `__pycache__`, `.gradle`, `.next` — tier 2; NUL-byte binary sniff in first 1 KiB (tier 3); file-size cap (default 10 MiB, override via `max_file_bytes` arg) — tier 4. ([#240])
- **2026-06-11** — Windows `shell_exec` output: auto-detect UTF-8 vs OEM codepage with strict `MB_ERR_INVALID_CHARS` UTF-8 first, fall back to `GetOEMCP`. Catches `pwsh` (PowerShell 6+ defaults to UTF-8 piped output) AND `cmd.exe` (defaults to OEM) without operator config. Replaces an earlier `GetConsoleOutputCP` approach which broke real-world non-ASCII paths like `r�sum�.txt`. ([#239])
- **2026-06-11** — Hashline `fs_read` header mojibake fix: `¶` was rendering as `Â¶` on certain terminals after a `{$CODEPAGE UTF8}` source-page change promoted ASCII byte literals to UnicodeString-like length-1 codepoints. Stamp the full hashline-formatted output as `CP_UTF8` before JSON serialisation so the bytes survive identically across FPC and Delphi. ([#238])
- **2026-06-11** — Windows `shell_exec` output: decode child-process stdout via the OEM codepage instead of assuming UTF-8. Catches `dir /b`, `git status`, `git diff` mojibake on non-ASCII paths. Subsequently refined in #239. ([#237])
- **2026-06-10** — Shell backends (`local` | `docker`) via `IShellBackend`. `shell_exec` and `execute_code` dispatch through an active backend instead of going straight to `/bin/sh -c`. The `docker` backend spawns a per-session container at session start, `docker exec`s into it for every shell call, bind-mounts the workspace at the **same path** inside the container (so `fs_*` from the host and `cat`/`tee` from inside reference the same files — no path translation), and stops it at session end. Hardening win: even a denylist-escaping model can only touch the container, not the host filesystem. `~/.pasclaw/config.json` (provider keys) is deliberately **not** mounted in. ([#233])
- **2026-06-10** — Heartbeat daemon (off by default; `pasclaw onboard` asks to enable). `pasclaw heartbeat` reads `workspace/heartbeat.md` every N minutes (default 30), runs the full agent loop on the body, optionally posts the reply to a named channel. Each tick re-reads the content file so edits land on the next tick without restarting the daemon. Same PR also wires **reversible condensation (CCR)** — destructive condensers (JSON shrink, shell-output filters) stash the original under a fresh `tool_output_get` handle so the model defaults to the structural view but can recall the verbatim bytes via one tool call. ([#232])
- **2026-06-10** — Four-feature batch: (1) `send_message` model-facing tool — post a message to a named, operator-configured channel mid-task (`channels[]` in `config.json`); the model can only reach endpoints the operator pre-declared. (2) ~14 more per-command shell-output condenser families: compile walls (`cargo build`/`check`/`clippy`), linters (eslint stylish), package managers (`npm install`/`pip install`), build systems (`mvn`/`gradle`), IaC (`terraform plan`/`apply`), tabular CLIs (`docker ps`, `kubectl get`, `gh`), JSON output (`aws`). (3) Promptware defense — substring-pattern scan over three indirect-input chokepoints (tool output, recalled memory, stored skills) with annotate-don't-block semantics for chokepoints 1-2 and suppress-outright for SKILL.md descriptions. (4) Task-aware MEMORY.md slicing via `orient_task_aware: true`. ([#230])
- **2026-06-09** — `pasclaw /goal` Ralph loop with judge model: auto-continues turn after turn until a judge model verdict of `MET` / `FAILED` / `CONTINUE`. Same PR also adds a JSON-aware tool-output condenser that collapses MCP search responses into structural summaries while preserving keys. ([#223])
- **2026-06-09** — `/undo` wired into `pasclaw agent` (interactive) and the sample dprojs (was TUI-only). ([#222])
- **2026-06-09** — Checkpoints: auto-snapshot files BEFORE `fs_write` / `fs_edit_hashline` overwrites them; TUI `/undo` reverts the last edit (opt-in via `checkpoints.enabled: true`). Snapshot store under `workspace/checkpoints/<session>/<seq>.json`; dedupe within a turn so multi-edit sequences don't snapshot the same file twice. ([#221])
- **2026-06-09** — `pasclaw mcp catalog`: lenient hub-projector accepts the slim summary shape the pasclaw.dev MCP hub returns (previously rejected 10 of 39 entries as "non-HTTP transports not supported" when those entries were actually fine). ([#220])
- **2026-06-09** — `pasclaw mcp` accepts SSE-tagged, Streamable HTTP, and stdio hub transports (was HTTP-only). The 10 previously-dropped entries become installable. ([#219])
- **2026-06-09** — Inbound MCP server mode: `pasclaw gateway` (and `pasclaw mcp stdio`) serve PasClaw's curated tools (`memory_search`, `kb_search`, `SCARS`, ...) over MCP so other agents (Claude Code, Cursor, etc.) reach PasClaw's state live. The inbound MCP server defaults to read-only; `--mcp-allow-write` opts in to mutating tools. `--mcp-port <p>` spawns a second listener on the named port that honours only MCP routes plus `/v1/health` (isolation for different firewall rules). ([#218])
- **2026-06-09** — `pasclaw onboard` offers to index documents into the knowledgebase as part of setup. ([#217])
- **2026-06-09** — Knowledgebase: RAG over operator-curated documents (`pasclaw kb add ~/docs/`). FTS5 BM25 ranking by default; auto-upgrades to **hybrid keyword + vector** with Reciprocal Rank Fusion when the local embedding runtime is provisioned (`pasclaw memory provision`). Two read-only tools (`kb_search` / `kb_get`) auto-register once at least one source is registered. Documents are indexed **in place** (never copied) into `workspace/kb.db`. Supports markdown, plain text, HTML, and common source-code extensions; PDFs require external conversion. Unlike `memory_search`, the KB does NOT re-index on every query — `pasclaw kb sync` is the explicit refresh. ([#214])
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
[#214]: https://github.com/FMXExpress/PasClaw/pull/214
[#217]: https://github.com/FMXExpress/PasClaw/pull/217
[#218]: https://github.com/FMXExpress/PasClaw/pull/218
[#219]: https://github.com/FMXExpress/PasClaw/pull/219
[#220]: https://github.com/FMXExpress/PasClaw/pull/220
[#221]: https://github.com/FMXExpress/PasClaw/pull/221
[#222]: https://github.com/FMXExpress/PasClaw/pull/222
[#223]: https://github.com/FMXExpress/PasClaw/pull/223
[#230]: https://github.com/FMXExpress/PasClaw/pull/230
[#232]: https://github.com/FMXExpress/PasClaw/pull/232
[#233]: https://github.com/FMXExpress/PasClaw/pull/233
[#237]: https://github.com/FMXExpress/PasClaw/pull/237
[#238]: https://github.com/FMXExpress/PasClaw/pull/238
[#239]: https://github.com/FMXExpress/PasClaw/pull/239
[#240]: https://github.com/FMXExpress/PasClaw/pull/240
[#241]: https://github.com/FMXExpress/PasClaw/pull/241
[#242]: https://github.com/FMXExpress/PasClaw/pull/242
[#243]: https://github.com/FMXExpress/PasClaw/pull/243
[#244]: https://github.com/FMXExpress/PasClaw/pull/244
[#292]: https://github.com/FMXExpress/PasClaw/pull/292
[#295]: https://github.com/FMXExpress/PasClaw/pull/295
[#296]: https://github.com/FMXExpress/PasClaw/pull/296
[#297]: https://github.com/FMXExpress/PasClaw/pull/297
[#298]: https://github.com/FMXExpress/PasClaw/pull/298
[#299]: https://github.com/FMXExpress/PasClaw/pull/299
[#300]: https://github.com/FMXExpress/PasClaw/pull/300
[#302]: https://github.com/FMXExpress/PasClaw/pull/302
[#303]: https://github.com/FMXExpress/PasClaw/pull/303
[#304]: https://github.com/FMXExpress/PasClaw/pull/304
[#306]: https://github.com/FMXExpress/PasClaw/pull/306
[#307]: https://github.com/FMXExpress/PasClaw/pull/307
[#309]: https://github.com/FMXExpress/PasClaw/pull/309
[#310]: https://github.com/FMXExpress/PasClaw/pull/310
[#312]: https://github.com/FMXExpress/PasClaw/pull/312
[#314]: https://github.com/FMXExpress/PasClaw/pull/314
[#315]: https://github.com/FMXExpress/PasClaw/pull/315
[#316]: https://github.com/FMXExpress/PasClaw/pull/316
[#317]: https://github.com/FMXExpress/PasClaw/pull/317
[#318]: https://github.com/FMXExpress/PasClaw/pull/318
[#343]: https://github.com/FMXExpress/PasClaw/pull/343
[#600]: https://github.com/FMXExpress/PasClaw/pull/600
[#604]: https://github.com/FMXExpress/PasClaw/pull/604
[#606]: https://github.com/FMXExpress/PasClaw/pull/606
[#608]: https://github.com/FMXExpress/PasClaw/pull/608
[#609]: https://github.com/FMXExpress/PasClaw/pull/609
[#611]: https://github.com/FMXExpress/PasClaw/pull/611
[#612]: https://github.com/FMXExpress/PasClaw/pull/612
[#613]: https://github.com/FMXExpress/PasClaw/pull/613
[#614]: https://github.com/FMXExpress/PasClaw/pull/614
[#615]: https://github.com/FMXExpress/PasClaw/pull/615
[#616]: https://github.com/FMXExpress/PasClaw/pull/616
[#617]: https://github.com/FMXExpress/PasClaw/pull/617
[#618]: https://github.com/FMXExpress/PasClaw/pull/618
[#619]: https://github.com/FMXExpress/PasClaw/pull/619
[#622]: https://github.com/FMXExpress/PasClaw/pull/622
[#623]: https://github.com/FMXExpress/PasClaw/pull/623
[#624]: https://github.com/FMXExpress/PasClaw/pull/624
[#625]: https://github.com/FMXExpress/PasClaw/pull/625
[#626]: https://github.com/FMXExpress/PasClaw/pull/626
[#627]: https://github.com/FMXExpress/PasClaw/pull/627
[#628]: https://github.com/FMXExpress/PasClaw/pull/628
[#629]: https://github.com/FMXExpress/PasClaw/pull/629
[#630]: https://github.com/FMXExpress/PasClaw/pull/630
[#631]: https://github.com/FMXExpress/PasClaw/pull/631
[#632]: https://github.com/FMXExpress/PasClaw/pull/632
[#633]: https://github.com/FMXExpress/PasClaw/pull/633
[#634]: https://github.com/FMXExpress/PasClaw/pull/634
[#635]: https://github.com/FMXExpress/PasClaw/pull/635
[#636]: https://github.com/FMXExpress/PasClaw/pull/636
[#637]: https://github.com/FMXExpress/PasClaw/pull/637
[#638]: https://github.com/FMXExpress/PasClaw/pull/638
[#639]: https://github.com/FMXExpress/PasClaw/pull/639
[#640]: https://github.com/FMXExpress/PasClaw/pull/640
[#641]: https://github.com/FMXExpress/PasClaw/pull/641
