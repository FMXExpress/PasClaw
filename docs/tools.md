# Tools

PasClaw exposes a fixed set of tools to the model on every turn (plus MCP-bridged tools when MCP servers are configured, plus `skill_<name>` tools from registered skills). Source: `src/pkg/tools/`.

## Catalog

| Tool | What it does |
|---|---|
| `fs_read` | Read a file, return hashline-formatted text (`¶path#hash` header + LINENO-prefixed body). |
| `fs_write` | Write a file. Refuses missing `content` (truncated tool-call signal). |
| `fs_list` | List a directory. |
| `fs_grep` | Recursive substring search. Returns hashline-formatted matches. |
| `fs_edit_hashline` | Apply a hashline patch (line-anchor + file-hash header). Race-safe: stale patches abort without writing. |
| `shell_exec` | Run a shell command. Output capped at 1 MiB; denylist-gated. |
| `execute_code` | Run a multi-line bash or PowerShell script. Same sandbox as `shell_exec`. |
| `web_search` | DuckDuckGo / Brave / Tavily / SearXNG / Perplexity / Gemini-grounding (6 providers). |
| `web_fetch` | HTTP GET → readable plain text. SSRF-guarded. Off by default. |
| `memory_search` | SQLite FTS5 BM25 (+ optional hybrid vector) over `workspace/memory/*.md` and `MEMORY.md`. |
| `memory_fetch` | Fetch a URL and write it to `workspace/memory/fetched-*.md` (URL auto-dedup within 24h). |
| `session_search` | FTS5 over the full text of every saved session under `workspace/sessions/`. |
| `kb_search` | FTS5 + optional vector over the operator-curated knowledgebase. |
| `kb_get` | Expand a `kb_search` citation into full chunk text ± neighbouring chunks. |
| `vault_search` / `vault_get` | Search + read pasclaw.dev Code Vault entries (Object Pascal samples). Opt-in. |
| `send_message` | Post to a named operator-configured channel (Discord / Slack / Teams / generic webhook / LINE / WhatsApp). |
| `tool_output_get` | Retrieve the verbatim bytes of a previously condensed or truncated tool result by handle. |
| `spawn` | Run a focused subagent (filtered tool registry + specialist system prompt). Returns when the subagent's loop returns. |
| `spawn_background` | Same, asynchronous. Returns a handle; parent loop keeps working. |
| `spawn_status` / `spawn_wait` / `spawn_cancel` | Manage background-subagent handles. |
| `skill_<name>` | Pascal-side tools registered from `kind: shell` / `kind: prompt` skills. |
| MCP-bridged | Every tool a configured MCP server exports — see [MCP servers](./mcp.md). |

## Filesystem tools

All filesystem paths go through `PasClaw.Tools.Sandbox` before the underlying syscall. When `sandbox.restrict_to_workspace: true`, reads and writes outside the workspace are refused with a `Reason` the model sees. See [Security](./security.md).

### Hashline format

`fs_read` returns content with a header and prefixed lines:

```
¶src/main.pas#a1b2
1:program main;
2:
3:begin
4:  WriteLn('hi');
5:end.
```

The header carries a short content hash so `fs_edit_hashline` can detect stale patches. `fs_grep` emits the same `¶path#hash` header before each section of matches. The model can paste anchors directly back into `fs_edit_hashline`.

### `fs_edit_hashline`

Patches by line anchor + file-hash check. Race-safe: if the file changed since the hash in the patch header, the edit aborts without writing. Operations supported: replace, insert, delete by line range; multiple sections per call. See the inline comments in `src/pkg/hashline/PasClaw.Hashline.pas` for the patch grammar.

### `fs_grep` — ripgrep-inspired

Six tiers of optimisation layered on the recursive scan:

1. **Deferred hashing** — `ComputeFileHash` only fires on the first match in a file.
2. **Blocked-dir skip** — `.git`, `node_modules`, `target`, `build`, `dist`, `vendor`, `.venv`, `__pycache__`, `.gradle`, `.next`, `.hg`, `.svn` pruned at walk time.
3. **Binary file sniff** — NUL byte in first 1 KiB → skip without reading.
4. **File-size cap** — default 10 MiB, override per call via `max_file_bytes`.
5. **Byte walker** — no `TStringList` / `StringReplace` / per-line `LowerCase`; splits on `#10` in place with CRLF trim.
6. **Boyer-Moore-Horspool** — substring search replaces `Pos()`.

