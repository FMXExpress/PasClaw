# PasClaw BUILD cog

A Replicate [cog](https://github.com/replicate/cog) that exposes `pasclaw build` — multi-iteration agent runs with a `workspace.zip` handshake — for use against ephemeral cloud compute.

Sibling to [`/cog/`](../cog/), which runs the simpler one-shot `pasclaw agent` flow. This one is for the "ship the whole brain back and forth" pattern: feed in a workspace.zip from a previous run, get a workspace.zip back containing everything the agent did (memory updates, knowledge-base writes, checkpoint history, source files written, …).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `message` | str | — | The build task ("add X", "port Y to Z", …) |
| `max_iters` | int | 50 | Tool-loop iteration budget |
| `timeout_seconds` | int | 3600 | Subprocess timeout (Replicate's container ceiling applies on top) |
| `workspace_in` | `Optional[Path]` | None | *Optional.* Workspace archive from a previous build. Cog handles both upload + URL via Path. Leave empty for a fresh run. |
| `workspace_in_url` | str | "" | *Optional.* Explicit URL — downloaded via [`pget`](https://github.com/replicate/pget) for parallelism. Wins over `workspace_in` when set. |
| `openai_api_key` / `anthropic_api_key` / `gemini_api_key` / `groq_api_key` / `openrouter_api_key` / `deepseek_api_key` | `Optional[Secret]` | None | Cloud-provider creds. [Cog Secret inputs](https://replicate.com/changelog/2024-06-07-secret-inputs-for-models) — stored encrypted on Replicate, masked in the UI, never appear in prediction-input logs. |
| `ollama_url` / `lmstudio_url` / `vllm_url` | str | "" | Base URL of a self-hosted OpenAI-compatible server reachable from the cog container (ngrok / Cloudflare Tunnel / Tailscale Funnel / public IP). No API key — PasClaw uses `asNone` auth for these. |
| `custom_provider_kind` | str | "" | Catalog kind for any OpenAI-compatible provider not surfaced as a dedicated input: `mistral`, `xai`, `cerebras`, `moonshot`, `qwen`, `zhipu`, `perplexity`, `nvidia`, `volcengine`, `minimax`, `novita`, `litellm`, `mimo`, or `openai-compat` for an in-house gateway. |
| `custom_provider_url` | str | "" | `api_base` URL for the custom provider. Required when `custom_provider_kind` is set. |
| `custom_provider_key` | `Optional[Secret]` | None | API key for the custom provider. Leave empty if the endpoint needs no auth. |
| `custom_provider_model` | str | "" | Default model id for the custom provider. |
| `provider` | str | "" | Route through this provider name. Any of the cloud names above, `ollama` / `lmstudio` / `vllm`, or whatever's in `custom_provider_kind`. Empty = first configured provider wins. |
| `model` | str | "" | Override the model id. Empty = provider's catalog default (or whatever the local server is currently serving). |
| `profile` | str | `"max-build"` | PasClaw [config profile](../docs/configuration.md#profiles) applied on top of stock defaults. See **Profile defaults** below for what `max-build` flips on, and the other built-ins. Empty to skip. |

### Profile defaults

The cog defaults `profile` to **`max-build`** — the richest unattended-build toolset. Compared to PasClaw's stock defaults, `max-build` turns on:

- `web_fetch`, `web_search` — let the model fetch docs and crawl the web for API references
- `vector_search` — better memory recall via the hybrid FTS+vector backend
- `auto_router` — route cheap turns to a cheap model
- `prompt_cache` — Anthropic / OpenAI prompt-cache TTL on (1 h)
- `condense_reversible` — longer effective context windows
- `orient_task_aware` — only task-relevant memory sections enter the system prompt
- `promptware` — prompt-injection guard scans incoming tool output
- the self-improving-skills suite (4 switches)
- vault tools (Code Vault search)
- `tool_output_cap` bumped from 0 (uncapped) to 16384

Override `profile` to:
- `baseline` — everything off. A/B reference against a feature-poor PasClaw.
- `low-token` — cheaper / smaller context. Same flags as `max-build` *minus* the wide-net ones.
- `security` — workspace restriction + shell deny + private-network block; promptware on; vault and `web_fetch` off; agent-authored skills stage for approval.
- `all-on` — inherits `max-build` and flips every remaining boolean. Surface-area testing only.
- *(empty)* — skip profile application entirely.

Profile is layered *under* the seeded `config.json` fields (provider catalog, sandbox, `checkpoints_enabled`), so the cog's explicit choices always win over the profile.

**At least one provider must be configured** — either a cloud API key, a local-server URL, or the `custom_provider_*` set.

## Outputs

A list of **two file URLs** in this order:

```jsonc
[
  "https://replicate.delivery/.../workspace_out_xxxx.zip",  // [0] new PASCLAW_HOME archive
  "https://replicate.delivery/.../reply_out_xxxx.txt"       // [1] model's final reply text
]
```

Why a list of two URLs instead of a `BaseModel(workspace: Path, text: str)`? Cog's nested-Path upload path was unreliable in some runtime versions — the workspace zip came back base64-encoded inline instead of as a CDN URL. `list[Path]` gets uploaded reliably.

The reply text lives in a tiny `.txt` file so the caller can fetch it with one HTTP GET to decide whether to continue. Typical control loop:

```python
import replicate
import requests

ws_url = None
for step in range(20):
    out = replicate.run(
        "owner/pasclaw-build",
        input={
            "message": "implement issue #42",
            "max_iters": 30,
            "workspace_in_url": ws_url,    # None on the first call
            "anthropic_api_key": KEY,      # passed as a Secret
        },
    )
    ws_url    = out[0]                     # workspace zip URL
    reply_url = out[1]                     # reply text URL
    reply     = requests.get(reply_url).text
    print(reply)
    if "DONE" in reply:
        break
```

## Using a local LLM server (Ollama / LM Studio / vLLM)

PasClaw's catalog has entries for `ollama`, `lmstudio`, and `vllm`. They default to `localhost:11434` / `localhost:1234` / `localhost:8000`, which makes sense on a developer laptop running `pasclaw tui` — but on Replicate, "localhost" is the cog container, not your machine.

To route a build through your own GPU, expose the local server via a publicly-reachable URL:

```sh
# Ollama on your laptop
ollama serve &
ngrok http 11434

# LM Studio on a desktop
# (LM Studio's "Local Server" tab; default port 1234)
ngrok http 1234

# vLLM on a cloud box
vllm serve meta-llama/Llama-3.1-8B-Instruct --host 0.0.0.0 --port 8000
# point cog at http://that-box.example.com:8000
```

Then pass the tunnel URL as `ollama_url=https://abc-xyz.ngrok-free.app` (or the equivalent input). No API key needed — these endpoints use `asNone` auth in PasClaw's catalog.

## Using any other PasClaw catalog provider

Twelve catalog entries that aren't surfaced as dedicated inputs — `mistral`, `xai`, `cerebras`, `moonshot`, `qwen`, `zhipu`, `perplexity`, `nvidia`, `volcengine`, `minimax`, `novita`, `litellm`, `mimo` — are reachable via the generic escape hatch:

```python
custom_provider_kind  = "mistral"
custom_provider_url   = "https://api.mistral.ai"
custom_provider_key   = "secret-key-here"
custom_provider_model = "mistral-large-latest"
provider              = "mistral"   # tell pasclaw to route through this one
```

The `kind` value goes straight into PasClaw's `NormalizeProviderKind`, so the catalog's existing protocol/auth handling kicks in unchanged. For any OpenAI-compatible endpoint **not** in the catalog (your own gateway, a brand-new provider PasClaw hasn't caught up with), use `kind = "openai-compat"` — `NormalizeProviderKind` aliases it to `openai`.

## Workspace contents

Everything under `$PASCLAW_HOME` ships back:

```
workspace/
├── memory/MEMORY.md           ← rules + scars carry forward
├── kb.db                      ← knowledgebase
├── kb-files/*                 ← uploaded reference docs (including binaries)
├── sessions/<id>.json         ← chat history
├── checkpoints/<id>/          ← zpaq-backed undo/redo journal
│   ├── archive.zpaq
│   └── index.json
├── skills/                    ← installed skills
└── AGENTS.md                  ← project rules (if present)
```

A small denylist (`pasclaw build` enforces) keeps surrounding-repo noise out:
- `.git` directories at any depth
- `.DS_Store`, `Thumbs.db`
- `kb.db-journal` (SQLite WAL, regenerated)

Everything else — tmp files, log dumps, kb-files binaries — does ship. The whole point of the handshake is "preserve the entire brain".

### What does NOT ship: `config.json` (API keys)

`config.json` is deliberately kept **outside** `$PASCLAW_HOME` so it never ends up in `workspace.zip`:

- The predictor writes it to a sibling scratch dir and sets `PASCLAW_CONFIG` so PasClaw finds it there.
- API keys stay in the predict.py process scope.
- A `workspace_in.zip` from a prior run can't clobber the fresh API keys this call was given.
- The output `workspace.zip` is provider-agnostic — safe to log, share, or store anywhere the rest of the workspace already goes.

Backward-compatible with every other `pasclaw` caller: when `PASCLAW_CONFIG` is unset (the normal case for CLI / TUI / gateway users), `GetConfigPath` falls back to `$PASCLAW_HOME/config.json` exactly as it did before.

## Size cap

**4 GiB** input, enforced at both ends (Python + Pascal). Replicate's upload + container limits will catch this earlier in practice; the cap is there so a runaway caller fails fast with a clean error.

## Why `pget` for the input?

For large URL-backed workspaces (multi-hundred-MB checkpoint archives), cog's default Path-input fetch is single-stream. Replicate's [pget](https://github.com/replicate/pget) does parallel multi-connection downloads from S3-compatible storage — typically 3–5× faster. Use `workspace_in_url` (string) to opt in; `workspace_in` (Path) still works for upload-from-disk or smaller URLs that don't benefit from parallelism.

## Build

```sh
cd cog-build/
cog build -t pasclaw-build
```

Then push to Replicate as usual.

## Run locally

```sh
cd cog-build/
cog predict \
  -i message="add a --version flag to the CLI" \
  -i max_iters=30 \
  -i anthropic_api_key=sk-ant-… \
  -i workspace_in=@/tmp/prev_workspace.zip
```
