# Gateway and OpenAI-compatible API

PasClaw ships an Indy-based HTTP server with two entry points sharing the same `TGatewayServer` implementation:

- `pasclaw gateway` — full surface: web UI, OpenAI-compatible endpoints, inspection routes, cron scheduler, optional channels.
- `pasclaw serve` — focused wrapper that prints copy-pasteable OpenAI client config on startup. Same server, smaller framing.

## Running

```sh
pasclaw gateway
pasclaw gateway --addr 0.0.0.0 --port 8088
pasclaw gateway --telegram --token <BOT_TOKEN>
pasclaw gateway --line                              # also $PASCLAW_LINE_TOKEN + $PASCLAW_LINE_SECRET
pasclaw gateway --whatsapp                          # also $PASCLAW_WHATSAPP_*
pasclaw gateway --matrix                            # also $PASCLAW_MATRIX_HOMESERVER + $PASCLAW_MATRIX_TOKEN
pasclaw gateway --irc                               # also $PASCLAW_IRC_*
pasclaw gateway --email                             # SMTP send + IMAP poll
pasclaw gateway --mcp-port 9090                     # spawn a second MCP-only listener (--mcp-allow-write opts in to mutating tools)
pasclaw gateway --no-tools --no-mcp --no-hashline

pasclaw serve
pasclaw serve --addr 0.0.0.0 --port 8088
pasclaw serve --debug
pasclaw serve --max-iter 40
pasclaw serve --no-tools --no-mcp --no-hashline
```

Default bind: `127.0.0.1:8088`. Override via `gateway.bind_addr` / `gateway.port` in `config.json` or `--addr` / `--port` per run.

## Route table

| Route | Method | Purpose |
|-------|--------|---------|
| `/` | GET | Embedded single-page web UI (`src/pkg/gateway/webui.html`). |
| `/v1` | GET | JSON index listing gateway routes. |
| `/v1/health` | GET | Health check with PasClaw version. |
| `/v1/version` | GET | Version + build metadata. |
| `/v1/status` | GET | Default provider/model + provider, MCP, cron, skill, tool counts. |
| `/v1/tools` | GET | Registered tool descriptors. |
| `/v1/mcp` | GET | Configured MCP servers (`name`, `cmd`, `args`, `enabled`). |
| `/v1/cron` | GET | Cron entries (`id`, `spec`, `skill`, `args`, `channel_*`, `enabled`). |
| `/v1/skills` | GET | Installed skills (`name`, `description`, `kind`, `path`, `dir`). |
| `/v1/memory` | GET | Files in `workspace/memory/` with sizes. |
| `/v1/memory/<name>` | GET | Contents of one memory file (rejects path-traversal). |
| `/v1/config` | GET | Full config with `providers[].api_key` masked to `•••`. |
| `/v1/fs?path=…` | GET | Directory listing (entries + sizes + dir flag); defaults to `$PASCLAW_HOME`. |
| `/v1/fs/read?path=…` | GET | File contents capped at 256 KB; `truncated` flag on response. |
| `/v1/logs` | GET | SSE tail of the gateway log buffer (1000-entry ring); recent buffer dumps first, then live. |
| `/v1/models` | GET | OpenAI-compatible model list containing the configured default model. |
| `/v1/stats` | GET | 5-second-cached aggregate of per-session counters (opt-in via `stats_collection_enabled`). |
| `/v1/chat` | POST | PasClaw JSON chat endpoint accepting `{"message":"..."}`. |
| `/v1/chat/completions` | POST | OpenAI Chat Completions-compatible. Streams with `stream: true`. |
| `/v1/responses` | POST | OpenAI Responses-compatible. String or message-array `input`. Non-streaming only. |
| `/mcp`, `/v1/mcp/rpc` | POST | MCP JSON-RPC endpoint when PasClaw is acting as an MCP server. |

## Embedded web UI

