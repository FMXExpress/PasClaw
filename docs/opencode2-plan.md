# Six things from OpenCode 2.0: a plan

OpenCode 2.0 is a re-architecture more than a feature release: one shared
service behind every client, a rebuilt plugin API, and a hosted console.
Most of what it ships PasClaw already has in some shape. Six things are
worth taking, in this order, and a survey of the code for each turned up
four defects to fix before any of them land. This page is the plan; the
facts are from reading `src/` on main at #606.

## Fix first: what the survey found

These are not new features. They are the reason the permission work below
has to start where it does, and each is a small PR on its own.

1. **The tool RPC bypasses every dispatch gate.** `execute_code` scripts
   call tools with `pasclaw __tool <name> '<json>'`, which reaches
   `TToolRPCServer` and then `Registry.RunTool` directly
   (`PasClaw.Tools.RPC.pas:345`). Plan-mode and space-mode refusal, hooks,
   preflight and the promptware scan all live in `DispatchOneToolCall`
   (`PasClaw.Tools.ToolLoop.pas:724`), which the RPC never calls. A plan-mode
   turn can therefore mutate through a script. Fix: route RPC calls through
   `DispatchOneToolCall` with the loop's `Cfg` (mode, hooks, active config),
   and apply the OutputCache cap the RPC comment at `:51` promises and does
   not do.
2. **Subagent isolation does not hold for scripts.** `BuildFilteredRegistry`
   (`PasClaw.Agent.Subagent.pas:185-235`) copies the parent's `execute_code`
   record, `HandlerObj` included, so a subagent's script dispatches into the
   parent's full registry. Fix: re-register `execute_code` per filtered
   registry.
3. **Shell skills skip the denylist.** Kind `shell` skills run `RunOneShot`
   with no `ShellAllowed` and not through the shell backend
   (`PasClaw.Skills.Loader.pas:227-250`), and `RegisterSkills` leaves
   `Category` unset. Fix: `ShellAllowed` on the rendered command, run via
   the backend, `tcMutating`.
4. **`shell_exec` has no timeout.** The only bound is the 1 MiB output cap
   (`PasClaw.Platform.pas:54`). Item 2 below adds the timeout as part of
   async shell; until then a hung command hangs the turn.

## 1. Code Mode for MCP servers

**What OpenCode does.** MCP servers default to `codemode: true`: their
tools are not sent as schemas. The agent calls `execute` with a short
JavaScript program in which tools appear as functions,
`tools.github.list_issues(...)`, chained in one script. Only the script's
final output reaches the model, so a list-then-filter-then-fetch sequence
costs one round and no intermediate context. The sandbox has no
filesystem, imports, timers or `fetch`; `execute` has its own permission
and nested calls keep theirs. Git worktree tools are exposed the same way.

**What PasClaw has.** Two of the three parts. `execute_code` materialises a
bash or PowerShell body and runs it (`PasClaw.Tools.ExecuteCode.pas:412`);
inside, `pasclaw __tool <name> '<json>'` reaches a per-call RPC server
bound on `127.0.0.1` with a token in `$PASCLAW_TOOL_RPC_INFO`
(`:465-471`, `PasClaw.Tools.RPC.pas:177-239`). Every registry tool is
reachable, deferred MCP tools included. MCP tools already register as
deferred under `mcp_progressive_disclosure` and `tool_search` reveals them
(`PasClaw.MCP.Bridge.pas:397-426`, `PasClaw.MCP.Disclosure.pas:309`). What
is missing is the shape the model sees: nothing but the tool description
mentions `__tool`, the system prompt never does, the binary has to be on
PATH, and the Docker backend does not mount it.

**Design.** Keep bash and PowerShell. A JavaScript sandbox is a new runtime
to carry; the win is in what the model sees and what the prompt costs, not
in the language.

