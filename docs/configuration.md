# Configuration

PasClaw stores configuration as a single JSON file at `$PASCLAW_HOME/config.json`. Every field has a sensible default; nothing here is required for a basic setup.

## File location

| Override | Effect |
|---|---|
| `$PASCLAW_HOME` | Sets the PasClaw home directory. Default: `~/.pasclaw/`. |
| `$PASCLAW_CONFIG` | Sets the config-file path explicitly. Default: `$PASCLAW_HOME/config.json`. |

## Helpers

```sh
pasclaw onboard       # interactive setup; idempotent — re-run any time
pasclaw config        # print the current JSON
pasclaw config path   # print the resolved path
pasclaw config reset  # write a default config
```

## `${VAR_NAME}` environment-variable substitution

`config.json` string values can reference environment variables with the openclaw `${VAR_NAME}` syntax. At `LoadConfig` time PasClaw resolves every marker in the raw JSON body before parsing, so the rest of the codebase sees the substituted value.

```json
{
  "providers": [
    { "name": "anthropic",
      "kind": "anthropic",
      "api_key": "${ANTHROPIC_API_KEY}",
      "model":   "claude-opus-4-7" }
  ],
  "gateway": {
    "token": "${PASCLAW_GATEWAY_TOKEN}"
  },
  "channels": [
    { "name":   "ops",
      "kind":   "discord",
      "target": "${OPS_DISCORD_WEBHOOK}" }
  ]
}
```

### Pattern

`${[A-Z_][A-Z0-9_]*}` — matches openclaw exactly:

- Uppercase only. Lowercase names don't match: `${api_key}` is left in place verbatim.
- First character must be `A-Z` or `_`. Digit-first names don't match: `${1FOO}` is left in place.
- Subsequent characters allow digits: `${FOO_42}` matches if `FOO_42` is set.
- No dashes: `${WITH-DASH}` is left in place.

### Behaviour on unset env

When the named env var is unset (or set to empty), the literal `${VAR_NAME}` is left in the config string. This is deliberate — `pasclaw config show` then prints the unresolved marker so an operator can see exactly which variable didn't resolve. No error, no abort, no silent substitution to empty.

### JSON safety

