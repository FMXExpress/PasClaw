# Web search

Two tools, both registered automatically alongside the filesystem and shell tools:

- **`web_search(query, k?)`** — returns up to `k` results as title + URL + snippet. Dispatches to the configured provider; defaults to DuckDuckGo when nothing is set.
- **`web_fetch(url, max_chars?)`** — fetches an `http://` or `https://` URL and returns the response body as readable plain text (HTML tags stripped, entities decoded, whitespace collapsed, capped at 50 KB by default). Registered only when `web_fetch_enabled: true`.

## Provider configuration

```json
"web_search": {
  "provider":    "brave",
  "api_key":     "",
  "max_results": 5
}
```

| Provider | API key needed? | Source |
|---|---|---|
| `duckduckgo` (default) | no | HTML scrape of `html.duckduckgo.com/html/`. |
| `brave` | yes — `$PASCLAW_BRAVE_API_KEY` overrides `api_key` | `api.search.brave.com/res/v1/web/search`. |
| `tavily` | yes — `$PASCLAW_TAVILY_API_KEY` overrides `api_key` | `api.tavily.com/search`. |
| `searxng` | no (most public instances); optional `$PASCLAW_SEARXNG_API_KEY` for protected ones | `<web_search.base_url>/search?format=json`. |
| `perplexity` | yes — `$PASCLAW_PERPLEXITY_API_KEY` overrides `api_key` | `api.perplexity.ai/chat/completions` (Sonar model — returns one synthesised answer plus citation URLs). |
| `gemini` | yes — `$PASCLAW_GEMINI_API_KEY` (or `$PASCLAW_GOOGLE_API_KEY`) overrides `api_key` | `generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent` with `google_search` grounding — returns one synthesised answer plus the ground-truth source URLs Gemini consulted. |

Env-var values win over the `api_key` field so secrets can stay out of `config.json`.

## SearXNG

```json
"web_search": {
  "provider": "searxng",
  "base_url": "https://searx.be"
}
```

Every SearXNG instance is self-hosted; `base_url` is required. Most public instances don't need auth; set `$PASCLAW_SEARXNG_API_KEY` only if your instance is protected by a Bearer-token reverse proxy.

## DDG behaviour note

DuckDuckGo's HTML endpoint started TLS-fingerprinting non-browser clients in 2025. The scrape fallback is **disabled by default** — its bot detection refuses non-browser requests at the TLS-fingerprint level. The `[info] web_search disabled: no real provider configured` log line at startup is your signal to pick one of the keyed providers above.

## `web_fetch`

```json
"web_fetch_enabled": true
```

Off by default. Explicit opt-in keeps the agent from making outbound HTTP unless the operator agreed.

### SSRF guard

Every `web_fetch` URL — initial request and every redirect hop — goes through `PasClaw.Net.SSRF.IsBlocked`. Blocked ranges include cloud-metadata (`169.254.169.254`), all of RFC1918, loopback, link-local, CGNAT, IETF-reserved. See [Security](./security.md#ssrf-guard).

To allow internal addresses for local development:

```json
"sandbox": { "block_private_networks": false }
```

Weigh the credentials-leak risk. The metadata endpoint is the canonical SSRF exfiltration vector on AWS / GCP / Azure.

### Content extraction

`web_fetch` runs the response through `PasClaw.Search.HTMLText`:

1. Strip script / style / iframe blocks.
2. Decode HTML entities (`&amp;`, `&#x27;`, etc.).
3. Strip remaining tags.
4. Collapse runs of whitespace.
5. Cap at `max_chars` (default 50 KB).

The output is plain text suitable for the model. If you need the raw HTML, use a `shell_exec` tool with `curl` instead — `web_fetch` is intentionally read-friendly, not byte-accurate.

## Server-side search (provider-native)

In addition to the `web_search` tool, three providers support **native** search grounding when their model is the active one:

- **Gemini `google_search`** — default-on for Gemini 3+ in the function-calling combo. Configurable via the per-request `tools` array; the gateway forwards the grounding metadata back as inline citations.
- **OpenAI `web_search_options`** — default-on for genuine OpenAI endpoints only (compatibility shims skip it).
- **Perplexity Sonar** — every response carries citation URLs alongside the synthesised answer; collation lives in `PasClaw.Providers.OpenAI` since Sonar speaks the OpenAI protocol.

These run **server-side at the provider** — no `web_search` round-trip from PasClaw. Faster, but the operator can't pick the search provider per call. To force the tool path: pass `--no-server-search` to `pasclaw agent` or set `web_search.disable_server_grounding: true` in `config.json`.

## See also

- [Tools](./tools.md) — `web_search` / `web_fetch` schemas.
- [Security and sandbox](./security.md#ssrf-guard) — SSRF guard details.
- [Configuration](./configuration.md#environment-variables) — env-var precedence for API keys.