- **Per-server mode.** `mcp_servers[].codemode` (default `true`, mirrors
  OpenCode). A codemode server's tools are registered deferred and
  *hidden from `tool_search`*: they never become provider tool schemas at
  all. They stay callable through the RPC.
- **A catalog the script can read.** New RPC verb `catalog` returning
  `{server, tool, description, schema}` for codemode tools, and a hidden
  tool `code_catalog(server?)` so the model can ask without a script. The
  `## Deferred Tools` section lists codemode servers by name with one line:
  "call from `execute_code` with `pasclaw __tool <server>__<tool> '<json>'`".
- **Make the call cheap to write.** Export `PASCLAW_BIN` into the script's
  environment (the resolved path of the running executable) and a shell
  function in the prologue, so the model writes `tool github__list_issues
  '{"repo":"x"}'` and pipes to `jq`. On Docker, mount the binary read-only
  at `/usr/local/bin/pasclaw` (`PasClaw.Shell.Backend.Docker.pas:358-370`).
- **Gates.** Depends on fix 1. The RPC path dispatches through
  `DispatchOneToolCall`, so plan mode refuses mutating MCP tools from a
  script exactly as from a direct call, and hooks fire.
- **Prompt.** A short paragraph in the rules section: when a task chains
  several tool calls or filters a large result, write one `execute_code`
  script and return only what matters.

**Config.** `mcp_servers[].codemode: true|false`; `mcp_codemode_default`
(global, default `true`) so an operator can turn the behaviour off in one
place.

**Tests.** RPC through dispatch (plan mode refuses a `tcMutating` MCP tool
from a script; a hook sees it); codemode servers absent from
`ToProviderDefs` and from `tool_search` results; `code_catalog` lists them;
`PASCLAW_BIN` set and the prologue function works under FPC's shell path;
a measured prompt-size delta with the Replicate or GitHub MCP catalog
loaded, recorded in `docs/agent-features.md`.

**Size.** Medium. Two days of focused work plus the fix-first items.

## 2. Async shell and the background key

**What OpenCode does.** A shell call can run in the background and notify
the agent when it finishes; background calls have no timeout unless set.
In the TUI, `Ctrl+B` moves running foreground work to the background.

**What PasClaw has.** `shell_exec` is synchronous with no timeout
(`PasClaw.Tools.Shell.pas:93`). Background *subagents* exist:
`spawn_background` / `spawn_status` / `spawn_wait` / `spawn_cancel`,
capped at four, with results drained into the next provider call's system
prompt through `GBackgroundDrainHook` when `Cfg.BackgroundDrainKey` is set
(`PasClaw.Agent.SubagentBg.pas:777-866`, `ToolLoop.pas:1905-1914`). The
TUI and CLI set the key; the gateway and serve register the tools and never
set it, so a gateway turn can start a background subagent and never hear
back. The TUI's `Ctrl+B` already exists and cycles mode (`TUI.pas:2048`).

**Design.**

- **`shell_exec` gains `timeout_sec`** (default from new config
  `shell.timeout_sec`, default 600; 0 = none) and `background: true`.
  A background call returns a handle `sh-<6hex>` immediately. Reuse the
  `TBgJob` machinery with a new job kind rather than a second coordinator:
  one map, one drain hook, one cap (`MaxConcurrentBackground`, raised to
  6 to leave room). `spawn_status` / `spawn_wait` / `spawn_cancel` accept
  shell handles; cancel actually kills the process group, which is the one
  place the "advisory" cancel of subagents is not acceptable for a shell.
- **Completion wakes an idle parent.** Today results reach the model only
  while a loop is running. Add a `PushSteering` of a short
  `[background shell finished: sh-xxxx, exit=N]` line to the session's
  steering key when the loop is idle, so the next user turn, or a
  heartbeat tick, sees it. In the gateway, also emit a desktop event
  (`PasClaw.Desktop.Events.pas`) so the web UI can show it.