`/` serves a single-page vanilla ES2020 app (no JS toolchain, no bundler — `src/pkg/gateway/webui.html` is `{$R webui.res}`'d into the binary). Eight tabs:

| Tab | Purpose |
|---|---|
| **Chat** | SSE-streamed conversation. Tool activity surfaced inline. LocalStorage session history. |
| **Memory** | Browse and read `workspace/memory/*.md`. |
| **Files** | Browse `$PASCLAW_HOME`. Read individual files up to 256 KB. |
| **MCP** | List configured MCP servers and their tool counts. |
| **Cron** | List cron entries and their last-fire timestamps. |
| **Skills** | List installed skills. |
| **Logs** | Live tail via SSE from the gateway's in-process ring buffer. |
| **Settings** | Read-only config view (provider API keys masked). |
| **Stats** | Auto-refreshing token + tool-call + truncation-savings cards + `by_provider` / `by_model` rollups (when `stats_collection_enabled`). |

## OpenAI-compatible client

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8088/v1", api_key="sk-pasclaw")
response = client.chat.completions.create(
    model="claude-opus-4-7",
    messages=[{"role": "user", "content": "hello"}],
)
print(response.choices[0].message.content)
```

The `api_key` is ignored — PasClaw uses its configured provider keys, not the one the client sends. Use any string. Streaming:

```python
stream = client.chat.completions.create(
    model="claude-opus-4-7",
    messages=[{"role": "user", "content": "hello"}],
    stream=True,
)
for chunk in stream:
    print(chunk.choices[0].delta.content or "", end="", flush=True)
```

## Curl examples

```sh
curl http://127.0.0.1:8088/v1/health
curl http://127.0.0.1:8088/v1/tools

curl http://127.0.0.1:8088/v1/chat \
  -H 'Content-Type: application/json' \
  -d '{"message":"hello"}'

curl http://127.0.0.1:8088/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-7","messages":[{"role":"user","content":"hello"}]}'

curl http://127.0.0.1:8088/v1/responses \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-7","input":"hello"}'
```

Streaming with `stream: true`:

```sh
curl -N http://127.0.0.1:8088/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-7","messages":[{"role":"user","content":"hi"}],"stream":true}'
```

## `/v1/chat/completions` with `stream: true` — tool transcript

The tool loop executes server-side and each tool call is surfaced to the client as a visible content delta in a Claude-Code-style transcript — the tool name with its key argument, then a short result summary on the next line:

```
⏺ fs_read(README.md)
  ⎿ 312 lines, 12044 bytes — ¶README.md#a1b2
⏺ shell_exec(ls -la)
  ⎿ exit=0
```

Known tools (`fs_read`, `fs_write`, `fs_list`, `fs_grep`, `fs_edit_hashline`, `shell_exec`, `memory_search`, `web_search`, `web_fetch`) surface their most meaningful argument; MCP and other tools fall back to a compact one-line dump of the raw arguments. The full argument and result text also go to SSE comment lines (`: tool_call ...` / `: tool_result ...`) for consumers that log structured activity, and to the server debug log when `--debug` is set. Formatter: `src/pkg/gateway/PasClaw.Gateway.ToolView.pas` (unit-tested via `make test-toolview`).

## `/v1/chat/completions` with `session_context` — server-held conversations

By default `/v1/chat/completions` is stateless in the OpenAI sense: the caller ships the whole `messages[]` array every turn and the gateway answers it. That is the right contract for third-party tooling, and it is unchanged.

A client that would rather let PasClaw hold the conversation — the way the CLI and the TUI already do — names a session and asks for it:

```sh
curl http://127.0.0.1:8088/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'X-PasClaw-Session: my-conversation' \
  -d '{"model":"claude-opus-4-7",
       "session_context": true,
       "session_title": "Notes with Claude",
       "messages":[{"role":"user","content":"and what about the second one?"}]}'