Substituted values are JSON-escaped on the fly: `"`, `\`, and control bytes get the standard `\"` / `\\` / `\u00xx` treatment. An `ANTHROPIC_API_KEY=foo"bar` env value yields valid `{"api_key":"foo\"bar"}` JSON, not a broken parse.

### Round-trip with `SaveConfig`

Substitution is **not preserved** through `SaveConfig`. Any config-mutating CLI command (`pasclaw auth login`, `pasclaw model set`, `pasclaw skills install`, ...) round-trips through `TConfig.FromJSON` → memory → `TConfig.ToJSON`, and by that point the marker has already resolved to its literal value. The next `SaveConfig` writes the resolved value, not the marker.

If you want a secret to live **only** in the environment and never get persisted, prefer the dedicated env-var path:

- `PASCLAW_GATEWAY_TOKEN` (or `OPENCLAW_GATEWAY_TOKEN`) for the gateway bearer — see [Gateway § Authentication](./gateway.md#authentication).
- Other dedicated env-only paths are documented per-feature.

### No literal `${UPPER}` value

There is no escape sequence for a literal `${UPPER}` string in a config value. Workarounds:

- Use the dedicated env-var path mentioned above (doesn't go through substitution at all).
- Downcase one letter so the pattern doesn't match: `${UPPER}` → `${Upper}`.
- Wrap with extra chars: `${{UPPER}}` resolves the outer `{UPPER}` (not a match — no opening `$`), so the literal stays. Note this only works because `${UPPER}` requires the leading `$` directly before `{`.

## Defaults

```json
{
  "default_provider": "anthropic",
  "default_model":    "claude-opus-4-7",
  "gateway":          { "log_level": "info", "bind_addr": "127.0.0.1", "port": 8088 },
  "providers":        [],
  "fallbacks":        [],
  "mcp_servers":      [],
  "crons":            [],
  "skills":           [],
  "subagents":        []
}
```

## Top-level fields

| Field | Default | Effect |
|---|---|---|
| `default_provider` | `"anthropic"` | Name of the entry in `providers[]` used when nothing overrides. |
| `default_model` | `"claude-opus-4-7"` | Default model id passed to the provider. |
| `fallbacks` | `[]` | Names of provider entries to walk on `429`/`5xx`/network error from the primary. Edit the array in `config.json` directly. |
| `gateway.log_level` | `"info"` | Logger level. `--quiet`/`-q` clamps to `error` for the whole process. |
| `gateway.bind_addr` | `"127.0.0.1"` | HTTP gateway bind. |
| `gateway.port` | `8088` | HTTP gateway port. |
| `gateway.token` | `""` | Inbound bearer token for `/v1/*` routes. Empty = unauthenticated (every route open — the default). When non-empty, every non-exempt route requires `Authorization: Bearer <token>` (or `?token=<token>` query param). `$PASCLAW_GATEWAY_TOKEN` env var overrides. See [Gateway](./gateway.md#authentication). |
| `prompt_cache.enabled` | `true` | Anthropic+OpenAI prompt caching. See [Providers](./providers.md). |
| `prompt_cache.ttl` | `"5m"` | Extended-TTL hint (Anthropic). Set `"1h"` for the long bucket. |
| `vector_search_enabled` | `true` | Hybrid FTS5+vector backend for `memory_search`. |
| `web_fetch_enabled` | `false` | Registers the `web_fetch` tool. Off by default — explicit opt-in. |
| `vault_tools_enabled` | `false` | Registers `vault_search` / `vault_get`. |
| `promptware_enabled` | `true` | Indirect-input prompt-injection scan. |
| `condense_reversible` | `true` | Stash original tool bytes under a `tool_output_get` handle when a condenser shrinks them. |
| `tool_output_cap` | `0` | Truncate tool outputs over this many bytes; model dereferences via `tool_output_get`. |
| `auto_router.enabled` | `false` | Cheap-tier routing for easy turns. See [Providers](./providers.md). |
| `stats_collection_enabled` | `false` | Persist per-turn counters into each session JSON's `meta.stats` block. |
| `orient_task_aware` | `false` | Lexical task-vs-section scoring for `MEMORY.md` injection. |
| `shell_backend` | `"local"` | `"local"` or `"docker"`. See [Security](./security.md). |
| `compaction.threshold_tokens` | `50000` | Trigger mid-loop history compaction over this many tokens. |
| `allow_senders` | `[]` | Identity allowlist for inbound channel messages. See [Channels](./channels.md). |

## Sandbox

See [Security and sandbox](./security.md) for the full key set. Quick example:

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

## OpenTelemetry diagnostics

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

Off by default. `OTEL_EXPORTER_OTLP_ENDPOINT` env var flips `enabled` to `true` on its own (standard OTel SDK contract). See [Observability](./observability.md) for the span shape.

## Heartbeat (proactive periodic wake-up)

```json
"heartbeat": { "enabled": true, "interval_mins": 30, "channel": "ops" }
```

`pasclaw heartbeat` reads `$PASCLAW_HOME/workspace/heartbeat.md` every `interval_mins` minutes, runs the agent loop on the body, and optionally posts the reply to a named channel.

## Subagents

```json
"subagents": [
  { "name": "researcher",
    "description": "Web search + summary specialist",
    "system_prompt": "You search the web and produce a 3-bullet summary...",
    "tools": ["web_search", "web_fetch"],
    "max_iterations": 4 },
  { "name": "coder",
    "description": "Code editor",
    "system_prompt": "You edit code precisely using hashline patches...",
    "tools": ["fs_read", "fs_write", "fs_grep", "fs_edit_hashline"] }
]
```

Each entry registers a `spawn(agent="<name>", prompt="...")` tool the parent agent can call. Optional `model` overrides the parent's default for that subagent.

## Environment variables

### Core

| Variable | Purpose |
|----------|---------|
| `PASCLAW_HOME` | PasClaw home directory. |
| `PASCLAW_CONFIG` | Config-file path. |
| `PASCLAW_VERSION` | Compile-time FPC version override used by the Makefile. |
| `PASCLAW_GATEWAY_TOKEN` | Inbound bearer token for the HTTP gateway. Overrides `gateway.token` in config.json when set. Empty = unauthenticated. Env value never persists into `config.json` (any later `SaveConfig` writes only the in-config value). |
| `OPENCLAW_GATEWAY_TOKEN` | Alias of `PASCLAW_GATEWAY_TOKEN` for openclaw-compat (operator porting an existing openclaw `.env` doesn't have to rename). `PASCLAW_` wins when both are set. |
| `NO_COLOR` | Disables ANSI color output. Equivalent to `--no-color`. |

### Web search

| Variable | Provider |
|---|---|
| `PASCLAW_BRAVE_API_KEY` | Brave Search. |
| `PASCLAW_TAVILY_API_KEY` | Tavily. |
| `PASCLAW_SEARXNG_API_KEY` | SearXNG (only for protected instances). |
| `PASCLAW_PERPLEXITY_API_KEY` | Perplexity Sonar. |
| `PASCLAW_GEMINI_API_KEY` / `PASCLAW_GOOGLE_API_KEY` | Gemini `google_search` grounding. |

Env values win over `web_search.api_key` so secrets stay out of `config.json`.

### Channels

| Variable | Purpose |
|---|---|
| `PASCLAW_TELEGRAM_TOKEN` | Telegram bot token (long-poll). |
| `PASCLAW_LINE_TOKEN` / `PASCLAW_LINE_SECRET` | LINE Messaging API; secret verifies `X-Line-Signature`. |
| `PASCLAW_WHATSAPP_TOKEN` / `PASCLAW_WHATSAPP_PHONE_ID` | WhatsApp Cloud API. |
| `PASCLAW_WHATSAPP_VERIFY_TOKEN` / `PASCLAW_WHATSAPP_APP_SECRET` | Webhook subscribe + `X-Hub-Signature-256` validation. |
| `PASCLAW_MATRIX_HOMESERVER` / `PASCLAW_MATRIX_TOKEN` | Matrix homeserver URL + access token. |
| `PASCLAW_IRC_SERVER` / `PASCLAW_IRC_PORT` / `PASCLAW_IRC_NICK` / `PASCLAW_IRC_CHANNEL` / `PASCLAW_IRC_PASSWORD` | IRC bot. |

### OpenTelemetry (standard SDK contract)

| Variable | Purpose |
|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Collector URL. Setting this alone enables OTel. |
| `OTEL_EXPORTER_OTLP_HEADERS` | `"k1=v1,k2=v2"` — auth headers for hosted backends. |

## See also

- [Sessions](./sessions.md) for `workspace/sessions/<id>.json` shape.
- [Providers](./providers.md) for `providers[]` entries.
- [Security and sandbox](./security.md) for the `sandbox.*` keys in depth.
