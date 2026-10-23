# Security and sandbox

PasClaw's filesystem and shell tools are guarded by an opt-in workspace boundary plus an always-on shell denylist. Source: `src/pkg/tools/PasClaw.Tools.Sandbox.pas`.

## Configuration

```json
"sandbox": {
  "restrict_to_workspace":        true,
  "allow_read_outside_workspace": false,
  "workspace":                    "/home/me/my-project",
  "allow_read_paths":             ["^/usr/(include|share)/.*"],
  "allow_write_paths":            ["^/tmp/agent/.*"],
  "custom_shell_deny":            ["scp ", "rsync "],
  "shell_deny_enabled":           true,
  "block_private_networks":       true
}
```

| Field | Default | Effect |
|---|---|---|
| `restrict_to_workspace` | `false` | When `true`, `fs_read` / `fs_write` / `fs_list` / `fs_edit_hashline` / `fs_grep` refuse paths outside `workspace`. `shell_exec` refuses absolute paths outside it AND tokens containing `..`, pins the shell's cwd to the workspace, and bans `cd` / `chdir` / `pushd` / `popd`. |
| `allow_read_outside_workspace` | `false` | When `true`, reads are allowed anywhere even while writes stay restricted. Useful for letting the agent pull from `/usr/include/` while still locking down writes. |
| `workspace` | `""` (cwd at startup) | Absolute path the agent may operate inside. Empty means "use the current working directory at the time `pasclaw` was invoked". |
| `allow_read_paths` | `[]` | **PCRE regex** patterns that *also* count as readable. Same syntax picoclaw's `tools.allow_read_paths` accepts — anchors (`^` `$`), character classes, alternation. |
| `allow_write_paths` | `[]` | Same for writes. |
| `custom_shell_deny` | `[]` | Extra substrings appended to the built-in shell denylist. Case-insensitive. |
| `shell_deny_enabled` | `true` | Master switch for the shell denylist. Set `false` only for trusted automation — doing so re-enables `sudo`, `rm`, `dd`, `mkfs`, `$( )`, `curl \| sh`, `format c:`, PowerShell `-EncodedCommand`, etc. |
| `block_private_networks` | `true` | `web_fetch` refuses URLs whose host resolves to a private / loopback / link-local IPv4 (RFC1918, `127.0.0.0/8`, `169.254.0.0/16` — including the cloud-metadata endpoint `169.254.169.254`, CGNAT, IETF-reserved). Initial URL and every redirect hop both checked. See `PasClaw.Net.SSRF`. |

`PasClaw.Tools.Regex` wraps FPC's `RegExpr` and Delphi's `System.RegularExpressions` behind one call so `allow_*_paths` patterns are full PCRE on either toolchain. Invalid patterns return `False` (the sandbox falls through to the workspace boundary) rather than crashing.

## Permissions (ordered rules)

The sandbox above says what is *possible*. The permissions list says what the agent may do *without asking*. It is one ordered list of rules, in `config.json`:

```json
"permissions": [
  {"tool": "shell_exec",  "effect": "ask"},
  {"tool": "shell_exec",  "resource": "git status*", "effect": "allow"},
  {"tool": "shell_exec",  "resource": "git diff*",   "effect": "allow"},
  {"tool": "shell_exec",  "resource": "git push*",   "effect": "deny"},
  {"tool": "fs_write",    "resource": "*/secrets/*", "effect": "deny"},
  {"tool": "github__*",   "effect": "ask"}
]
```

