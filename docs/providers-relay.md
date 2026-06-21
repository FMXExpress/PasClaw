# Relay provider (pull-worker pattern)

The relay provider inverts the usual PasClaw → LLM-API relationship.
Instead of PasClaw making outbound HTTP calls to a hosted LLM, an
**external worker app** (a WebGPU browser tab, a phone with mlc-llm, a
desktop with llama.cpp, anything that speaks HTTP+SSE) connects
**inbound** to PasClaw's gateway, advertises which models it can serve,
pulls pending inference requests off PasClaw's queue, runs them on its
own hardware, and POSTs results back.

## Why

Three flows this unblocks that none of the existing catalog providers do:

- **WebGPU on your laptop without exposing ports.** Open a browser tab
  with WebLLM / Transformers.js / mlc-llm pointing at your PasClaw URL.
  The tab connects outbound; PasClaw never reaches the laptop. Closes
  when you close the tab.
- **Cog / Replicate-hosted PasClaw served by your phone.** PasClaw
  runs on Replicate (no GPU), inference happens on a phone in your
  pocket. The cog never talks to a paid LLM API.
- **Share a home GPU across devices.** Each device runs its own
  PasClaw; one home server runs the queue; the GPU machine connects as
  a worker.

## V1 scope

- Non-streaming. Worker returns one POST with the full completion.
  Streaming (chunks back through PasClaw to the agent loop's caller) is
  a V2 feature.
- Tool calls flow through the response envelope's **`tool_calls`
  array** (OpenAI shape: `id`, `type`, `function.name`,
  `function.arguments`). Workers using libraries that emit structured
  tool calls (WebLLM, mlc-llm, llama.cpp grammar mode) populate this;
  workers that emit only text omit the array and the agent gets
  text-only chat through the relay. There is **no text-extraction
  fallback** -- worker libraries that can't emit structured output
  yield text-only relay sessions. Most modern small-model runtimes
  support structured tool calls; this is the right floor for V1.
- Capability matching is **exact case-insensitive string match** on the
  model id. Glob / semver matching is V2.
- Single-process. One in-process queue, one set of workers.

## Wire protocol

Two HTTP endpoints on `pasclaw gateway`, both auth'd with the existing
`PASCLAW_GATEWAY_TOKEN`:

### `GET /v1/relay/poll` — SSE stream

The worker opens this once and keeps it alive. Each `data:` event ships
one pending inference request.

```http
GET /v1/relay/poll HTTP/1.1
Authorization: Bearer <PASCLAW_GATEWAY_TOKEN>
Accept: text/event-stream
X-Relay-Worker-Id: web-tab-abc123
X-Relay-Capabilities: llama-3.2-3b-instruct,phi-3-mini
```

Response stream:

```
data: {"id":"req_...", "model":"llama-3.2-3b-instruct", "messages":[...], "tools":[...], "options":{"max_tokens":8192,"system_prompt":"..."}}

data: {"id":"req_...", ...}
```

The first poll connection acts as the worker's **registration**: the
`X-Relay-Worker-Id` is the worker's identity, and `X-Relay-Capabilities`
is the comma-separated list of model ids it can serve. Re-connecting
with the same worker id updates capabilities (so a worker page reload
with a different model swap is transparent).

A worker with empty capabilities (no header, or empty string) is
treated as a **wildcard** — it accepts any model. Useful for "I'll
serve whatever you throw at me" workers without explicit capability
tracking.

**Query-string fallback for browser EventSource workers.** Native
browser `EventSource` ignores custom headers, so the gateway also
accepts `?token=<token>`, `?worker_id=<id>`, and `?caps=<a,b,c>` as
fallbacks for the equivalent headers. A header beats the query
param when both are present. Non-browser workers should keep using
the headers (no extra URL noise; nothing in query-string logs).

The queue does first-come-first-served dispatch: pending requests go to
the first connected worker whose capabilities match the request's
model. If no matching worker is connected, the request stays in the
queue until one shows up or the caller's timeout expires.

### `POST /v1/relay/respond/:id` — worker submits result

```http
POST /v1/relay/respond/req_... HTTP/1.1
Authorization: Bearer <PASCLAW_GATEWAY_TOKEN>
Content-Type: application/json

{
  "content": "The capital of France is Paris.",
  "finish_reason": "stop",
  "usage": {
    "prompt_tokens": 47,
    "completion_tokens": 8
  }
}
```

PasClaw matches `:id` to the waiting `TRelayProvider.Chat()` call,
hands it the result, and the agent loop continues. A late or duplicate
POST (worker submitted twice; another worker won the race) is dropped
silently — the waiting caller already got the first response.

### `GET /v1/relay/status` — operator surface

```json
{
  "pending_requests":   2,
  "inflight_requests":  1,
  "connected_workers":  3,
  "total_enqueued":     147,
  "total_completed":    144,
  "total_failed":       1,
  "workers": [
    { "id":"web-tab-abc",  "caps":["llama-3.2-3b"], "requests_seen": 52, "last_seen": "..." },
    { "id":"phone-xyz",    "caps":["phi-3-mini"],   "requests_seen": 89, "last_seen": "..." }
  ]
}
```

Used by the TUI panel and `pasclaw status`.

## Request envelope

```jsonc
{
  "id":         "req_...",              // ULID-ish; sortable + unique
  "model":      "llama-3.2-3b-instruct",// matched against worker capabilities
  "session_id": "sess_abc123",          // optional; opaque conversation id
                                        // (sourced from Options.CacheKey on the
                                        // PasClaw side -- the same key OpenAI
                                        // uses for prompt_cache_key). Drives
                                        // the queue's sticky-routing
                                        // preference and is available for the
                                        // worker's own KV-cache reuse. Omitted
                                        // entirely for one-shot turns.
  "messages": [
    { "role": "system",    "content": "..." },
    { "role": "user",      "content": "..." },
    { "role": "assistant", "content": "..." }
  ],
  "tools": [                            // empty array when no tools
    {
      "name":        "fs_read",
      "description": "Read a file ...",
      "parameters":  "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}"
    }
  ],
  "options": {
    "max_tokens":    8192,
    "temperature":   "0.7",             // string when set; omitted when 0
    "system_prompt": "..."              // convenience for OpenAI-shaped workers
  }
}
```

Workers parse `tools[].parameters` as a JSON-string-containing-JSON
(the schema is already JSON, we ship it verbatim under a string key).
Workers that don't support tool calling just ignore the `tools` array
and emit any tool calls as text in the response; PasClaw extracts them
on receipt.

## Response envelope

```jsonc
{
  "content":       "...",          // full assistant reply text
  "finish_reason": "stop",         // or "length" / "tool_calls" / ""
  "usage": {                       // optional; best-effort token accounting
    "prompt_tokens":     47,
    "completion_tokens": 12
  },
  "tool_calls": [                  // optional; OpenAI shape. Omit when the model
                                   // produced only text (e.g., smaller models
                                   // without tool-calling support). Workers
                                   // that support tool calling -- WebLLM,
                                   // mlc-llm, llama.cpp grammar mode --
                                   // populate this; PasClaw forwards verbatim
                                   // into TLLMResponse.ToolCalls and
                                   // RunToolLoop dispatches.
    {
      "id":   "call_0",
      "type": "function",
      "function": {
        "name":      "fs_read",
        "arguments": "{\"path\":\"foo.pas\"}"
      }
    }
  ]
}
```

Workers without a token counter can omit `usage`; PasClaw estimates via
its tokenizer if needed. Workers without tool-calling support omit
`tool_calls` entirely and the agent gets text-only chat through the
relay.

## Multi-worker semantics (this is important)

PasClaw's agent loop is **strictly sequential per session**. There is
only ever one outstanding `Provider.Chat()` call per session — the
next call's prompt literally depends on the previous call's response
being in the history. So "history desync from out-of-order responses"
**cannot happen** within a single session, even with 50 workers
connected.

Where multiple workers DO help: throughput across **independent**
sessions. Gateway serving 3 concurrent users → 3 sessions → each can
take one worker. Subagents (`TSpawnTool`) each get their own session,
own history, own inference call. Background-spawn is the same. In all
of these, sessions don't share history.

**Stale-response on timeout**: if a worker grabs a request, takes too
long, the request times out and gets requeued, a second worker picks it
up — both workers might eventually respond. PasClaw matches responses
by request id; whichever arrives first wins, late duplicates are
dropped. No history corruption possible. The wasted compute on the
late worker is real but harmless.

**Worker disconnect**: SSE drop detected → assigned requests are
requeued to the head of the queue. The next polling worker picks them
up. Bounded by `RelayMaxAttempts` (default 3) — after that many
requeues, the request fails the caller with a clear error rather than
looping forever.

## Sticky routing (KV-cache locality)

When a request carries a `session_id` (sourced from
`Options.CacheKey`, which the agent loop sets to `Session.Meta.Id`),
the queue remembers which worker last served that session and
preferentially routes the session's next turn to the same worker.
This keeps the model's working state hot in the worker's GPU memory
across multi-turn conversations — typically 5-10× speedup on turn 2+
with long contexts (PasClaw's typical case with MEMORY.md +
AGENTS.md + PLAN.md all loaded).

Dispatch is two-pass:

1. **Sticky pass** — scan pending requests for any whose session id
   is pinned to *this* polling worker. If found, take it.
2. **FCFS fallback** — take the head of the queue, BUT skip any
   request whose session is pinned to a *different currently-connected*
   worker. That worker just hasn't polled yet; stealing the request
   would re-pin the session on every cold-cache turn 2+ and defeat
   the routing. Take pinned-elsewhere requests only when the pinned
   worker has actually disconnected from the registry, so sessions
   don't starve on ghosts.

After assignment the sticky map is updated to whoever took the work,
so a session whose preferred worker disappeared gets re-pinned to its
new handler. When a worker unregisters, sticky entries pointing at it
are pruned so a fresh worker connecting under the same id doesn't
inherit stale stickiness and the map doesn't grow unbounded.

One-shot turns (empty `session_id`) never enter the sticky map — no
sticky preference, no map pollution from empty-key entries.

## Tuning the per-Chat wait timeout

`Options` exposed in `config.json`:

```jsonc
{
  "relay_wait_timeout_ms": 1800000   // 30 minutes; default 0 = use
                                     // Pascal-side RelayDefaultWaitTimeoutMs (5 min)
}
```

`TRelayProvider.Chat()` blocks on `Done.WaitFor` for this long before
giving up and returning a `StatusCode := -1` error that walks the
fallback chain. Operators with a flaky worker that takes ages to come
back online set this higher (30 minutes, an hour); operators wanting
fast fallback to the next provider set it lower. `0` (the default)
keeps PasClaw on the built-in default so future bumps to the
constant flow through without operator action.

## How `/v1/responses` differs

[`docs/gateway.md`](./gateway.md) covers `/v1/responses` — that's the
**outbound-facing** stateful chat endpoint other apps call to use
PasClaw as an LLM. The relay is the **inbound-facing** worker queue
PasClaw uses to source inference. Different directions, different
purposes. They can coexist on the same gateway — an external chat app
calls `/v1/responses`, PasClaw orchestrates the agent loop, individual
inference calls go out to relay workers. The chat-app caller never
sees the relay layer.

## Worker reference implementations

### Browser + WebLLM (minimal example)

The WHATWG `EventSource` constructor has **no headers option** in real browsers, so a Pascal-style "set X-Relay-Worker-Id as a header" approach can't work from JS. PasClaw's gateway therefore accepts `?token=`, `?worker_id=`, and `?caps=` as query-string fallbacks for the equivalent headers on `/v1/relay/poll`. Use them from the browser; the `Authorization` header continues to work for the response `POST` (where `fetch` honours `headers`).

```html
<!DOCTYPE html>
<script type="module">
  import { CreateMLCEngine } from "https://esm.run/@mlc-ai/web-llm";

  const TOKEN = "...";
  const URL   = "http://localhost:8888";
  const MODEL = "Llama-3.2-3B-Instruct-q4f16_1-MLC";
  const WID   = `tab-${crypto.randomUUID()}`;

  const engine = await CreateMLCEngine(MODEL);

  // Query-string auth so the browser can attach worker identity +
  // capabilities + token without custom headers (which native
  // EventSource silently drops).
  const q = new URLSearchParams({ token: TOKEN, worker_id: WID, caps: MODEL });
  const events = new EventSource(`${URL}/v1/relay/poll?${q}`);

  events.onmessage = async (ev) => {
    const req = JSON.parse(ev.data);
    const completion = await engine.chat.completions.create({
      messages:    req.messages,
      temperature: parseFloat(req.options?.temperature ?? "0"),
      max_tokens:  req.options?.max_tokens ?? 512,
    });

    await fetch(`${URL}/v1/relay/respond/${req.id}`, {
      method:  "POST",
      headers: {
        "Authorization": `Bearer ${TOKEN}`,
        "Content-Type":  "application/json",
      },
      body: JSON.stringify({
        content:       completion.choices[0].message.content,
        finish_reason: completion.choices[0].finish_reason,
        usage:         completion.usage,
        // Forward tool_calls if WebLLM produced them. PasClaw's
        // RunToolLoop dispatches verbatim. Omit (or null) for
        // text-only models.
        tool_calls:    completion.choices[0].message.tool_calls,
      }),
    });
  };
</script>
```

### Python + llama.cpp (sketch)

```python
import requests, sseclient, llama_cpp

llm = llama_cpp.Llama(model_path="...", n_gpu_layers=-1)

resp = requests.get(
    "http://localhost:8888/v1/relay/poll",
    headers={
        "Authorization":         f"Bearer {TOKEN}",
        "X-Relay-Worker-Id":     "py-worker-1",
        "X-Relay-Capabilities":  "llama-3.2-3b-instruct",
        "Accept":                "text/event-stream",
    },
    stream=True,
)
client = sseclient.SSEClient(resp)

for ev in client.events():
    req = json.loads(ev.data)
    out = llm.create_chat_completion(
        messages=req["messages"],
        max_tokens=req["options"]["max_tokens"],
    )
    requests.post(
        f"http://localhost:8888/v1/relay/respond/{req['id']}",
        headers={"Authorization": f"Bearer {TOKEN}"},
        json={
            "content":       out["choices"][0]["message"]["content"],
            "finish_reason": out["choices"][0]["finish_reason"],
            "usage":         out["usage"],
        },
    )
```

## Catalog row

```jsonc
// in config.json
{
  "providers": [
    {
      "name":     "relay",
      "kind":     "relay",
      "api_base": "",
      "api_key":  "",
      "model":    "llama-3.2-3b-instruct"   // pin a default; workers advertise this
    }
  ],
  "default_provider": "relay"
}
```

`api_base` and `api_key` are unused (the queue is in-process, workers
auth with the gateway token). `model` is what `Provider.Chat()` will
match against worker capabilities when the agent loop doesn't override.

## Status

| Piece | State |
|---|---|
| Queue (`PasClaw.Gateway.RelayQueue`) | V1 landed |
| Provider (`PasClaw.Providers.Relay`) | V1 landed |
| Catalog row (`relay` kind, `pfRelay` family) | V1 landed |
| Factory wiring | V1 landed |
| `GET /v1/relay/poll` SSE endpoint | V1 landed |
| `POST /v1/relay/respond/:id` | V1 landed |
| `GET /v1/relay/status` | V1 landed |
| Structured tool calls from workers | V1 landed (PR #318 review fix) |
| Sticky routing (KV-cache locality) | V1.1 landed |
| Reference HTML worker | Follow-up PR |
| Streaming back to caller | V2 |
| Persistent queue | V2 if anyone runs PasClaw as a long-lived multi-tenant service |