- **Gateway sets the drain key.** `BackgroundDrainKey := ReqSession` at the
  four `LoopCfg` builders. This is a one-line fix with its own test; ship it
  first.
- **TUI.** `Ctrl+B` keeps its meaning. Add `Ctrl+Shift+B` (or `/bg`) that
  detaches the running loop: the worker continues, its result lands via
  the steering path above, and the input unlocks. The FPC line-mode TUI
  gets `/bg` only.
- **Docker backend.** Background runs need the container to outlive the
  tool call; the session container already does (`pasclaw-<session>`).

**Config.** `shell.timeout_sec`, `shell.background_max`.

**Tests.** Timeout kills and reports `exit=124`; a background call returns
a handle and `spawn_wait` collects it; cancel kills a `sleep 1000`; the
gateway drains results (currently untested because it never could);
idle-parent steering line appears on the next turn.

**Size.** Medium. The drain-key fix is tiny and should not wait for the rest.

## 3. Ordered permissions and pushed policies

**What OpenCode does.** `permissions` is an ordered array of rules, each
with a tool pattern, a resource pattern and an effect of `allow`, `deny`
or `ask`; the last matching rule wins. `policies` is a separate list a
workspace server can push that hard-denies providers, tools, MCP servers,
skills and plugins and cannot be overridden by local config.

**What PasClaw has.** Four unrelated gates, each with its own config:
plan-mode and space-mode refusal of `tcMutating` tools (`ToolLoop.pas:749-775`);
the sandbox's shell denylist and path rules (`PasClaw.Tools.Sandbox.pas`,
keys under `sandbox`); family switches (`web_fetch_enabled`,
`cron_tool_enabled`, …); and `TPasClawHook.BeforeToolCall`, which the
browser uses to ask the user. There is no per-tool allow or deny list, no
`ask` outside the browser, and no way for the gateway to push a rule set.
`PUT /v1/config` applies providers live but marks sandbox and MCP
restart-only (`Server.pas:1407`).

**Design.**

- **One rule list.** `permissions: [{tool, resource?, effect}]`, `tool`
  a glob over tool names (`shell_exec`, `fs_*`, `github__*`), `resource` a
  glob over the tool's primary argument (the command string, the path, the
  URL), `effect` `allow | deny | ask`. Last match wins; no match falls
  through to today's behaviour, so an empty list changes nothing.
  Evaluated in `DispatchOneToolCall` after the mode check and before
  `RunTool`, which, after fix 1, covers scripts too.
- **`deny` is a synthetic result,** worded like `PlanModeRefusal`, so the
  model is told and moves on.
- **`ask` needs an asker.** The hook surface already has one shape
  (`TConfirmFn` in the browser). Promote it: `TToolLoopConfig.OnAsk:
  function(const Name, ArgsJSON, Reason: string): TAskAnswer` with
  `allow once / allow for session / deny`. The TUI answers in a footer
  prompt; the gateway answers through a new `permission_request` desktop
  event and `POST /v1/permissions/<id>` from the web UI, with a timeout
  that denies; the CLI in `--quiet` denies; the component exposes it as
  `OnAsk`. A rule with `ask` and no asker denies, as the browser's hook
  does today.
- **Policies.** `policies: [{deny: provider|tool|mcp|skill, match}]`, same
  evaluator, but loaded from a separate file `$PASCLAW_HOME/policies.json`
  that `PUT /v1/config` cannot touch and that the gateway re-reads on its
  config mtime watch. Applied live: a deny here needs no restart because it
  is checked at dispatch. The team case is a gateway that owns the file;
  the single-user case never sees it.
- **Fold the existing gates in, do not replace them.** The shell denylist
  stays as the floor beneath the rule list. Plan mode stays a mode. The
  family switches stay as registration-time toggles. The rule list is the
  layer an operator edits.

**Config.** `permissions[]`, `policies.json`; `pasclaw permissions list |
test <tool> <resource>` to show which rule fires.

