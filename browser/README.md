# PasClaw in the browser (container2wasm)

Run PasClaw's CLI/TUI agent **in a browser tab** — no install for the end
user, and no backend/relay server. The native `pasclaw` binary runs inside a
WebAssembly Linux emulator ([container2wasm](https://github.com/container2wasm/container2wasm)),
and its HTTPS calls to the LLM go out through the **browser's own `fetch()`**
via `c2w-net-proxy` (this is what the `PASCLAW_C2W` build flag wires up — see
[`../docs/c2w.md`](../docs/c2w.md)).

## ⚠️ "No server" — what that actually means

Two different things get called "server":

- **No backend / no relay you run** — ✅ true. Networking is the browser's
  `fetch()`; there is nothing to host besides static files.
- **A process serving the static files** — ❌ still required. You cannot
  double-click an `.html` from `file://`. The emulator needs
  `SharedArrayBuffer`, which browsers only enable under *cross-origin
  isolation* (`Cross-Origin-Opener-Policy: same-origin` +
  `Cross-Origin-Embedder-Policy: require-corp`). Those headers can't exist on
  `file://`, and the service-worker shim that injects them doesn't run there
  either. This is a browser security rule, not a PasClaw limitation.

So the closest thing to "just open it":

- **Publish once to a free static host** (GitHub Pages / Netlify / Cloudflare
  Pages). Then anyone opens the URL — nothing installed, no backend. This is
  the real "serverless" deployment.
- **Locally**, run one command (`serve.py`) and open `http://localhost`.

`coi-serviceworker.js` is included so even a header-less host (GitHub Pages)
becomes cross-origin isolated after the first load.

## Build the bundle

Run on a real machine with `docker`, **node + npm** (the upstream harness is
webpack-bundled), `git`, `curl`, `gzip` — and **not** behind a TLS-intercepting
proxy (c2w compiles its emulator from source and fetches a lot over HTTPS).
The `c2w` CLI is **auto-downloaded** into `browser/.bin/` if it isn't already
on your `PATH` (override with `C2W=/path/to/c2w`):

```sh
./browser/build.sh
```

It mirrors container2wasm's "on browser" pipeline, pointed at the pasclaw
image: (1) `docker build --build-arg C2W=1`, (2) `c2w --to-js` → emscripten
`*.wasm`/`*.js`, (3) clone the pinned container2wasm example, (4) `npx webpack`
its `htdocs` and copy `index.html` + `dist/` + `vendor/xterm.css` in, (5)
`c2w-net-proxy.wasm.gzip` next to the page, (6) drop in the COOP/COEP service
worker. Output lands in `browser/site/` (git-ignored — it's large).

The result is a plain **static folder**: `index.html`, the webpack `dist/`
bundle, `vendor/xterm.css`, the c2w `.wasm`, and `c2w-net-proxy.wasm.gzip`.
Manually deploy it as-is. It's heavy/slow the first time and the `.wasm` is
~100 MB+.

## Try it locally

```sh
python3 browser/serve.py            # serves browser/site on http://localhost:8080
```

Open the printed URL. A terminal boots in the tab running the container's
default command. Set that command to `agent` or `tui` (override `CMD` when you
build the image) so the user lands straight in the agent.

## Deploy

Upload the **contents** of `browser/site/` to any static host. On hosts where
you control headers, set `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp` and you can drop
`coi-serviceworker.js`. On GitHub Pages (no header control), keep the service
worker.

## What the user experiences, and the limits

- It's an **xterm terminal** running `pasclaw`, not a chat UI. A polished
  front-end would be separate work. The gateway `webui` doesn't apply here
  (it'd be a server inside the VM with no path out to the tab).
- **Anthropic only.** `fetch()` is subject to CORS; Anthropic allows it (the
  `PASCLAW_C2W` build sends `anthropic-dangerous-direct-browser-access`).
  OpenAI generally doesn't; Gemini may.
- **Bring-your-own API key**, entered in the page — anything baked into a
  public bundle is extractable.
- **Slow.** c2w's x86-64 backend is an interpreter (Bochs).
- Token **streaming** may buffer through the fetch proxy; the final answer
  still arrives.

## Files here

| File | Purpose |
|------|---------|
| `build.sh` | One-shot: image (C2W=1) → `c2w --to-js` → webpack harness → static `site/`. |
| `serve.py` | Local static server with the required COOP/COEP headers. |
| `coi-serviceworker.js` | Adds COOP/COEP on header-less hosts (e.g. GitHub Pages). |
| `site/` | Generated, manually-deployable bundle (git-ignored — large). |

> Status: `build.sh` follows container2wasm's documented emscripten "on
> browser" pipeline (pinned to `v0.8.4`), pointed at the pasclaw image. The
> PasClaw side (image builds with `C2W=1`, proxy routing) is verified; the
> `c2w --to-js` + webpack conversion was **not** executed in this repo's CI
> (it needs container-registry access and no TLS interception). Run it on a
> suitable machine and pin/verify against the `c2w` version you use.