- `tool` is a case-insensitive glob over the tool name (`*` any run, `?` one character). `resource` is an optional glob over the call's primary resource: the **command** for `shell_exec` / `shell_background`, the **script** for `execute_code`, the **url** for `web_fetch` / `memory_fetch`. Every other tool yields its `path` argument, or failing that its `url`, or failing that its `command` — so a resource rule reaches the whole file family (`read_file`, `write_file`, `append_file`, `edit_file`, `list_dir`, `grep_files`, `find_files`, their `fs_*` aliases), `kb_get`, and an MCP server's tools, without PasClaw being taught their names. A tool with none of those three has no resource and matches on `tool` alone. `apply_patch` is the one deliberate gap: its paths are inside the patch body, several of them, so scope it by tool.
- **Last match wins.** Put the broad rule first and the exceptions after it. No matching rule means no opinion: the call goes through the gates that already existed (plan mode, the denylist, the family switches), so an empty list changes nothing.
- `deny` refuses the call. The model sees a result that names the rule and tells it not to retry.
- `ask` pauses the turn until a human answers: **allow once**, **allow for this session** (remembered per session for that tool + resource), or **deny**. The TUI asks in its footer (`Y` once, `S` session, anything else deny); the line REPL asks on stdin; the gateway publishes a `permission_request` desktop event and waits for `POST /v1/permissions/<id>`; the `TPasClawAgent` component fires `OnAsk`. With nobody to ask (a cron run, a piped `pasclaw agent`, a gateway with no web UI connected) an `ask` rule **denies**. It never silently becomes allow. `permissions_ask_timeout_sec` (default 300) bounds the wait.
- **One prompt at a time** on the TUI and the CLI. Tool calls dispatch in parallel, so a single batch can contain two ask-gated calls; on a surface with one footer and one stdin they are presented in turn, and the second waits for the first to be answered. Only the web UI shows several at once — its requests carry ids and are answered individually. The answer you give always belongs to the request you were shown.
- `allow` is only an opinion. The shell denylist and the workspace boundary still run inside the tool.

**Policies.** `<home>/policies.json` holds a second list of the same shape (`{"permissions": [...]}` or a bare array). It is evaluated **first**: a policy `deny` is final, a policy `ask` outranks a config `allow`, and a policy `allow` can still be tightened by the config list. The gateway's `PUT /v1/config` writes `config.json` only, so a web UI session can edit its own `permissions` but cannot touch the policies.

The file is re-read whenever its modification time **or size** changes, and a read that cannot be used — unreadable, truncated, not JSON, no `permissions` array — **keeps the rules already in force** rather than clearing them. That matters because the file a team gateway owns is the file that gets rewritten under a running agent: a non-atomic write must not open a window with no denies in it. `pasclaw permissions list` warns when what is in force is not what is on disk. The two ways to clear the rules are both explicit: an empty array, or deleting the file.

`pasclaw permissions list` prints both lists in evaluation order; `pasclaw permissions test shell_exec "git push origin main"` prints the decision and the rule that made it.

The permissions gate runs after the plan / SPACE mode gates and before the tool's own checks. Source: `src/pkg/config/PasClaw.Permissions.pas`, `PermissionGate` in `src/pkg/tools/PasClaw.Tools.ToolLoop.pas`.

## Built-in shell denylist

Always on unless `shell_deny_enabled: false`.

### POSIX tokens

`sudo`, `su`, `rm`, `chmod`, `chown`, `pkill`, `killall`, `kill`, `shutdown`, `reboot`, `poweroff`, `halt`, `eval`, `mkfs`, `diskpart`.

### Windows tokens

`del`, `erase`, `rd`, `rmdir`, `format`, `attrib`, `takeown`, `icacls`, `runas`.

### cwd-change tokens (when `restrict_to_workspace`)

`cd`, `chdir`, `pushd`, `popd`. Any token containing `..` is also rejected.

### Substrings

`dd if=`, `:(){:|`, `<<EOF`, `$( )`, `${ }`, backticks, `| sh`, `| bash`, `apt install/remove/purge`, `yum install/remove`, `dnf install/remove`, `npm install -g`, `pip install --user`, `docker run/exec`, `git push`, `git force`, `format c:`.

### PowerShell (matched lowercased)

`powershell -e/-en/-enc/-ec`, `-encodedcommand`, `iex (`, `invoke-expression`, `[convert]::frombase64`, `[text.encoding]`, `.getstring([byte[]`, `set-executionpolicy`.

### Device writes

`> /dev/sd*` / `/hd*` / `/vd*` / `/xvd*` / `/nvme*` / `/mmcblk*` / `/loop*` / `/md*`.

### Always-safe paths