**Tests.** Last-match-wins, glob matching, deny result text, `ask` without
an asker denies, `ask` with a fake asker honours each answer, policy file
beats config, a script call is subject to the same rule, the gateway
request/answer round trip with a timeout.

**Size.** Large. Split: evaluator plus `deny` (one PR); `ask` with the TUI
and component askers (one PR); gateway asker and policies (one PR).

## 4. Git worktree tools

**What OpenCode does.** `worktree_create`, `worktree_list`,
`worktree_remove`, so parallel subagents edit in separate checkouts.
Removal needs edit approval; force removal can discard changes.

**What PasClaw has.** No git helpers at all; the only git awareness is
`FindProjectAgentsMd` stopping at `.git`. Subagents run against the
process-global sandbox workspace (`GWorkspace`, `Sandbox.pas:138`) and the
global shell session id, so two background subagents editing files collide
in the same tree.

**Design.**

- **Three tools** in a new `PasClaw.Tools.Worktree` unit, shelling out to
  `git worktree` through the shell backend (so Docker and the denylist
  apply): `worktree_create(branch, base?)` under `worktree.directory`
  (default `<repo>/../<repo>-worktrees/<branch>`), `worktree_list`,
  `worktree_remove(path, force?)`; `remove` is `tcMutating`, `force`
  refuses when `git status --porcelain` is non-empty unless the permission
  layer allowed it.
- **Subagents take a cwd.** `TSubagentContext` gains `Workspace`;
  `spawn` / `spawn_background` accept `worktree: "<branch>"` which creates
  one and runs the child with its sandbox workspace and shell cwd pointed
  there. This needs the sandbox workspace to stop being process-global for
  the child: a threadvar override read by `CurrentWorkspace`, set for the
  child thread, the same trick `SetThreadWorkspace` uses for agent data
  worlds.
- **Sessions remember their location.** `TSessionMeta.Location` (the
  directory), shown by `session list` and used by `resume`.

**Config.** `worktree.directory`.

**Tests.** Against a temp git repo: create / list / remove round trip,
force refusal with dirty tree, a background subagent given a worktree
writes there and not in the parent tree, thread override does not leak to
the parent.

**Size.** Small for the tools, medium with the subagent cwd. Ship the tools
first; they are useful to the main agent alone.

## 5. Attach mode: one session list across surfaces

**What OpenCode does.** One local service; terminal, desktop and web are
clients of it and share one session database. `opencode pair` hands a
browser a short-lived login.

**What PasClaw has.** The gateway already serves web, desktop and studio
with `/v1/sessions`, `/v1/chat/completions` (streaming, `X-PasClaw-Session`,
`session_context`) and SSE tool frames. The CLI and TUI run their own loop
against the same session files with no cross-process lock
(`SessionTurnLock` is in-process, `Session.Store.pas:912`), the TUI does
not call `BuildSystemPrompt` (so no memory or AGENTS.md in TUI turns), and
`TPasClawClient.Chat` sends full history with no session header
(`PasClaw.Client.Api.pas:2461`). There is no port file, so a client cannot
discover a running gateway.

**Design.** Not a rewrite. Make the gateway the owner when it is running
and leave the in-process path for when it is not.

- **Discovery.** The gateway writes `$PASCLAW_HOME/run/gateway.json`
  (`{port, pid, token_hash, started_at}`) on start and removes it on stop;
  `pasclaw status` reads it. Stale files (dead pid) are ignored.
- **`pasclaw tui --attach` / `pasclaw agent --attach`** (and `attach: auto`
  in `cli` config, default `off` for now): when a live gateway is found,
  the TUI becomes a client. It uses `TPasClawClient` with `X-PasClaw-Session`
  and `session_context: true`, so the gateway holds the transcript and the
  turn lock; the TUI sends one message per turn, renders the SSE stream and
  the `pasclaw-tool` frames it already parses. Session list, new, resume
  and delete go through `/v1/sessions`. Steering goes through `/v1/steer`.
