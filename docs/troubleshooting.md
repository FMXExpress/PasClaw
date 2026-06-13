# Troubleshooting

A grep-friendly index of "user sees X, fix is Y" entries. Each entry names the symptom verbatim so you can paste an error message into the search box and find the right section.

## Build errors

### `F2613 Unit 'PasClaw.<X>' not found.` (dcc64)

The Delphi project file is missing the unit search path for a `src/pkg/<dir>/` directory the Makefile already knows about. Fix: append `..\pkg\<dir>` to `DCC_UnitSearchPath` in `src/pasclaw/PasClaw.dproj`. See [Contributing](./contributing.md#delphi).

### `Fatal: Can't find unit Masks` (FPC)

Lazarus's `lazutils` source tree isn't on the FPC search path. On Debian:

```sh
sudo apt install lazarus-src
make LAZUTILS_DIR=/usr/lib/lazarus/3.0/components/lazutils
```

On macOS Homebrew: `brew install lazarus`; the Makefile autodetects `<prefix>/share/lazarus/components/lazutils`.

### `Indy not found at vendor/Indy`

Run `make get-indy`. One-time clone of `IndySockets/Indy` into `vendor/Indy`. Delphi builds skip this — Indy ships with RAD Studio.

### `Fatal: Syntax error, BEGIN expected but - found` near a comment block

Pascal `{ ... }` comments **don't nest**. If a comment block contains `{` or `}` (e.g. JSON examples, traceparent format `00-{trace}-{span}`), the first `}` closes the comment and the rest is parsed as code. Fix: use `(* ... *)` for blocks that contain literal `{` / `}`. See `PasClaw.Otel.pas` for examples.

## Runtime errors

### `[info] web_search disabled: no real provider configured. Set $PASCLAW_BRAVE_API_KEY / ...`

The DuckDuckGo scrape fallback is disabled because DDG started TLS-fingerprinting non-browser clients in 2025. Pick a keyed provider:

```sh
export PASCLAW_BRAVE_API_KEY=...
```

Or set `web_search.provider` in `config.json` to `tavily` / `searxng` / `perplexity` / `gemini`. See [Web search](./web-search.md).

### `[info] mcp[<name>] cache hit: N tool(s) registered, live refresh started`

Informational. The MCP server registered tools from cache (fast path); a live refresh runs in the background. Not an error. To suppress on machine-readable pipelines: pass `--quiet` / `-q`.

### `pasclaw error: provider not configured (no provider entry for "anthropic" ...)`

You haven't run `pasclaw onboard` or `pasclaw auth login <provider>` yet. Either:

```sh
pasclaw onboard
# or
pasclaw auth login anthropic
```

Or code-driven from an embedder:

```pascal
Agent.SetProvider('anthropic', GetEnvironmentVariable('ANTHROPIC_API_KEY'));
```

### `r�sum�.txt` mojibake in `shell_exec` output on Windows

CP437 / CP1252 bytes from `cmd.exe`'s pipe being decoded as UTF-8. Fixed in PR #239 — `PasClaw.Platform.DecodeShellOutputBytes` now auto-detects with strict UTF-8 first (`MB_ERR_INVALID_CHARS`) and falls back to OEM (`GetOEMCP`). Update to a build that includes `8802c8f` or later.

If you still see mojibake on a recent build, your terminal's console codepage may be lying. Check:

```bat
chcp
```

If it reports `65001` (UTF-8) but the child process actually writes CP437, that's the trigger. The fallback should catch it; if it doesn't, file an issue with the exact `chcp` value and the raw bytes the child emits.

### `pasclaw agent --quiet -m "..."` prints `[info] ...` lines before the model reply

Fixed in PR #244 — the dpr clamps the logger to `llError` when `--quiet` is on argv, and `RunRootCommand` no longer undoes the clamp via `SetLogLevelFromString`. Update to a build that includes `8802c8f` or later.

If you're on an older build: as a workaround, set `gateway.log_level: "error"` in `config.json` (clamps everything, even non-quiet runs).

### `(loop failed)` with no further context

The agent loop returned `False` — typically a provider error after the fallback walk failed (every provider returned non-2xx) or `MaxIterations` exhausted. Check:

1. `pasclaw status` — are all `providers[]` keys valid?
2. The stderr `[warn] provider Chat raised: ...` lines from the loop.
3. With `--debug` (gateway/serve) or in interactive `pasclaw agent` mode you get the per-call diagnostic.

When `--quiet` is set, exit code is non-zero on `(loop failed)` so scripts can detect it without parsing stdout.

### `EAccessViolation` / segfault on Linux when running threaded code

Missing `cthreads` import in a program that uses threading. Threaded tests need:

```pascal
{$IFDEF UNIX}cthreads,{$ENDIF}
SysUtils, Classes, ...
```

Without it, calling `TThread.Create` results in undefined behaviour. The smoke test and every test program already does this.

### `EIdOSSLCouldNotLoadSSLLibrary`

OpenSSL isn't loadable from the PasClaw binary's load path. Fixes:

- Linux: `sudo apt install libssl3 libssl-dev` (or distro equivalent).
- macOS: `brew install openssl` and re-link, or `export DYLD_LIBRARY_PATH=$(brew --prefix openssl)/lib`.
- Windows: drop `libssl-3-x64.dll` and `libcrypto-3-x64.dll` next to `pasclaw.exe`. Indy's required minor version is documented at https://github.com/IndySockets/IndyOpenSSL.

### `Killed` mid-turn with no obvious error

OOM-killed by the kernel. Most common cause: a tool result over `tool_output_cap` getting reinjected verbatim. Set:

```json
"tool_output_cap":      8192,
"condense_reversible":  true
```

The model dereferences the verbatim bytes via `tool_output_get` when it needs them. See [Tools](./tools.md#output-condensation).

## Gateway / serve

### `bind: address already in use`

Another process is listening on `127.0.0.1:8088` (default). Either kill it (`fuser -k 8088/tcp`), or:

```sh
pasclaw gateway --addr 127.0.0.1 --port 8089
```

### `gateway: handler crashed: ...`

Unhandled exception inside a route handler. The catch-all in `OnCommandGet` (`src/pkg/gateway/PasClaw.Gateway.Server.pas`) writes a 500 response if the headers haven't been sent yet, or disconnects the client if a streaming response was already in flight.

Check stderr for the full `[error] gateway: handler crashed:` line. The stack trace + originating route is in the log buffer (`GET /v1/logs`).

### `MCP-only listener; route not found`

You hit a non-MCP route on the listener spawned by `--mcp-port <p>`. By design — that listener only honours `/mcp`, `/v1/mcp/rpc`, and `/v1/health`. Use the main gateway port for `/v1/chat`, etc.

## MCP

### `mcp[<server>] cache hit: 0 tool(s) registered`

The MCP server's cached metadata is empty — the cache file exists but has no tools. Causes:

1. The server returned an empty tools list on the previous boot.
2. The cache is stale (server's tool list changed).

Fix: delete the cache file and let `pasclaw` re-fetch:

```sh
rm $PASCLAW_HOME/cache/mcp/<server>.json
pasclaw mcp test <server>
```

### `pasclaw mcp stdio` corrupts the host's JSON-RPC parser

The banner is leaking onto stdout. Confirm: `pasclaw mcp stdio --help` should NOT print the banner. If it does, you're on an older build that doesn't have `IsStdioMCPInvocation`. Update past `f303f44`.

### `mcp install <slug>: hub unreachable`

`pasclaw mcp install` tries the pasclaw.dev hub first, falls back to the bundled catalog (5 entries). If neither has the slug, you get the unreachable + not-found message. Workaround: install manually:

```sh
pasclaw mcp add <name> <cmd-or-url> [args...]
```

## Channels

### Telegram bot doesn't see messages

- The bot was created with @BotFather and you have the token.
- `pasclaw gateway --telegram --token $TOKEN` is running.
- `getUpdates` requires the bot to NOT be a webhook target. If you previously set a webhook, run `https://api.telegram.org/bot<TOKEN>/deleteWebhook` once.
- The bot is added to the chat / group / channel you're testing from.

### Slack `invalid_signature` on inbound events

`X-Slack-Signature` validation failed. Likely causes:

- `$PASCLAW_SLACK_SIGNING_SECRET` (or per-app config) doesn't match the app you configured the webhook for.
- Replay protection: events older than 5 minutes are rejected. Clock skew on the host > 5 min triggers this.

### Matrix bot doesn't auto-join

By default the Matrix channel honours `allow_senders`. If your account isn't in the allowlist, invites are dropped. Either add yourself or set `allow_senders: []` for unrestricted dev usage.

## Sandbox

### `tool denied: path outside workspace: /home/me/other/foo`

`sandbox.restrict_to_workspace: true` is on and the model tried to read/write outside `sandbox.workspace`. Either:

1. Add an explicit allow:
   ```json
   "sandbox": {
     "allow_read_paths":  ["^/home/me/other/.*"]
   }
   ```
2. Move the file into the workspace.
3. Set `allow_read_outside_workspace: true` (reads-anywhere, writes-restricted — softer than disabling the boundary).

### `tool denied: refused command: contains 'rm '`

The shell denylist refused a `rm` token. Workaround for legitimate cleanup: use `fs_write` to truncate a file instead, or pre-stage a `find -delete` workflow in a skill the operator audits before installation.

To disable the denylist (trusted automation only):

```json
"sandbox": { "shell_deny_enabled": false }
```

See [Security](./security.md#built-in-shell-denylist) for the full list.

### `web_fetch refused: private network` for an internal address

`sandbox.block_private_networks` blocks RFC1918, loopback, link-local, cloud-metadata. For local development / intranet scraping:

```json
"sandbox": { "block_private_networks": false }
```

Weigh the credentials-leak risk. The metadata endpoint (`169.254.169.254`) is the canonical SSRF exfiltration vector on AWS / GCP / Azure.

## Sessions / memory

### Sessions auto-disappear after a crash

They don't — auto-saves go through atomic `.tmp` then `rename`. But the working-state snapshot is rebuilt only on a successful tool loop. A crash mid-loop loses the snapshot for that turn but the message history is intact. Resume with:

```sh
pasclaw resume <id>
```

### `memory_search` returns nothing for a phrase I just wrote

The index is lazy — it rebuilds on `memory_search` itself. If the search runs **before** the new file's `UpdatedAt` ticks, it can miss. Force a refresh:

```sh
ls -la $PASCLAW_HOME/workspace/memory/
touch $PASCLAW_HOME/workspace/memory/MEMORY.md
```

Then re-search. The lazy-sync also covers `workspace/sessions/.search.db` for `session_search`.

### `pasclaw memory provision` fails to download artifacts

Provisioning fetches sqlite-vec + ONNX Runtime + MiniLM from GitHub Releases. Behind a corporate proxy:

```sh
export HTTPS_PROXY=http://proxy:8080
pasclaw memory provision
```

Verify with `pasclaw memory status`.

## OpenTelemetry

### Spans aren't showing up in my OTel Collector

Checklist:

1. `pasclaw status` should show `otel: enabled` if you set `diagnostics.otel.enabled: true`.
2. Set `OTEL_EXPORTER_OTLP_ENDPOINT` explicitly to confirm — it overrides config and flips `enabled` on its own.
3. The Collector accepts OTLP/HTTP+JSON on its `/v1/traces` path. Some Collector configs only accept protobuf — check your `receivers.otlp.protocols.http` block.
4. Sampling: `sampleRate: 0.1` means 90% of traces don't ship. Use `1.0` for diagnosis.
5. Synchronous export: if the export POST hangs (Collector down, wrong URL), each trace adds the timeout cost (10s default) at the end of the agent turn. Check stderr for `otel: export ... raised` / `otel: export ... -> 4xx`.

### Parallel tool calls don't appear in traces

Known limitation. Parallel-worker dispatches don't yet propagate the parent's threadvar span context across the worker boundary. Serial dispatch (the default for the CLI) is fully traced. Workaround: run with `--no-parallel` if you specifically need parallel tools traced.

## Specific PR references

For grep-friendly issue lookups:

- `r�sum�.txt` mojibake — PR #237, #238, #239 (Windows OEM vs UTF-8 console).
- `Â¶` in `fs_read` output — PR #238 (hashline header CP_UTF8 stamping).
- Config rewrite drops `diagnostics.otel.*` — PR #242 review (ToJSON emission block).
- `pasclaw agent --quiet` still shows `[info]` lines — PR #244 (and the P1 fix that followed).
- `pasclaw agent --quiet` exits 0 on provider error — PR #243 review (RunSingleTurn → function returning Boolean → exit code).
- `dcc64 F2613 Unit 'PasClaw.Otel' not found` — PR #243 (added `..\pkg\otel` to `DCC_UnitSearchPath`).
- `fs_grep` silent on file >= 10 MiB — by design (tier-4 cap). Override per call with `max_file_bytes`.

## See also

- [Configuration](./configuration.md) — full set of knobs.
- [Security](./security.md) — sandbox-related refusals.
- [Contributing](./contributing.md) — build-side issues.
- The full git log: `git log --grep "<keyword>"`.
