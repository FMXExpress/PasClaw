# Providers

PasClaw ships a catalog of 19+ LLM providers covering three protocol families. Adding a provider is a one-record append to `src/pkg/providers/PasClaw.Providers.Catalog.pas`.

## Protocol families

- **`pfAnthropic`** — Anthropic Messages API (`POST /v1/messages`), `x-api-key` header.
- **`pfOpenAI`** — OpenAI Chat Completions-compatible (`POST /v1/chat/completions`). Powers OpenAI and the bulk of hosted/local providers.
- **`pfGemini`** — Google Gemini `generateContent` REST API, `x-goog-api-key` header.
- **`pfPlaceholder`** — catalog slot for known providers not wired in this build.

All three protocols stream via SSE.

## Auth schemes

| Scheme | Header |
|---|---|
| `asBearer` | `Authorization: Bearer <key>` |
| `asNone` | no auth header (local Ollama / vLLM) |
| `asHeader` | raw key in the catalog-specified header name |

## Catalog

| Provider | `kind` | Family | Default base | Default model | Auth |
|----------|--------|--------|--------------|---------------|------|
| Anthropic | `anthropic` | Anthropic | `https://api.anthropic.com` | `claude-opus-4-7` | `x-api-key` header |
| OpenAI | `openai` | OpenAI-compatible | `https://api.openai.com` | `gpt-4o-mini` | Bearer |
| OpenRouter | `openrouter` | OpenAI-compatible | `https://openrouter.ai/api` | provider-selected | Bearer |
| Zhipu (GLM) | `zhipu` | OpenAI-compatible | `https://open.bigmodel.cn/api/paas` | `glm-4` | Bearer |
| DeepSeek | `deepseek` | OpenAI-compatible | `https://api.deepseek.com` | `deepseek-chat` | Bearer |
| Volcengine (Doubao/Ark) | `volcengine` | OpenAI-compatible | `https://ark.cn-beijing.volces.com/api` | provider-selected | Bearer |
| Qwen (DashScope) | `qwen` | OpenAI-compatible | `https://dashscope.aliyuncs.com/compatible-mode` | `qwen-max` | Bearer |
| Groq | `groq` | OpenAI-compatible | `https://api.groq.com/openai` | provider-selected | Bearer |
| Moonshot (Kimi) | `moonshot` | OpenAI-compatible | `https://api.moonshot.cn` | `moonshot-v1-32k` | Bearer |
| MiniMax | `minimax` | OpenAI-compatible | `https://api.minimax.chat` | provider-selected | Bearer |
| Mistral | `mistral` | OpenAI-compatible | `https://api.mistral.ai` | `mistral-large-latest` | Bearer |
| NVIDIA NIM | `nvidia` | OpenAI-compatible | `https://integrate.api.nvidia.com` | provider-selected | Bearer |
| Cerebras | `cerebras` | OpenAI-compatible | `https://api.cerebras.ai` | provider-selected | Bearer |
| Novita AI | `novita` | OpenAI-compatible | `https://api.novita.ai` | provider-selected | Bearer |
| Xiaomi MiMo | `mimo` | OpenAI-compatible | set `api_base` in config | provider-selected | Bearer |
| xAI Grok | `xai` | OpenAI-compatible | `https://api.x.ai` | provider-selected | Bearer |
| LM Studio (local) | `lmstudio` | OpenAI-compatible | `http://localhost:1234` | required during onboarding | none |
| Ollama (local) | `ollama` | OpenAI-compatible | `http://localhost:11434` | required during onboarding | none |
| vLLM (local) | `vllm` | OpenAI-compatible | `http://localhost:8000` | required during onboarding | none |
| LiteLLM proxy | `litellm` | OpenAI-compatible | set `api_base` in config | provider-selected | Bearer |
| Google Gemini | `gemini` | Gemini | `https://generativelanguage.googleapis.com` | `gemini-1.5-flash` | `x-goog-api-key` header |

The source of truth is `src/pkg/providers/PasClaw.Providers.Catalog.pas`. To add a provider, append a `TProviderCatalogEntry` record.

## Authentication

```sh
pasclaw auth login anthropic       # prompt for API key, store in providers[].api_key
pasclaw auth logout anthropic
pasclaw auth status                # show which providers have keys
```

To set the fallback chain, edit `fallbacks` in `config.json` directly:

```json
"fallbacks": ["openai", "gemini"]
```

Per-provider entry in `config.json`:

```json
"providers": [
  {
    "name":     "anthropic",
    "kind":     "anthropic",
    "api_base": "https://api.anthropic.com",
    "api_key":  "sk-ant-...",
    "model":    "claude-opus-4-7"
  }
]
```

`name` is operator-facing (referenced by `default_provider` and `fallbacks[]`); `kind` selects the catalog entry. You can register the same `kind` under multiple `name`s — e.g. one OpenAI entry pointed at the real OpenAI and another pointed at a LiteLLM proxy.

## Model selection

```sh
pasclaw model show
pasclaw model set claude-opus-4-7
pasclaw model add openai gpt-4o-mini
pasclaw model refresh anthropic              # GET /v1/models → cache
pasclaw model refresh --all
pasclaw model list openai                    # show cached roster
```

