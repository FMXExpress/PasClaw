# PasClaw Browser (desktop)

Tabs of WebView2, each with a PasClaw chat beside it that can **read the
page you are looking at and change it**. The agent is embedded in the exe —
one `TPasClawAgent` for the app, pointed at whichever tab is talking —
against your own `PASCLAW_HOME`. No gateway to start, no port to open.

Not to be confused with `browser/`, which is the opposite thing: PasClaw's
CLI running *inside* a browser tab on a WebAssembly Linux emulator.

```
┌──────────────────────── PasclawBrowser.exe ─────────────────────────┐
│ [◀][▶][↻][+ Tab][✕ Tab]                                              │
│ ┌ Tab: Example Page ─────────────────────────┬─ PasClaw ──────────┐ │
│ │ https://example.com/docs                [Go] │ ☑ confirm changes  │ │
│ │                                              │                    │ │
│ │   (WebView2)                                 │  You: what's this  │ │
│ │                                              │  PasClaw: It's …   │ │
│ │                                              │                    │ │
│ │                                              │ [ask or instruct…] │ │
│ └──────────────────────────────────────────────┴────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

## What the agent can do

| tool | | |
|---|---|---|
| `browser_page` | read-only | the URL, title, selection, and the page as text or as an outline of headings / links / fields, each with a handle |
| `browser_find` | read-only | CSS selector or visible text → elements with handles |
| `browser_navigate` | mutating | a URL, or `back` / `forward` / `reload`; waits for the load |
| `browser_click` | mutating | click an element by handle |
| `browser_fill` | mutating | set a field's value, firing `input`/`change` so React and friends notice |
| `browser_eval` | mutating | arbitrary JavaScript — the escape hatch |

Every message you send is stamped with `[page: <title> — <url>]` and the
current selection, so "what is this about?" costs no tool call.

## Each tab is its own session

A tab owns its conversation. The history handed to the agent for a turn is
that tab's history and nothing else, and the page context on each message
is that tab's page. Sessions persist as JSON under
`PASCLAW_HOME/workspace/browser/<tab-id>.json`, so a tab's conversation
survives closing it — though v1 does not reopen old tabs automatically;
that is the next thing to add.

What is shared is the engine. `TPasClawAgent` is one-per-process (its
constructor raises on a second live instance, because MCP and skills keep
module-level state), so the app has one agent with the six tools and two
hooks registered once against a *switching bridge*. Turns run one at a
time on a single worker thread; before each turn the worker points the
switching bridge at the tab that sent it, and after the turn clears it. A
tab that sends while another tab's turn is running is queued and its
status line says so. The "always allow on this site" answers are shared
across tabs for the same host, which is what you would expect.

Memory, distilled facts and `AGENTS.md` are shared with the CLI and web UI,
because the agent is built on the same config: what it learns in the browser
is available everywhere, and vice versa.

## Confirm before changing the page

Four of the six tools change the page, and `browser_eval` can do anything
the page's own scripts can, with your cookies. So by default every mutating
call asks first: **Yes** for this once, **Yes to All** for this site until
you close the app, **No** to decline — which the model is told, so it asks
what you'd like instead rather than retrying. The checkbox at the top of
the chat turns the gate off for a tab.

Plan mode refuses the mutating tools outright, as it does for any
`tcMutating` tool.

## Building

**Delphi 11 or later, Windows.** The form uses the `EvaluateJavaScript`
overload that returns the script's value through a callback, which is what
makes reading a page possible at all; on 10.x there is no way to get a
result back.

Open `PasclawBrowser.dproj` and build Win64 or Win32. The `.dproj` is
derived from `desktop/PasclawDesktop.dproj` with the unit search path
covering the whole of `src/`. On first build Delphi will create
`PasclawBrowser.res` — none is committed.

WebView2's evergreen runtime is present on Windows 11 and most updated 10;
the desktop's notes on the redistributable apply here unchanged. The
WebView2 profile is placed at `PASCLAW_HOME/workspace/browser/webview2` via
`WEBVIEW2_USER_DATA_FOLDER`, so logins persist with the workspace.

## What is tested, and how

Nothing in CI can compile the FMX form. So the design puts everything that
can be wrong in an interesting way *below* the form, in units that compile
under FPC and run in `make test`:

```
make test-browser-tools    # src/tests/browser_tools_tests.pas
make lint-browser-shape    # scripts/check-browser-shape.py browser-desktop/*.pas
```

The test drives all six tools, both hooks and the session against a fake
bridge that recognises the script it is handed and records it — so the
assertions are about what the tool asked the page to *do*, not about
internals. Covered: argument validation, the 24 KB cap and `offset`,
handle validation (a selector-breaking handle never reaches JavaScript),
the React-aware fill, the context stamp being applied once and only once,
the confirm gate denying / allowing once / remembering a host / refusing
when no asker is wired, a UTF-8 round-trip through a real temp file, and
the switching bridge: no current tab fails with a named error and reaches
no tab, a tool built once follows whichever tab is current, and after
`Shutdown` every call fails at once and the bridge cannot be re-pointed.

Each guard was negative-tested — the cap removed, the handle check removed,
the gate opened — and each failed on the assertion that owns it. Those
negative runs use a forced clean unit build: a first attempt reused a stale
`.ppu` and "failed" on the wrong assertion, which is the exact thing a
negative test exists to catch.

The lint enforces the one rule the compiler cannot: `WindowsEngine` before
`Parent`. Assigning `Parent` creates the native handle and the engine is
chosen then; the other order compiles, runs, and silently uses the IE-era
engine. `desktop/` found that out from a user; this project fails the build
on it.

## Limits, stated

- **One turn at a time across tabs.** The agent is a process singleton, so
  a second tab's message waits for the first tab's turn to finish. Closing
  the window mid-turn stops new page calls immediately and closes once the
  turn returns; a second close offers to quit at once, saving sessions
  first.
- **Top frame only.** Cross-origin iframes are invisible and untouchable;
  a page that is mostly an embedded editor will look empty, and
  `browser_page` says so.
- **Windows only.** `TWebBrowser` on macOS is WebKit and the bridge differs.
- **Compiled blind.** The form has never been through a Delphi compiler in
  this repository. The tested layer is exact; the form may need a type or
  overload spelled differently for your Delphi version. The
  `EvaluateJavaScript` call in `TFmxBridge.Eval` is the line most likely
  to need it.
- **The web UI cannot see browser sessions.** The transcript lives in the
  exe. Memory is shared; the conversation is not.
