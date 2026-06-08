# Running PasClaw in the browser via container2wasm (c2w)

PasClaw is a native binary that wants a real OS (sockets, threads, subprocess,
SQLite, OpenSSL). It cannot be *compiled* to `wasm32` in any useful form. The
way to run it in a browser tab is to run the **unmodified native binary inside
a WebAssembly Linux emulator** — [container2wasm](https://github.com/container2wasm/container2wasm)
(`c2w`) — which boots a real Linux kernel compiled to wasm, so every OS feature
works as normal.

The one thing a browser can't do is open raw TCP sockets, so PasClaw's outbound
HTTPS to the LLM has to leave the sandbox somehow. c2w's serverless networking
mode, **`c2w-net-proxy`**, solves this entirely in the browser: it runs a
gVisor-based network stack in wasm, TLS-terminates the guest's HTTPS with its
own CA, and re-issues each request through the browser's **Fetch API**. No host
relay process is required.

## The `PASCLAW_C2W` build flag

`c2w-net-proxy` injects `HTTP_PROXY` / `HTTPS_PROXY` (e.g.
`http://192.168.127.253:80`) into the guest environment, but Indy's `TIdHTTP`
(PasClaw's HTTP client) does not read those variables on its own. The
`PASCLAW_C2W` conditional-compilation symbol wires PasClaw up for this
deployment and **nothing else** — it is off in every normal build:

- `src/pkg/providers/PasClaw.Providers.HTTP.pas` — routes `TIdHTTP` through the
  `HTTP_PROXY` / `HTTPS_PROXY` proxy (`ApplyBrowserProxy`, called from the
  single `NewClient` factory). Indy does not verify the server certificate by
  default, so the proxy's MITM cert is accepted with no extra CA wiring.
- `src/pkg/providers/PasClaw.Providers.Anthropic.pas` — adds the
  `anthropic-dangerous-direct-browser-access: true` request header, which
  Anthropic requires before it will return the CORS headers the in-browser
  Fetch proxy needs.

Build with the flag via the Makefile:

```sh
make C2W=1
```

Without `C2W=1` the wire behaviour is byte-identical to before (the proxy code
and the extra header are excluded by `{$IFDEF}`).

## Packaging

1. **Build the image with the C2W networking compiled in.** The existing
   `docker/Dockerfile` produces the x86-64 binary + bundled OpenSSL 1.0.2 +
   libsqlite3; pass `--build-arg C2W=1` to thread `-dPASCLAW_C2W` through:

   ```sh
   docker build -f docker/Dockerfile --build-arg C2W=1 -t pasclaw:c2w .
   ```

   Consider overriding the default `CMD` to `agent`/`tui`, and trimming the
   heavy features for an emulated guest (vector/ONNX memory, MCP, cron,
   channels) via config.

2. **Convert the image to wasm** with the `c2w` CLI
   (https://github.com/container2wasm/container2wasm):

   ```sh
   c2w --target-arch=amd64 pasclaw:c2w pasclaw.wasm
   ```

   `c2w` compiles its emulator (Bochs for x86-64) from source on first run, so
   it pulls several base images (`rust`, `gcc`, `golang`, `ubuntu`,
   `emscripten/emsdk`) and fetches build deps — it needs an environment with
   container-registry access and **no TLS interception** (a MITM proxy breaks
   the in-build HTTPS fetches). Server-side runs use `wasmtime pasclaw.wasm`.

3. **For the browser**, build with `--to-js` (emscripten output) and serve the
   resulting bundle from any HTTP server that supports byte-range requests.
   Drop in the released **`c2w-net-proxy.wasm`** — that's the serverless
   in-browser Fetch network stack PasClaw's `HTTP_PROXY`/`HTTPS_PROXY` routing
   (this change) targets. Opening the page boots Linux in the tab and renders
   `pasclaw agent` / `tui` in an xterm.

## Hard constraints (inherent to the browser, not to PasClaw)

- **Provider must allow CORS.** Anthropic does (with the header above). OpenAI
  generally does **not**, so OpenAI-compatible providers will not work in this
  mode. Gemini may. PasClaw being Claude-centric, Anthropic is the target.
- **Bring-your-own API key.** Anything baked into a publicly served bundle is
  extractable; each user supplies their own key.
- **Streaming.** A fetch-based proxy may buffer responses rather than stream
  tokens incrementally; the final completion still arrives. Verify SSE
  behaviour for your use.
- **Performance.** c2w's x86-64 backend is an interpreter (Bochs); expect slow
  boot and latency. A RISC-V guest or a server-side `wasmtime` runtime is
  faster if the browser path proves too slow.

## Status

Verified:

- Full `make` and `make C2W=1` both build a working `pasclaw` under FPC 3.2.2
  (zero new warnings from the gated code); `make test` passes.
- The proxy routing is behaviourally confirmed: a `C2W=1` binary with
  `HTTP_PROXY` set sends its request through the proxy (observed as an
  absolute-URI `GET` / `CONNECT` at a local listener); a default binary with
  the same env ignores it and goes direct.
- `docker build --build-arg C2W=1 -t pasclaw:c2w .` produces a working image
  and `docker run --rm pasclaw:c2w version` runs, with OpenSSL 1.0.2 bundled.

Not yet exercised end to end: the `c2w` image→wasm conversion and a live
in-browser Anthropic call through `c2w-net-proxy`. The conversion needs an
environment with registry access and no TLS-intercepting proxy (see step 2).