```

With `session_context: true` the gateway loads `my-conversation` from the session store, appends the request's `messages[]` to it, runs the turn against the whole thing, and files the result back. So each request carries only what is new.

| Field | Meaning |
|---|---|
| `session_context` | Boolean, default `false`. Prepend the stored transcript to `messages[]`. Requires a session id (`X-PasClaw-Session`, or the `user` field). |
| `session_title` | Names the session the first time it is written. Later turns do not rename it. Without it a session is titled after the route that created it. |

Details worth knowing:

- **Stored `system` turns are dropped on load.** The system prompt is composed fresh per request (workspace context, memory, AGENTS rules, mode); a stored copy replayed mid-transcript would be stale and would argue with the live one. Tool calls and tool results are kept — the model needs its own results to make sense of what it did.
- **Compaction sticks.** The stored transcript is the compacted one, so the loop's compaction is no longer undone by a client re-sending the long copy. What compaction drops is carried forward as a working-state block (recently edited files, last shell command, last tool error) appended to the system prompt, the same block the TUI injects.
- **The session is a real session.** `pasclaw resume <id>`, `pasclaw learn` and the Library window all see it, because it is the same store every other surface writes.

The desktop uses this for both its project chats (`desktop-<project>`) and its shell (`desktop-shell`).
## `/v1/sessions/<id>` — the live transcript and the record

A session on disk is the model's **working context**. When the tool loop compacts — replacing the older half of a conversation with a summary so the next turn fits — every surface writes that result back as the session, so the compacted turns leave the file. That is correct for a resume (replaying them would undo the compaction) and wrong for a reader.

So every message is also appended, once, to `<id>.log.jsonl` beside the session: the **record**. The live file is what the model sees; the record is what the conversation was.

| Request | Answers with |
|---|---|
| `GET /v1/sessions/<id>` | the live transcript — post-compaction, the resume state |
| `GET /v1/sessions/<id>?full=1` | the newest 200 messages of the record, with `total` |
| `GET /v1/sessions/<id>?full=1&limit=N` | the newest `N` |
| `GET /v1/sessions/<id>?full=1&offset=K&limit=N` | `N` messages from index `K` |

```json
{ "id": "desktop-notes", "total": 1603, "offset": 1483, "count": 120, "messages": [ … ] }
```

Windowed because the record grows without bound: the desktop measured 10.4 s and 2.1 MB to paint a 1500-turn conversation in one go, against 94 ms and 369 DOM nodes for a 120-message window. Page backwards by walking `offset` down from `total`; `limit` is capped at 2000.

`?full=1` falls back to the live transcript for a session recorded before the log existed, so old sessions still answer. Deleting a session deletes its record with it.

## `/v1/responses` — OpenAI Responses API

Accepts string or message-array `input`:

```sh
# string input
curl http://127.0.0.1:8088/v1/responses \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-7","input":"hello"}'

# message-array input
curl http://127.0.0.1:8088/v1/responses \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-7","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}'