## Shell tools

### `shell_exec`

Runs `/bin/sh -c <cmd>` on POSIX or `cmd.exe /C <cmd>` on Windows. Output capped at 1 MiB. Denylist-gated via `PasClaw.Tools.Sandbox.ShellAllowed`. Per-command condensers run on successful output (tee-on-failure: full output passes through on non-zero exit). Filter coverage: `git status/diff/log`, `pytest`/`cargo test`/`npm test`/`go test`, `grep`/`Select-String`/`findstr`, recursive `ls`/`find`/`Get-ChildItem`, tabular CLIs (`docker ps`, `kubectl get`, `gh`), `docker build`, log tails, compiler walls, linters, package managers, build systems, IaC, `aws` JSON. PowerShell-alias normalisation included. See [`src/pkg/tools/PasClaw.Tools.Shell.Filters.pas`](../src/pkg/tools/PasClaw.Tools.Shell.Filters.pas).

### `execute_code`

Model writes a multi-line bash or PowerShell script body via `execute_code({lang, code})`. PasClaw materialises it to `$PASCLAW_HOME/tmp/exec-*.{sh,ps1}`, spawns the right shell (`bash <file>` on unix, `pwsh -NoProfile -ExecutionPolicy Bypass -File <file>` on Windows), captures combined stdout+stderr, cleans up. Same `ShellAllowed` denylist runs against the script body — a buried `rm -rf /` in a heredoc gets refused identically to the inline form. Cwd pinned to the workspace when `sandbox.restrict_to_workspace`.

The big win: fan-out patterns (list every `*.pas`, grep each for a symbol, summarise hits) that would take `1 + N + 1` inference rounds under `shell_exec` collapse to one tool call.

### Tool-RPC callback (`pasclaw __tool`)

When `execute_code` spawns a script, PasClaw starts a loopback TCP server on a kernel-allocated port and writes the port + a fresh 32-hex token to `$PASCLAW_HOME/run/tool-rpc.json`. Inside the script the model can call back into the same tool registry:

```bash
for f in $(pasclaw __tool fs_list '{"path":"src/"}' | jq -r .files[]); do
  pasclaw __tool memory_search "{\"q\":\"$f\"}"
done
```

Bad tokens get rejected at the wire level. Same registry the model is using; same sandbox + denylist + output-cap path. `pasclaw __tool` is the internal subcommand — not in `--help`.

## Search tools

### `web_search(query, k?)`

Returns up to `k` results as title + URL + snippet. Provider configured under `web_search.provider`. See [Web search](./web-search.md).

### `web_fetch(url, max_chars?)`

Fetches an `http://` or `https://` URL and returns the response body as readable plain text (HTML tags stripped, entities decoded, whitespace collapsed). Cap default 50 KB. SSRF-guarded: refuses IPv4 hosts in RFC1918 / loopback / link-local ranges including `169.254.169.254` (cloud metadata). Initial URL and every redirect hop both checked.

Registered only when `web_fetch_enabled: true`.

## Memory + knowledgebase tools

See [Memory](./memory.md) and [Knowledgebase](./knowledgebase.md).

## `send_message`

Post a message to a named, operator-configured channel mid-task. Configured via `config.json`:

```json
"channels": [
  { "name": "ops",    "kind": "discord", "target": "https://discord.com/api/webhooks/..." },
  { "name": "alerts", "kind": "slack",   "target": "https://hooks.slack.com/..." }
]
```

The model addresses channels strictly by `name`, so it can only reach endpoints the operator pre-declared (no model-supplied URLs). Registered only when `channels[]` is non-empty.

## `tool_output_get(handle, offset, length)`

Retrieves the verbatim bytes of a tool result that was condensed (`condense_reversible: true`) or truncated (`tool_output_cap > 0`). Handle id appears in the inline footer the model sees:

