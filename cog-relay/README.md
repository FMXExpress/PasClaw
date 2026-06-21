# PasClaw RELAY cog

A Replicate [cog](https://github.com/replicate/cog) that runs `pasclaw relay` -- a pull-worker for the [relay provider pattern](../docs/providers-relay.md). The cog acts as a remote inference back-end for a separate PasClaw gateway: it polls the gateway's `/v1/relay/poll`, drains inference jobs, runs them through a locally-configured provider (OpenAI / Anthropic / Gemini / Groq / OpenRouter / DeepSeek / Ollama / LM Studio / vLLM / custom), and POSTs the results back to `/v1/relay/respond/<id>`.

Sibling to [`/cog/`](../cog/) (one-shot `pasclaw agent`) and [`/cog-build/`](../cog-build/) (multi-iter `pasclaw build` with workspace.zip handshake).

## Why

Decouple LLM credentials from the gateway. Put a $500-budget API key on the cog -- the credential boundary -- and point a gateway running on a laptop, a home server, a CI runner, or a friend's machine at the cog. The gateway gets the LLM's capacity *without ever holding the key*. The key only exists inside Replicate's encrypted Secret store and the running cog container.

Three flows this unblocks:

1. **Shared family LLM**: one household deployment of cog-relay with the family's API key; each family member's PasClaw points at the same gateway. Per-device PasClaw never sees the key.
2. **Bursty CI**: a Replicate deployment is cheap when idle. Wrap predict() in a CI workflow that spins it up before kicking off a build, tears it down after. Gateway-side `pasclaw build` runs against it.
3. **Air-gapped gateway**: gateway runs on a network that can reach Replicate but not your provider's API directly. The cog bridges the gap.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `gateway_url` | str | -- | **Required.** Remote PasClaw gateway base URL. Worker opens SSE to `<url>/v1/relay/poll`. |
| `gateway_token` | Secret | -- | **Required.** Bearer for `/v1/relay/*`. The same `PASCLAW_GATEWAY_TOKEN` the gateway is configured with. |
| `lifetime_seconds` | int | 300 | How long the worker polls before predict() returns. One prediction = one polling window. |
| `worker_id` | str | "" | Worker identity shown on the gateway's `/v1/relay/status` panel. Empty = auto-generated `cog-relay-<random>`. |
| `*_api_key` | `Optional[Secret]` | None | Cloud provider creds: openai / anthropic / gemini / groq / openrouter / deepseek. Stored encrypted, masked in logs. |
| `ollama_url` / `lmstudio_url` / `vllm_url` | str | "" | Self-hosted OpenAI-compatible server URLs reachable from the cog container. |
| `custom_provider_kind` | str | "" | Catalog kind for any OpenAI-compatible endpoint not surfaced as a dedicated input: `mistral` / `xai` / `cerebras` / `moonshot` / `qwen` / `zhipu` / `perplexity` / `nvidia` / `volcengine` / `minimax` / `novita` / `litellm` / `mimo`, or `openai-compat` for in-house endpoints. |
| `custom_provider_url` / `custom_provider_key` / `custom_provider_model` | str / Secret / str | -- | The generic escape hatch. |
| `provider` | str | "" | Which configured provider to forward jobs through. Empty = first configured wins. |
| `model` | str | "" | Capability the worker advertises to the gateway's queue. Empty = provider's default. Pass a deliberate non-default string to make this worker handle only requests for that model id. |

**At least one provider must be configured** -- the worker forwards jobs *through* a provider, so it needs one. Either a cloud key, a local-server URL, or the `custom_provider_*` set.

## Output

A single string: the worker's captured stdout. Each completed dispatch logs one `relay worker: completed <id>` line, so a simple `grep -c 'completed'` on the output gives the jobs-served count for the window.

## Continuous coverage

One prediction is one polling window. For continuous worker coverage, wrap predict() in a loop:

```python
import replicate, time

while True:
    out = replicate.run(
        "your-handle/pasclaw-relay",
        input={
            "gateway_url":       "https://gateway.example.com:8888",
            "gateway_token":     {"$secret": "GATEWAY_TOKEN"},
            "openai_api_key":    {"$secret": "OPENAI_KEY"},
            "lifetime_seconds":  300,
        },
    )
    served = out.count("relay worker: completed")
    print(f"served {served} jobs this window")
    time.sleep(1)
```

Or push the cog as a Replicate deployment and use the deployment's queue auto-scaling.

## Sandbox / shell / tools

The worker is a thin `Provider.Chat()` bridge -- it never runs tools, never touches the filesystem outside its scratch dir, never executes shell. Tool *definitions* arrive on the wire as part of each request envelope (so the provider can advertise them to the model) and any tool *calls* in the model's reply are forwarded verbatim back to the gateway; the gateway-side PasClaw owns the agent loop and dispatches tools there.

So sandbox configuration is irrelevant on the cog side. The shell/sandbox toggles a normal `pasclaw agent` cog uses don't apply.

## How it works (one prediction lifecycle)

1. Predictor builds a `config.json` with the chosen provider in `$PASCLAW_HOME`.
2. Spawns `pasclaw relay --gateway-url ... --gateway-token ...`.
3. The Pascal worker opens a long-poll SSE GET to `<gateway>/v1/relay/poll` with `Authorization: Bearer <token>`, `X-Relay-Worker-Id: <id>`, `X-Relay-Capabilities: <model>`.
4. As each `data: {...}` event arrives, the worker decodes the [request envelope](../docs/providers-relay.md#request-envelope), calls `Provider.Chat(messages, tools, model, options)`, encodes the result as the [response envelope](../docs/providers-relay.md#response-envelope), and POSTs to `<gateway>/v1/relay/respond/<id>`.
5. After `lifetime_seconds`, the predictor sends SIGTERM. The worker drops the SSE socket; the gateway's poll handler sees the disconnect and requeues any in-flight job for the next polling worker. Predict() returns the captured log.