`/dev/null`, `/dev/zero`, `/dev/{,u}random`, `/dev/std{in,out,err}` — picoclaw's `safePaths`.

## Scripts and skills go through the same gates

Three paths used to reach a shell or a tool around the gates above, and no longer do:

- **`execute_code` scripts calling tools.** `pasclaw __tool <name>` inside a script now dispatches through the loop's own gate chain: plan-mode and space-mode refusal of mutating tools, hooks, preflight, the promptware scan, the output cap. A subagent's script dispatches into the subagent's filtered registry, not the parent's.
- **Shell skills.** A `kind: shell` skill's rendered command passes `ShellAllowed` (the denylist and, under `restrict_to_workspace`, the path rules) and runs through the active shell backend, so with the Docker backend it runs in the container like `shell_exec`. Shell skills are `tcMutating`, so plan mode refuses them; prompt skills are read-only.
- **Hung commands.** Every shell *tool* path (`shell_exec`, `execute_code`, shell skills) is bounded by `shell_timeout_sec` (default 600). On expiry the whole process tree is killed — SIGTERM then SIGKILL, deepest first — and the tool reports `exit=124`. Signalling only the shell would leave the compiler or test runner under it running after PasClaw had already reported the timeout.

## Workspace pin

When `restrict_to_workspace=true`, `Tool_Shell` invokes `RunOneShot` with `WorkingDir = workspace` so the child shell starts inside the boundary. Combined with the `cd` token ban and `..` traversal check, a sandboxed model has no relative-path escape — even if a future denylist gap let a command through, the shell still starts in the workspace, not wherever `pasclaw` was launched from.

## Known limitation: symlinks

Path canonicalisation uses `ExpandFileName`, which resolves `..` but not symlinks. Picoclaw's equivalent (`os.OpenRoot` in Go 1.24+) enforces the boundary at the syscall layer; PasClaw runs on FPC and Delphi RTLs that have no equivalent.

**Do not place symlinks inside `workspace` that point outside it** — they would let the agent escape.

## Docker shell backend

For a stronger boundary, set `shell_backend: docker`:

```json
"shell_backend": "docker",
"shell_backend_docker": {
  "image":      "debian:bookworm-slim",
  "network":    "none",
  "privileged": false,
  "user":       ""
}
```

PasClaw spawns a per-session container at session start, `docker exec`s into it for every `shell_exec` / `execute_code` call, and stops it at session end. The workspace is bind-mounted at the **same path** inside the container, so `fs_read`/`fs_write` from the host process and `cat`/`tee` from inside the container reference the same files — operators inspect from outside with `ls ~/.pasclaw/workspace/`, no path translation.

Hardening win: even a model that escapes the `ShellAllowed` denylist can only touch the container, not the host filesystem. `~/.pasclaw/config.json` (provider keys) is deliberately **not** mounted in.

**The tool callback crosses the boundary on purpose.** An `execute_code` script calls back into the agent's tool registry (`tool <name> '<json>'`, and the only route to a [code-mode](./mcp.md#code-mode) MCP server). The container's loopback is its own, so on a bridge network the callback listener binds the host's docker-bridge gateway instead and the container gets `host.docker.internal` mapped to the host. What that widens, and what it does not:

- The listener is on a docker-bridge address, not `0.0.0.0` — reachable from containers on this host's docker networks and from the host, not from the LAN.
- Every request carries a per-call random token. The discovery file holding it is written under `~/.pasclaw/run/`, which is mounted only into PasClaw's own container.
- The listener exists only for the duration of one `execute_code` call, on a fresh port and token.
- `"network": "none"` keeps the container off the network entirely. The callback then cannot work — `tool` fails to connect and code-mode MCP servers are unreachable from a script — which is the right trade if that is the posture you picked.

Onboarding asks once. CLI override `--backend docker|local` doesn't persist. Phase 1 wires this for `pasclaw agent` (interactive + one-shot) and `pasclaw heartbeat`; `pasclaw tui` / `pasclaw serve` / `pasclaw gateway` refuse `docker` cleanly until per-session container handoff inside those long-running surfaces lands. SSH backend is Phase 2.

## SSRF guard

