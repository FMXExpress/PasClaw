# PasClaw Browser: a plan

An FMX desktop browser — `TWebBrowser` on WebView2 — with a PasClaw chat
panel beside it, where the agent can **read the page you are looking at and
change it**. Lives in `browser/`, beside `desktop/` and `studio/`, and follows
their conventions.

## The one design decision

There are two ways to give PasClaw "the context of the current browser
window", and the question raised both. They are not equally good.

**Sharing the WebView2 cache directory is not context.** The user-data folder
is a Chromium profile: SQLite cookie jars, a disk cache of compressed
responses, IndexedDB, GPU shader caches. None of it is the page as rendered,
and none of it is readable without reimplementing Chromium's storage formats.
Pointing that folder somewhere stable is still worth doing — it makes logins
survive restarts — but it contributes nothing to what the model knows.

**JavaScript is the whole answer.** `TWebBrowser.EvaluateJavaScript` runs
script in the page and, on Delphi 11+, hands the result back through a
callback. Everything the model needs is one expression away:

| the model wants | the script |
|---|---|
| what the page says | `document.body.innerText` |
| what the user selected | `window.getSelection().toString()` |
| the structure | walk headings, links, forms, inputs → compact JSON |
| to change it | any statement — set text, click, fill, inject CSS |

So the design is: the browser app exposes a small set of **tools** backed by
`EvaluateJavaScript`, and PasClaw calls them the way it calls any other tool.

## How PasClaw reaches into the browser

The gateway is one process; the browser is another. The link is **MCP, over
HTTP, in the reverse of the usual direction**: the browser app *hosts* an MCP
server, and PasClaw's gateway is the *client*.

Both halves already exist in the tree:

- `PasClaw.MCP.Bridge` picks `TMCPHttpClient` whenever a registered server's
  command is an `http://` URL (`Bridge.pas:494`). So the registration is one
  line: `pasclaw mcp add browser http://127.0.0.1:8089/mcp`.
- `PasClaw.MCP.Server` is transport-agnostic — `HandleRequest` takes one
  JSON-RPC line and returns one — and dispatches against a `TToolRegistry`.
  The gateway mounts it on `/mcp`; `pasclaw mcp stdio` wraps it in a stdin
  loop. The browser app is a third transport: Indy HTTP server → the same
  core → a registry holding only the browser tools.

That reuse matters more than it looks. The protocol handling — both MCP
protocol eras, tool listing, error shapes, the read-only/mutating split —
is code that already has tests. The browser app writes the tools and the
UI-thread bridge, nothing else.

The alternative, the existing `desktop-command` SSE channel
(`PublishDesktopCommand` → `/v1/desktop/events`), is fire-and-forget: right
for "tile the windows", wrong here, because the model needs the *result* of
reading a page before it can decide what to do. MCP is request/response.

```
┌──────────────────── PasclawBrowser.exe (FMX, Delphi) ─────────────────────┐
│                                                                            │
│  ┌── TWebBrowser (WebView2) ───────┐   ┌── Chat panel ─────────────────┐  │
│  │  address bar, back/forward      │   │  POST /v1/chat, streamed      │  │
│  │  EvaluateJavaScript(js, cb) ◄───┼───┼── every message prefixed with │  │
│  │  OnDidFinishLoad                │   │  {url, title, selection}      │  │
│  └─────────────────────────────────┘   └───────────────────────────────┘  │
│                    ▲                                                       │
│                    │ UI thread only                                        │
│  ┌── MCP server on :8089/mcp ──────┴──────────────────────────────────┐    │
│  │  PasClaw.MCP.Server core + TToolRegistry holding:                   │    │
│  │    browser_page      browser_navigate    browser_eval               │    │
│  │    browser_click     browser_fill        browser_find               │    │
│  │  each tool: Queue to UI thread → run JS → wait on event → result    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────▲──────────────────────────────┬──────────────┘
                               │ MCP tool calls               │ /v1/chat
                               │                              ▼
                     ┌──── pasclaw serve :8088 — gateway + MCP client ─────┐
```

## The tools

Six, deliberately few. Names are what the model sees after PasClaw
namespaces them by server.

| tool | category | does |
|---|---|---|
| `browser_page` | read-only | URL, title, selection, and the page as text or as a structural outline (`mode: text \| outline`). Output capped at PasClaw's 24 KB tool-result limit, with `offset` for the rest — a long page must not ride in the transcript forever |
| `browser_find` | read-only | CSS selector or text → matching elements with a short stable handle each (`h3`, `h7`) so later tools can name a target without re-sending the DOM |
| `browser_navigate` | mutating | go to a URL, back, forward, reload; waits for `OnDidFinishLoad` |
| `browser_click` | mutating | click a handle from `browser_find` |
| `browser_fill` | mutating | set an input's value and dispatch `input`/`change`, so frameworks notice |
| `browser_eval` | mutating | arbitrary JavaScript, result stringified. The escape hatch; everything above is a safer specialisation of it |

`browser_eval` is the honest name for "modify the page". It is powerful and
it is dangerous — it runs with the user's logged-in cookies on whatever site
is open — so it is `tcMutating`, plan mode refuses it, and phase 3 puts a
confirm toggle in front of it.

**Cheap context without a tool call.** The chat panel prefixes every message
with one line — `[page: <title> — <url>]` plus the selection if any — so
"what is this page about?" costs no round-trip. `/v1/chat` accepts only
`message` and the `X-PasClaw-Session` header, so the prefix is the mechanism;
the tools are for when a line is not enough.

