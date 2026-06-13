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
