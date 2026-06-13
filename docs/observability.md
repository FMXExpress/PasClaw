# Observability

PasClaw ships three layers of operator visibility:

1. **OpenTelemetry traces** — OTLP/HTTP+JSON spans for agent turns, provider requests, tool calls, and HTTP server requests. Off by default.
2. **`/v1/stats`** — 5-second-cached aggregate of per-session counters. Opt-in.
3. **TUI `/stats` overlay** — in-process accumulator, always available.

## OpenTelemetry

### Configuration

```json
"diagnostics": {
  "otel": {
    "enabled":     false,
    "endpoint":    "http://localhost:4318",
    "protocol":    "http/json",
    "serviceName": "pasclaw",
    "sampleRate":  1.0,
    "headers":     { "Authorization": "Bearer ..." },
    "traces":      true,
    "metrics":     false,
    "logs":        false
  }
}
```

Off by default. Two ways to enable:

1. **Config** — set `diagnostics.otel.enabled: true`.
2. **Env var** — set `OTEL_EXPORTER_OTLP_ENDPOINT` (standard OTel SDK contract). The env var alone flips `enabled` to `true`. Optional `OTEL_EXPORTER_OTLP_HEADERS="k1=v1,k2=v2"` for auth headers.

Env values win over config when both are set.

### Span shape

```
HTTP <method> <route>            (gateway: every inbound /v1/* call,
                                  W3C traceparent parsed for parent ctx)
└── openclaw.agent.turn          (one tool loop iteration set)
    ├── chat <model>             (provider request, gen_ai.* attrs)
    └── execute_tool <name>      (serial tool dispatch)
```

Span shape and attribute names mirror **openclaw v2026.2+** so OTel-aware backends (Langfuse, Tempo, Jaeger, Honeycomb, Datadog, Grafana) recognise our spans without remapping. Follows OpenTelemetry GenAI semantic conventions: `gen_ai.request.model`, `gen_ai.provider.name`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.operation.name`. PasClaw-specific overlays: `openclaw.run.id`, `openclaw.turn.id`, `openclaw.session.id`.

### Transport

- OTLP/HTTP+JSON only (no protobuf in this release).
- POST to `{endpoint}/v1/traces`. `/v1/traces` is appended when the configured endpoint doesn't already end in it.
- Synchronous per-trace export: spans buffer until the root span finishes, then ship in one POST. Latency to a localhost OTel Collector is ~1-5ms (invisible). To a cloud endpoint over WAN it's 50-200ms — added to the *end* of an agent turn, not in the model's critical path. For high-volume gateway deployments, point at a local Collector and let *it* batch+forward to the cloud.

### Sampling

```json
"diagnostics": { "otel": { "sampleRate": 0.1 } }
```

Bernoulli sample at trace start (root span). `1.0` = trace every turn, `0.0` = trace nothing (effectively off), `0.1` = trace ~10%. Children inherit the parent's decision — no per-span re-roll.

### W3C trace context

The gateway parses incoming `traceparent` headers as the parent context for the HTTP server span. Outbound HTTP from the agent (provider requests, MCP calls) doesn't yet propagate `traceparent` headers — follow-up.

### Backends

Any OTLP/HTTP+JSON-capable backend works. Pre-validated:

- **OpenTelemetry Collector** (`otel/opentelemetry-collector-contrib`) — most common path. Run on localhost, forward to your cloud backend.
- **Jaeger** — `JAEGER_OTLP_HTTP_PORT` exposed by the Jaeger all-in-one image.
- **Tempo** — Grafana's traces backend.
- **Langfuse** — uses the openclaw span shape directly.
- **Honeycomb** — point at `https://api.honeycomb.io` with `x-honeycomb-team` header.
- **Datadog** — via the OTel Collector or Datadog Agent's OTLP receiver.

### Known limitations

- **Metrics + logs** are scoped out of this release. The `diagnostics.otel.metrics`/`logs` booleans are reserved fields.
- **Parallel tool workers** don't yet propagate the parent span's threadvar context across the worker boundary; tool dispatches under `Cfg.Parallel = True` won't appear in traces. Serial dispatch (the default for the CLI) is fully traced.

