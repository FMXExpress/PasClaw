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

## Packaging (outline)

1. Build the container image (the existing `docker/Dockerfile` produces the
   x86-64 binary + bundled OpenSSL + libsqlite3). Build it with `C2W=1` so the
   proxy support is compiled in, and set its default command to `agent` (or
   `tui`). Trim/disable the heavy features for an emulated guest: vector/ONNX
   memory, MCP, cron, channels.
2. Convert the image to a wasm bundle with the `c2w` CLI, selecting the
   **fetch** networking assets (`examples/networking/fetch/`), which bundle
   `c2w-net-proxy`. (Check current c2w docs for exact flags.)
3. Serve the static bundle from any HTTP server that supports byte-range
   requests. Opening it boots Linux in the tab and renders `pasclaw agent` /
   `tui` in an xterm.

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

The `PASCLAW_C2W` code paths compile cleanly under FPC 3.2.2 in both modes
(default and `-dPASCLAW_C2W`). The end-to-end browser run (c2w packaging +
`c2w-net-proxy` + a live Anthropic call) has **not** been exercised in CI and
should be validated manually before relying on it.