## The hard part: threads

`EvaluateJavaScript` must run on the UI thread, and its result arrives later
on a callback. The MCP server answers requests on Indy worker threads. So
each browser tool is:

```
worker thread                       UI thread
─────────────                       ─────────
build request
TThread.Queue ──────────────────►   EvaluateJavaScript(js,
wait on TEvent (timeout 10 s)         procedure(const R: string)
                                        begin Result := R; Event.SetEvent end)
◄────────────────────────────────── callback fires
return R, or "timed out" error
```

One reusable `RunOnBrowser(js, timeout): string` behind all six tools.
The timeout is not optional: a page that never finishes a script, or a
WebView2 that is mid-initialisation, would otherwise hang the gateway's tool
loop.

Two gotchas `desktop/uDesktopMain.pas` already documents and this must
inherit: `WindowsEngine := EdgeIfAvailable` **before** `Parent` is assigned
(line 5718 — the other order silently gets the IE engine), and WebView2
loads string content into an opaque origin, so testing with `LoadFromStrings`
does not exercise the same security context as a real navigation.

## What is reused

| from | what |
|---|---|
| `desktop/uDesktopMain.pas` | the streaming `/v1/chat` client, `JsonStr`, the WebView2 engine-ordering fix, `EnsureLiveBrowsers`, the FMX style loading |
| `src/pkg/mcp/PasClaw.MCP.Server.pas` | the entire MCP protocol layer |
| `src/pkg/tools/PasClaw.Tools.Registry.pas` | tool registration, read-only/mutating split |
| `studio/PasclawAccessibility*.pas` | screen-reader support, drop-in |
| `desktop/FMXStyles/` | the theme |
| `scripts/check-pascal-shape.py` | the structural-lint convention, since no CI compiler can reach FMX |

## Phases

| phase | deliverable | size |
|---|---|---|
| **0 — skeleton** | `browser/PasclawBrowser.dpr`: WebView2 pane with address bar, chat pane streaming to a running gateway, splitter. Attaches to `http://127.0.0.1:8088` like the desktop does. No integration yet. | small |
| **1 — page context** | `RunOnBrowser` bridge; message prefix with URL/title/selection. "What does this page say?" works with zero new gateway code. | small |
| **2 — tools** | Embedded MCP server, six tools, `pasclaw mcp add browser …`. "Change the heading to X" works. The build unlocked by phase 1's bridge. | medium |
| **3 — safety and polish** | Confirm toggle for mutating tools; `UserDataFolder` under `PASCLAW_HOME` so logins persist; `OnDidFinishLoad` pushes `[page changed → url]` through `/v1/steer` when a turn is running; a structural lint for the engine-before-Parent order. | medium |

Each phase is one PR. Phase 1 is the first point at which the thing is
useful, and it needs no gateway change at all.

## Tests

- **`RunOnBrowser`** against a fake `TWebBrowser` behind an interface:
  result marshalled, timeout fires, callback after timeout is ignored.
- **The MCP server** against a registry of fake browser tools: tools list,
  read-only vs mutating exposure, a mutating call refused when the toggle is
  off. Pure Pascal, runs on FPC, joins `make test`.
- **The outline extractor** (the JS for `browser_page mode=outline`) as a
  fixture: an HTML file in → expected JSON out, run through headless
  Chromium in a Python test the way `docs/screenshots/capture.py` already
  does.
- **Structural lint**: `WindowsEngine` assigned before `Parent` in any unit
  under `browser/`, the way `check-pascal-shape.py` pins other shapes CI
  cannot compile.

The FMX form itself is Delphi/Windows only and cannot be built in CI — the
same position as `desktop/` and `studio/`. The tests above are what makes
that tolerable: the parts that can be wrong in interesting ways are the
bridge, the server and the extractor, and all three are reachable without
FMX.

## Known limits, stated now

- **Top frame only.** `EvaluateJavaScript` runs in the main document.
  Cross-origin iframes are invisible and untouchable. A page that is mostly
  an iframe — many embedded editors — will look empty. Say so in the tool
  result rather than returning nothing.
- **Delphi-version-specific API.** The callback form of
  `EvaluateJavaScript` exists from Delphi 11. On 10.x the result cannot be
  read back at all, which removes phase 1 entirely. Pin the minimum version
  in the `.dproj` and the README.
- **WebView2 runtime.** Evergreen on Windows 11; on 10 it may need the
  redistributable. The tree's `webview2-redist` history already covers how
  the desktop handles this.
- **Windows only**, for now. `TWebBrowser` on macOS is WebKit and the
  bridge shape differs; not in scope.

## Open questions

1. **Which Delphi?** Decides whether `EvaluateJavaScript` can return a
   value, which decides whether phase 1 is possible.
2. **Attach or embed the gateway?** The desktop attaches to a running
   `pasclaw serve`. Same here is simplest; embedding would let the app be
   one exe but drags every provider and config concern into it.
3. **Own workspace or shared?** A browser-specific `PASCLAW_HOME` keeps
   browsing sessions and memory separate; the shared one lets the agent use
   what it learned in the browser everywhere else. The desktop shares.
   Lean shared, with `X-PasClaw-Session` keyed per browser tab.
4. **Confirm-before-mutate default.** On, and the user turns it off per
   site? Or off, trusting plan mode? On is the safe default for a tool that
   can submit forms on a logged-in bank.

## Build order

0 → 1 → 2 → 3, one PR each. Phase 1 before 2 because the bridge is the
risky piece and the message prefix proves it end to end with nothing else in
the way.