`model refresh` hits the provider's live `/v1/models` endpoint (supported on Anthropic / OpenAI / Gemini / xAI / Groq / OpenRouter / DeepSeek / Mistral / Moonshot / Cerebras / Ollama / vLLM / LM Studio — anything in the catalog), caches the result under `$PASCLAW_HOME/cache/models/<provider>.json`, and shows the count.

`pasclaw onboard` runs the same fetch automatically once you've entered the API key and presents a numbered picker over the top 12 newest models. Discovery fails gracefully when the endpoint is unreachable — the wizard falls back to free-form text input.

## Fallback chain

```json
{
  "default_provider": "anthropic",
  "fallbacks":        ["openai", "gemini"]
}
```

When the primary returns `429` / `5xx` / network / TLS error, PasClaw walks `fallbacks[]` in order, calling each `name` in turn until one returns `2xx` or all fail. Single-provider failure surfaces directly when `fallbacks[]` is empty.

For embedders the same chain is available code-driven via `Agent.SetProvider(...)`.

## Prompt caching

On by default for Anthropic and OpenAI. The Anthropic request builder emits `cache_control: { type: "ephemeral" }` on the system prompt and the trailing `tools[]` entry (uses 2 of the 4-breakpoint budget). OpenAI gets `prompt_cache_key` anchored to the persistent session id so each conversation routes to its own cache bucket.

Cache hit / write tokens roll up in `pasclaw status` (`cache: on, N read / M written`) and surface inline in the per-turn `[tokens in=… out=… cache_r=… cache_w=…]` summary.

```json
"prompt_cache": { "enabled": true, "ttl": "5m" }
```

Set `"ttl": "1h"` for the Anthropic extended-TTL bucket. Disable entirely with `"enabled": false`. Gemini caching is not yet wired — implicit caching applies automatically on supported models.

## Auto-router (cheap-tier routing)

```json
"auto_router": {
  "enabled":         true,
  "easy_provider":   "groq",
  "easy_max_tokens": 500
}
```

Heuristic classifies each user message as easy / abstain / hard from three signals: hard-keyword markers (`implement`, `refactor`, `debug`, `fix bug`, `write tests`, `optimize`), token count over `easy_max_tokens`, and tool-mix gate (when `shell_exec` / `execute_code` / `fs_write` are in the registry, ambiguous one-word messages abstain because they might mean "go run the script").

Only when all three agree on **easy** does the agent swap providers for that turn. The original primary is automatically prepended to the fallback chain so a misclassified easy that the cheap provider fumbles falls back transparently.

Each routed turn surfaces `(routed -> <provider>, auto-routed)` in the assistant header so it's never invisible.

## Server-side capabilities

Auto-detected per provider on supported routes:

- **Gemini native search grounding** — server-side `google_search` tool, default-on for Gemini 3+ in the function-calling combo.
- **Gemini 3 `thoughtSignature`** — round-tripped on `functionCall` parts for tool-use continuations; server-side `call_id` → signature cache on `/v1/responses` so stock OpenAI clients (Codex CLI etc.) keep signatures across turns.
- **OpenAI `web_search_options`** — server-side web search, default-on for genuine OpenAI endpoints only (compatibility shims skip it).
- **Perplexity Sonar citation collation** — one synthesised answer plus the source URLs the model consulted.

## Minimal local-provider configs

Ollama:

```json
{
  "default_provider": "ollama",
  "default_model":    "llama3.1:8b",
  "providers": [{
    "name":     "ollama",
    "kind":     "ollama",
    "api_base": "http://localhost:11434",
    "api_key":  "",
    "model":    "llama3.1:8b"
  }]
}
```

vLLM:

```json
{
  "default_provider": "vllm",
  "default_model":    "your-model",
  "providers": [{
    "name":     "vllm",
    "kind":     "vllm",
    "api_base": "http://localhost:8000",
    "api_key":  "",
    "model":    "your-model"
  }]
}
```

LM Studio works the same way — `"kind": "lmstudio"`, `"api_base": "http://localhost:1234"`.

## Adding a provider

1. Append a record to `src/pkg/providers/PasClaw.Providers.Catalog.pas`:

   ```pascal
   (Name: 'mycorp';
    Family: pfOpenAI;
    DefaultBase: 'https://api.mycorp.example/v1';
    DefaultModel: 'mc-large';
    AuthScheme: asBearer;
    AuthHeader: '';
    Description: 'MyCorp hosted LLM')
   ```

2. Rebuild. `pasclaw onboard` and `pasclaw auth login mycorp` pick it up automatically.

For a genuinely new protocol family (not OpenAI / Anthropic / Gemini compatible), add an HTTP client unit under `src/pkg/providers/` mirroring `PasClaw.Providers.Anthropic.pas` and wire it through `PasClaw.Providers.Factory.pas`.

## See also

- [Configuration](./configuration.md) for `providers[]` / `fallbacks[]` / `auto_router` / `prompt_cache`.
- [Gateway and OpenAI-compatible API](./gateway.md) for how the gateway uses the same provider chain server-side.
- [Embedding in your own app](./embedding.md) for code-driven `SetProvider` in embedders.