- **Fix the client first.** `TPasClawClient.Chat` gains `SessionId` and
  `SessionContext`; this is also what the browser desktop should have used.
- **TUI parity in local mode.** Call `BuildSystemPrompt` so a local TUI turn
  sees memory, facts and AGENTS.md like the CLI does. Independent of attach
  and overdue.
- **Live attach to a running turn** (watching a turn the web UI started) is
  a second step: an SSE endpoint `GET /v1/sessions/<id>/events` fed from
  the existing `TSSEStreamer`. Without it, attach mode shows a turn's
  result when it finishes, which is enough for v1.
- **Pairing** is `gateway.token` plus the URL; a `pasclaw pair` that prints
  a one-time token and QR is cosmetic and can wait.

**Config.** `cli.attach: auto|on|off`.

**Tests.** Port file written and cleared; stale pid ignored; the client
sends the session header and the gateway merges context (currently
untested because no client sends it); a TUI turn in local mode carries the
memory section.

**Size.** Medium. The client fix and the TUI prompt parity are small and
should go first.

## 6. Small ones

Each is an afternoon, each has a test, and none depends on the others.

- **Command arguments for prompt skills.** `RenderTemplate` knows only
  `{{key}}` from JSON args (`Loader.pas:180`). Add `$ARGUMENTS`, `$1..$9`
  with quoted grouping and last-absorbs-rest, and let a prompt skill carry
  `agent:` (subagent spec name), `model:` and `subagent: true` in its
  frontmatter, so `/deploy staging` runs the template on the named model
  in a child session. Register prompt skills as TUI slash commands: today
  the slash list is a hardcoded if-chain (`TUI.pas:1729-1790`); replace it
  with a small registry the skills loader can add to.
- **`instructions` list.** Beside AGENTS.md discovery, `instructions:
  ["docs/style.md", "rules/*.md", "https://…/team.md"]` appended to the
  project-rules section, each capped like AGENTS.md (`ProjectRulesMaxBytes`),
  URLs fetched through `web_fetch`'s guard with a 24 h cache, the one
  `memory_fetch` already keeps.
- **Prompt-cache keep-alive.** `prompt_cache.warm: true` (default off):
  after four minutes idle, one minimal request every four minutes until
  thirty minutes since the last real turn, same system block and tools so
  the prefix matches. Worth little with the one-hour TTL PasClaw defaults
  to; worth something for operators who set `5m`. Lives in the gateway's
  existing ticker alongside `TTeamTickThread`. Count the pings in
  `/v1/stats` so the cost is visible.
- **`shell_exec` timeout** is in item 2 but can ship alone.
- **Image limits for `fs_read`.** `media.image.{max_width, max_height,
  max_base64_bytes}` with auto-resize, the one OpenCode knob PasClaw lacks
  on the read path. Only if the desktop's image reads are hitting provider
  limits; otherwise skip.

## Order

| PR | contents | why first |
|---|---|---|
| A | fix-first items 1–4, gateway sets `BackgroundDrainKey`, `TPasClawClient` session header, TUI uses `BuildSystemPrompt` | every one is a correctness gap today |
| B | Code Mode for MCP (item 1) | the cost win; depends on A |
| C | async shell with timeout, `/bg` (item 2) | depends on A's drain fix |
| D | permissions evaluator with `deny`, then `ask`, then policies (item 3) | depends on A so scripts are covered |
| E | worktree tools, then subagent cwd (item 4) | makes C's parallelism safe |
| F | attach mode (item 5) | depends on A's client fix |
| G | the small ones (item 6), any order | independent |

Not taken from OpenCode 2.0: the plugin system and its hot reload (MCP,
skills and the component's hooks are PasClaw's extension points), the
hosted console and the Go subscription, and dropping LSP (never present).