`web_fetch` runs every URL — initial request and every redirect hop — through `PasClaw.Net.SSRF.IsBlocked`. The blocklist:

- RFC1918: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`.
- Loopback: `127.0.0.0/8`.
- Link-local: `169.254.0.0/16` (includes `169.254.169.254`, the AWS / GCP / Azure metadata endpoint).
- CGNAT: `100.64.0.0/10`.
- IETF-reserved: `0.0.0.0/8`, `192.0.0.0/24`, `192.0.2.0/24`, `198.18.0.0/15`, `198.51.100.0/24`, `203.0.113.0/24`, `224.0.0.0/4`, `240.0.0.0/4`.

Set `block_private_networks: false` only when you actually need the model to reach private addresses (local development, intranet scraping) and have weighed the credentials-leak risk.

The check happens after DNS resolution — a hostname that resolves to a private IP is still blocked, so `mc.internal.example.com` pointed at `10.0.0.5` doesn't bypass the guard.

## Hashline race-safety

`fs_edit_hashline` patches carry a `¶path#hash` header. The `hash` is computed over the file's current bytes. If the file changed since the model read it, the hash in the patch won't match and the edit aborts without writing — no torn patch, no partial-apply.

This is the "race-safe" property: when the agent reads, summarises, then writes, the writeback might race against another process editing the same file. Hashline catches the conflict and surfaces it as a tool error the model can react to (e.g. re-read and re-patch).

## Gateway bearer token

The HTTP gateway is unauthenticated by default — every `/v1/*` route is open and the OpenAI-compatible endpoints ignore the `api_key` field. The implicit safety is binding to `127.0.0.1` (loopback); operators who use `--addr 0.0.0.0` are exposing an unauthenticated agent loop.

For network-bound deployments, set `gateway.token` (or `$PASCLAW_GATEWAY_TOKEN`):

```json
"gateway": {
  "bind_addr": "0.0.0.0",
  "token":     "sk-pasclaw-<shared-secret>"
}
```

Every non-exempt route then requires `Authorization: Bearer <token>` (or `?token=<token>`). Exempt: `/`, `/v1/health`, `/v1/version`, `/webhooks/*`. See [Gateway](./gateway.md#authentication) for the full contract including the `gateway:authed` identity stamp `allow_senders` can gate on.

The check is constant-time. For higher-assurance auth, terminate TLS + mTLS at a reverse proxy and run PasClaw loopback-bound.

## TLS

All HTTPS provider and MCP calls go through Indy's OpenSSL IO handler. PasClaw refuses to connect to TLS endpoints if OpenSSL isn't loadable — there's no plaintext fallback path that could be misconfigured into a downgrade.

## Channel sender identity

Every channel tags inbound messages with a canonical `<platform>:<id>`:

- `slack:U12345`
- `telegram:5551234`
- `matrix:@eli:matrix.org`
- `email:eli@example.com`
- `irc:eli`
- `discord:9876543210`
- `cli:$USER`

Configure an allowlist:

```json
"allow_senders": ["slack:U-eli", "telegram:*", "cli:*"]
```

Patterns are exact ids or `<platform>:*` wildcards. `*` allows anyone (escape hatch). Empty array (default) = no gate.

Each channel calls `IsAllowedSender` before invoking the agent — non-matching senders are dropped at the boundary with a log line, the model never sees them. Identity rides on `TToolLoopConfig.Identity` from the channel boundary down through hooks and audit logs, so embedder hooks can gate behaviour per-sender.

## `--no-tools` (the strongest option)

Disables the tool registry entirely, so neither `fs_*` nor `shell_exec` is registered. The system prompt automatically reflects this (no SKILLS section, no "ALWAYS use tools" rule). Pair with `--no-mcp` and `--no-hashline` for the absolute minimum exposure.

```sh
pasclaw agent --no-tools --no-mcp --no-hashline -m "explain monads"
```

## See also

- [Tools](./tools.md) for the tool catalog and promptware defense.
- [Configuration](./configuration.md) for the broader config surface.
- [Channels](./channels.md) for `allow_senders` and per-channel identity formats.