## `/v1/stats`

Gateway-side aggregate of per-session counters. Cached 5 seconds.

```sh
pasclaw onboard                  # answer "y" to stats_collection_enabled
# OR
# config.json: "stats_collection_enabled": true

pasclaw gateway
curl http://127.0.0.1:8088/v1/stats
```

### Response shape

```json
{
  "input_tokens":            1234567,
  "output_tokens":            234567,
  "cache_read_tokens":        890000,
  "cache_created_tokens":      45000,
  "turns":                       1234,
  "tool_calls":                  5678,
  "truncation_bytes_saved":  12345678,
  "by_provider": [
    { "provider": "anthropic", "input_tokens": 800000, "output_tokens": 150000 },
    { "provider": "openai",    "input_tokens": 434567, "output_tokens":  84567 }
  ],
  "by_model": [
    { "model": "claude-opus-4-7", "input_tokens": 800000, "output_tokens": 150000 }
  ]
}
```

### What's counted

Per turn, accumulated into the session JSON's `meta.stats` block:

- `input_tokens` / `output_tokens` — prompt + response tokens.
- `cache_read_tokens` / `cache_created_tokens` — Anthropic / OpenAI prompt-cache hit/write counts.
- `turns` — each user→assistant round-trip.
- `tool_calls` — count of `tool_use` blocks dispatched.
- `truncation_bytes_saved` — sum of `original_size − truncated_size` across `tool_output_cap` diversions.

`by_provider` / `by_model` rollups sum across every session in `$PASCLAW_HOME/workspace/sessions/`.

### Gateway endpoint buckets

The gateway's own stateless API endpoints (`/v1/chat`, `/v1/chat/completions`, `/v1/responses`) accumulate into per-endpoint synthetic session files (`_gateway_v1_chat.json`, `_gateway_v1_chat_completions.json`, `_gateway_v1_responses.json`) so calls driven through the web UI chat or any other OpenAI/Anthropic-compatible client also show up in `/v1/stats`. Each endpoint gets one bucket regardless of model — `Meta.Model` tracks the most recent request's model, so the `by_model` rollup reflects the latest call rather than per-call breakdown for those buckets. Concurrent gateway requests serialise the bucket update through a single critical section.

### Web UI Stats tab

`pasclaw gateway` serves a Stats tab that auto-refreshes every 10s and renders the cards + rollup tables. When `stats_collection_enabled: false` the panel shows a hint pointing at the config flag rather than a wall of zeros.

## TUI `/stats` overlay

Type `/stats` inside `pasclaw tui` for a read-only modal showing:

- Per-session token totals (in / out / cache_r / cache_w).
- Turn count + wall-clock elapsed.
- Truncation count + bytes saved.
- OutputCache handles held.
- Per-tool call counts (top 8 rendered).

Pairs with `tool_output_cap` so the savings are visible — type `/stats` after a long session, see the bytes saved climb. Any key dismisses the overlay.

The overlay uses an in-process accumulator and works **regardless** of `stats_collection_enabled`. Persistence is a separate setting.

## Logging

Logger levels: `debug`, `info`, `warn`, `error`, `silent`. Default `info`. Configure via:

```json
"gateway": { "log_level": "info" }
```

Or set via `--quiet` / `-q` (clamps the logger to `error` for the whole process so `[info]` noise doesn't pollute the stdout pipeline scripts read).

Each log line goes to stderr (so stdout stays clean for `pasclaw agent --quiet -m "..."` callers) **and** into a 1000-entry ring buffer the gateway exposes at `GET /v1/logs` (SSE tail).

## See also

- [Gateway and OpenAI-compatible API](./gateway.md#v1stats--operator-metrics) for the full `/v1/stats` shape.
- [Configuration](./configuration.md#opentelemetry-diagnostics) for the OTel config block.
- [Architecture](./architecture.md) for how the agent loop fires the spans.