# missing or empty input returns invalid_request_error
curl http://127.0.0.1:8088/v1/responses \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-7","input":""}'
```

Tool passthrough so Codex CLI can drive its own tools. Streaming is intentionally unsupported — Codex CLI doesn't stream on this route.

Server-side `call_id` → `thoughtSignature` cache means stock OpenAI-Responses clients round-trip Gemini 3's signed function calls across turns even when they strip PasClaw's `provider_signature` extension.

## `/v1/stats` — operator metrics

Returns a 5-second-cached aggregate of per-session counters when `stats_collection_enabled: true`:

```json
{
  "input_tokens":           1234567,
  "output_tokens":          234567,
  "cache_read_tokens":      890000,
  "cache_created_tokens":   45000,
  "turns":                  1234,
  "tool_calls":             5678,
  "truncation_bytes_saved": 12345678,
  "by_provider": [
    { "provider": "anthropic", "input_tokens": 800000, "output_tokens": 150000 },
    { "provider": "openai",    "input_tokens": 434567, "output_tokens":  84567 }
  ],
  "by_model": [
    { "model": "claude-opus-4-7", "input_tokens": 800000, "output_tokens": 150000 }
  ]
}
```

Gateway-side stateless API calls (`/v1/chat`, `/v1/chat/completions`, `/v1/responses`) accumulate into per-endpoint synthetic session files (`_gateway_v1_chat.json`, `_gateway_v1_chat_completions.json`, `_gateway_v1_responses.json`) so calls driven through the web UI chat or any other OpenAI/Anthropic-compatible client also show up. Each endpoint gets one bucket regardless of model — `Meta.Model` tracks the most recent request's model. Concurrent gateway requests serialise the bucket update through a single critical section.

Default off: per-session JSONs of flag-off operators are byte-identical to the pre-feature schema.

## Authentication

Off by default. The gateway runs unauthenticated — every `/v1/*` route is open and the OpenAI-compatible endpoints accept any `api_key` string (it's ignored). The implicit safety is binding to `127.0.0.1` (loopback only); operators who run `--addr 0.0.0.0` are intentionally exposing an unauthenticated agent loop to the network.

To gate every non-exempt route on a bearer token, set `gateway.token` in `config.json`:

```json
"gateway": {
  "bind_addr": "0.0.0.0",
  "port":      8088,
  "token":     "sk-pasclaw-<your-shared-secret>"
}
```

Or via environment (standard ops-sets-env-at-deploy pattern, mirrors `OTEL_EXPORTER_OTLP_ENDPOINT`):

```sh
PASCLAW_GATEWAY_TOKEN=sk-pasclaw-<secret> pasclaw gateway --addr 0.0.0.0
```

`OPENCLAW_GATEWAY_TOKEN` is honoured as an alias for openclaw-compat — an operator pointing PasClaw at an existing openclaw `.env` file doesn't have to rename anything. `PASCLAW_GATEWAY_TOKEN` wins when both env vars are set.

A third path: reference any env var inline via openclaw-style `${VAR_NAME}` substitution in `config.json` (see [Configuration § `${VAR_NAME}` environment-variable substitution](./configuration.md#var_name-environment-variable-substitution)):

```json
"gateway": { "token": "${MY_CORP_PASCLAW_TOKEN}" }
```

This pattern persists the resolved value through `SaveConfig`; for env-only secrets that should never end up in `config.json`, prefer the dedicated `PASCLAW_GATEWAY_TOKEN` env path above.

Env overrides config when both are set. An env-only token does **not** leak into `config.json` — any config-mutating command (`pasclaw auth login`, `pasclaw model set`, `pasclaw skills install`, ...) round-trips through `SaveConfig` and `TConfig.ToJSON` emits only the in-config `gateway.token` field, never the env override. The middleware reads the effective value via `PasClaw.Config.GetEffectiveGatewayToken`.

The `/v1/config` route masks `gateway.token` to `•••` for any authenticated caller — same shape `providers[].api_key` and `mcp_servers[].env` already use.

### Calling an authenticated gateway

Header (preferred — doesn't leak through access logs):

```sh
curl http://127.0.0.1:8088/v1/chat/completions \
  -H "Authorization: Bearer sk-pasclaw-<secret>" \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-4-7","messages":[{"role":"user","content":"hi"}]}'
```

OpenAI SDK — set the same value as `api_key`:

```python
client = OpenAI(base_url="http://127.0.0.1:8088/v1", api_key="sk-pasclaw-<secret>")
```

Query parameter — needed by browser `EventSource` which can't set headers:

```sh
curl 'http://127.0.0.1:8088/v1/logs?token=sk-pasclaw-<secret>'
```

When both are present, the header wins (logs may capture the query string; the header is authoritative).

### Exempt routes

These five route families bypass the bearer check even when `gateway.token` is set:

| Route | Why exempt |
|---|---|
| `GET /` | Web UI HTML. Browsers can't attach a Bearer header on the initial GET; the JS inside attaches the token to subsequent `/v1/*` fetches. |
| `GET /desktop` | Desktop shell HTML — same reason as `/`, and this page hosts the token-entry dialog itself, so returning it as 401 would lock you out of the UI that lets you authenticate. Its `/v1/desktop/*` data routes are **not** exempt. |
| `GET /v1/health` | k8s liveness / readiness probes. A 401 would route the platform's probe into "instance unhealthy" even when the gateway is up. |
| `GET /v1/version` | Build metadata. Frequently scraped; pinning a token wouldn't protect anything sensitive. |
| `/webhooks/<channel>` | LINE / WhatsApp / Slack inbound paths. Upstream channels can't supply the gateway bearer; they carry their own per-channel signature secret instead (`x-line-signature`, `x-hub-signature-256`, etc.). |

### What's gated

Everything else, including `/v1/logs`, `/v1/stats`, `/v1/config`, `/v1/fs`, `/v1/fs/read`, `/mcp`, `/v1/mcp/rpc`. The `/v1/logs` ring buffer leaks per-tool argument bytes; `/v1/config` carries masked API keys + bot tokens; `/v1/fs/read` returns file contents up to 256 KB. Locking these down behind the token is the whole point.

One deliberate exception, scoped to a listener rather than a route: on the `--apps-port` listener, the app surface it exists to serve (`/apps/*`, `/pages/*`, and the per-app `state`/`read`/`action` paths) answers without a bearer. That origin is where model-authored app code runs, and it is designed never to hold the operator token — see [Serving apps from their own origin](desktop.md#serving-apps-from-their-own-origin). Every other route on that listener still 401s, and the main port is unaffected.

### Identity stamping

Inbound requests reach `RunToolLoop` with `LoopCfg.Identity := MakeIdentity('gateway', '<sub>')` where `<sub>` is:

- `anon` when no token is configured (unauthenticated mode).
- `authed` when a token is configured (the request has already passed the bearer check by the time `LoopCfg` is built).

Operators wanting to require token-auth for any gateway-driven turn can set:

```json
"allow_senders": ["gateway:authed", "telegram:*", "cli:*"]
```

A `gateway:anon` identity would then be dropped at the channel boundary — defence in depth in case the operator accidentally removes the `gateway.token` field without also un-binding from `0.0.0.0`.

### Comparison shape

`gateway.token` comparisons are constant-time so a timing oracle can't enumerate the token byte-by-byte. ASCII byte equality only — the token is whatever string the operator put in config.json (or the env var); there's no scheme-specific validation (no JWT, no signature, no expiry). For higher-assurance auth, terminate TLS + mTLS at a reverse proxy and let PasClaw run loopback-bound; `gateway.token` is for the "shared secret + HTTPS over the LAN" middle case openclaw targets.

### Known limitations

- The embedded web UI passes the token through to every `/v1/*` fetch as `Authorization: Bearer <token>`. The token lives in browser `localStorage` under `pasclaw.gw_token.v1`. On the first 401 (typically the initial `GET /v1/status` after page load) a prompt asks for the token; subsequent calls reuse it. The 🔑 button in the header lets the operator re-set or clear the token without reloading. For SSE endpoints (`/v1/logs`) the token is appended as `?token=<value>` since `EventSource` can't set custom headers — same query-param fallback `PasClaw.Gateway.Auth.CheckGatewayAuth` already accepts. localStorage is acceptable for this single-shared-secret model; higher-assurance auth is the reverse-proxy + mTLS path noted above.
- Token rotation requires a restart (config is read at `pasclaw gateway` startup, not per-request).
- No per-tenant tokens / no JWT — single shared secret. The use case is "PasClaw is the team's shared HTTP agent, every team member has the same secret", not "multi-tenant SaaS".

## Trace correlation

When OpenTelemetry is enabled (`diagnostics.otel.enabled` or `OTEL_EXPORTER_OTLP_ENDPOINT`), every inbound `/v1/*` request is wrapped in an `HTTP <method> <route>` server span. The `traceparent` request header (W3C Trace Context) becomes the parent context, so an upstream caller's trace stays connected to whatever the gateway then does (`openclaw.agent.turn`, `chat <model>`, `execute_tool <name>`). See [Observability](./observability.md).

## Stop / health probing

```sh
curl http://127.0.0.1:8088/v1/health         # 200 OK + JSON
```

Press Ctrl-C to stop. The server tears down all active SSE streams cleanly before exiting.

## Embedded use

`TPasClawServer` lets you host the same gateway inside your own Delphi/FPC process. See [Embedding in your own app](./embedding.md).

## See also

- [Channels](./channels.md) — chat-channel bots the gateway can run alongside the HTTP surface.
- [Providers](./providers.md) — the server uses the same provider chain as the CLI.
- [Observability](./observability.md) — trace shape and `/v1/stats`.
