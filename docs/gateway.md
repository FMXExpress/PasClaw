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