```
[condensed 187432 -> 4096 bytes; full original at handle="oc_a1b2c3" via tool_output_get]
[tool output truncated: 50000 bytes, handle=oc_d4e5f6]
```

Registers whenever either feature is on.

## Subagent tools

### `spawn(agent, prompt)` (synchronous)

Runs a focused subagent loop and returns the result as the parent's `tool_result`. Each entry in `config.json`'s `subagents[]` registers a callable specialist:

```json
"subagents": [
  { "name": "researcher",
    "description": "Web search + summary specialist",
    "system_prompt": "...",
    "tools": ["web_search", "web_fetch"],
    "max_iterations": 4 }
]
```

The subagent inherits the parent's provider + fallback chain; the tool registry is filtered to the named tools; the system prompt is the specialist one. Implementation: `src/pkg/agent/PasClaw.Agent.Subagent.pas`.

### `spawn_background(agent, prompt)` (asynchronous)

Returns a handle and the parent loop keeps working. When the job finishes its result is pushed into the next loop iteration as a `[background subagent results]` block in the system prompt (same channel `pasclaw steer` uses). Companion tools: `spawn_status(handle)`, `spawn_wait(handle, timeout_sec)`, `spawn_cancel(handle)`. Up to 4 concurrent jobs per session. Jobs die with the session — coordinator teardown abandons still-running workers and they self-free.

## Parallel dispatch

When the model returns multiple `tool_use` blocks in one turn, read-only tools (`web_search`, `web_fetch`, `fs_read` / `fs_grep` / `fs_list`, `memory_search`) fan out on worker threads; mutating tools (`fs_write`, `fs_edit_hashline`, `shell_exec`, `execute_code`) stay serial. ~50% wall-clock win on multi-network-tool turns.

Set `"parallel": false` in your `TToolLoopConfig` (embedders) or use `--no-parallel` (TUI) to force serial dispatch.

## Output condensation

Two layers, both opt-in:

1. **`tool_output_cap`** (bytes) — when set, oversize tool results get diverted into a process-lifetime cache; the in-context body becomes `[tool output truncated: N bytes, handle=...]` plus a head + tail snippet. The model dereferences via `tool_output_get`.

2. **`condense_reversible`** (default `true`) — JSON condenser and shell-output filters collapse structural output (e.g. a 200 KB MCP search response into a 4 KB structural summary); the original bytes get stashed under a `tool_output_get` handle named in the footer. The model defaults to the structural view and pulls the verbatim bytes when the shape isn't enough.

Both use the same `PasClaw.Tools.OutputCache` store. Errors stay verbatim regardless of cap (they're short, and a head/tail split would obscure the failure).

## Promptware defense

`PasClaw.Promptware` runs a substring-pattern scan on three indirect-input chokepoints:

1. **Tool output** — scanned in `RunToolLoop` after JSON condensation. Hits get a `[promptware-warning]` banner naming the matched rule and source prepended; the content still reaches the model intact (false positives — a security blog quoting an injection — survive).
2. **Recalled memory** — `memory_search` snippets, which re-enter the context looking like the agent's own notes.
3. **Stored skills** — SKILL.md descriptions advertised verbatim inside the system prompt. Flagged descriptions get suppressed outright (a banner inside the system prompt would sit in the model's most trusted real estate) and an operator pointer is logged.

Rules: instruction overrides (`ignore previous instructions`), fake system prompts (`<|im_start|>`), concealment (`do not tell the user`), system-prompt exfiltration probes, curl-pipe-to-shell droppers (two-substring rule: `curl` alone never fires).

On by default. `"promptware_enabled": false` opts out.

## See also

- [Security and sandbox](./security.md) for `ShellAllowed`, the workspace boundary, and the SSRF guard.
- [Web search](./web-search.md) for `web_search` provider configuration.
- [Memory](./memory.md) for `memory_search` / `memory_fetch` / `session_search`.
- [Knowledgebase](./knowledgebase.md) for `kb_search` / `kb_get`.
- [MCP servers](./mcp.md) for bridged tools.
- [Embedding in your own app](./embedding.md) for `RegisterTool` + custom `TPasClawTool` subclasses.
