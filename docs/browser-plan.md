# PasClaw Browser: a plan

An FMX desktop browser — `TWebBrowser` on WebView2 — with a PasClaw chat
panel beside it, where the agent can **read the page you are looking at and
change it**. Lives in `browser/`, beside `desktop/` and `studio/`, and follows
their conventions.

The first draft of this plan put PasClaw in a second process and reached the
browser over MCP-over-HTTP. That was wrong: `TPasClawAgent` (unit
`PasClaw.Agent`) embeds the whole agent in-process — provider, tool loop,
custom tools, hooks — and every piece the browser needs is a method on it.
The revision below is the in-process design. The MCP path survives only as
the answer to "what if you also want the web UI to see this session", at the
end.

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

## The agent lives in the exe

One process. `TPasClawAgent` is created on the form; the six browser tools
are `TPasClawTool` subclasses registered with `Agent.RegisterTool`; the chat
panel calls `Agent.ChatHistory`. No gateway, no MCP server, no port, no
registration step, nothing to start before the app.

```
┌──────────────────── PasclawBrowser.exe (FMX, Delphi) ─────────────────────┐
│                                                                            │
│  ┌── TWebBrowser (WebView2) ───────┐   ┌── Chat panel ─────────────────┐  │
│  │  address bar, back/forward      │   │  per-tab TMessage[] history   │  │
│  │  EvaluateJavaScript(js, cb)     │   │  Agent.ChatHistory on a task   │  │
│  │  OnDidFinishLoad                │   │  OnText → append as it streams │  │
│  └────────────▲────────────────────┘   └──────────────┬────────────────┘  │
│               │ UI thread only                        │ background thread │
│               │                                       ▼                   │
│  ┌── RunOnBrowser(js, timeout) ─────┐   ┌── TPasClawAgent ─────────────┐  │
│  │  Queue to UI → eval → wait event │◄──│  tools: browser_page         │  │
│  └──────────────────────────────────┘   │         browser_find         │  │
│                                         │         browser_navigate     │  │
│  hooks:                                 │         browser_click        │  │
│    BeforeTurn      → inject page context│         browser_fill         │  │
│    BeforeToolCall  → confirm mutations  │         browser_eval         │  │
│    AfterToolResult → steer after nav    │  system prompt: memory,      │  │
│                                         │  facts, AGENTS.md — the same  │  │
│                                         │  one the CLI builds           │  │
│                                         └──────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────┘
```

Every arrow above is a method call. What the component provides, verified
against `PasClaw.Agent` and `docs/embedding.md`:

| need | component API |
|---|---|
| custom tools | `RegisterTool(TPasClawTool)` — override `Name`, `Description`, `Schema`, `Run`, `Category` |
| read-only vs mutating | `Category` returns `tcReadOnly` or `tcMutating`; default is mutating |
| inject page context each turn | `TPasClawHook.BeforeTurn(var ContinueTurn, var Messages)` — mutate `Messages` |
| confirm before a mutation | `BeforeToolCall(const ToolCall, var Cancel, var SyntheticResult)` — the doc calls this "the approval-gate pattern" by name |
| tell the model the page changed | `AfterToolResult(…, var SteeringMessage)` — a system note before the next model round |
| streaming | `OnText` fires per chunk, on the calling thread |
| provider without a config file | `SetProvider(kind, key[, model[, base]])`; or leave `LoadConfigFromDisk` on and use `~/.pasclaw/config.json` |
| the real system prompt | `BuildSystemPrompt(FConfig, …)` — memory, distilled facts, `AGENTS.md`, exactly what the CLI injects |

That last row is why a shared `PASCLAW_HOME` works: the browser's agent
reads the same `MEMORY.md` and `facts.db` as `pasclaw agent` and the web UI.

## The tools

Six, deliberately few.

| tool | category | does |
|---|---|---|
| `browser_page` | read-only | URL, title, selection, and the page as text or as a structural outline (`mode: text \| outline`). Capped at 24 KB with `offset` for the rest — a long page must not ride in the transcript forever |
| `browser_find` | read-only | CSS selector or text → matching elements, each with a short stable handle (`h3`, `h7`) so later tools name a target without re-sending the DOM |
| `browser_navigate` | mutating | go to a URL, back, forward, reload; resolves on `OnDidFinishLoad` |
| `browser_click` | mutating | click a handle from `browser_find` |
| `browser_fill` | mutating | set an input's value and dispatch `input` / `change`, so frameworks notice |
| `browser_eval` | mutating | arbitrary JavaScript, result stringified. The escape hatch; the five above are safer specialisations of it |

`browser_eval` is the honest name for "modify the page". It runs with the
user's logged-in cookies on whatever site is open, so it is `tcMutating`,
plan mode refuses it, and a `BeforeToolCall` hook puts a confirm dialog in
front of every mutating tool by default.

**Page context without a tool call.** A `BeforeTurn` hook appends one
message — `[page: <title> — <url>]` plus the selection if any — so "what is
this page about?" costs no round-trip. This replaces the first draft's
"prefix the user's text" hack: the hook keeps the user's message clean in
the transcript and the context arrives as its own system-ish line.

## The hard part: threads

The component runs the tool loop **on the calling thread**, so the chat panel
must call `ChatHistory` on a background `TTask` or the UI freezes for the
whole turn. That puts every tool's `Run` on that background thread — and
`EvaluateJavaScript` is UI-thread-only, with its result arriving on a
callback. So each browser tool is:

```
background (tool loop)             UI thread
──────────────────────             ─────────
build request
TThread.Queue ──────────────►      EvaluateJavaScript(js,
wait on TEvent (timeout 10 s)        procedure(const R: string)
                                       begin Result := R; Event.SetEvent end)
◄─────────────────────────────     callback fires
return R, or "timed out" error
```

One reusable `RunOnBrowser(js, timeout): string` behind all six tools. The
timeout is not optional: a page that never finishes a script, or a WebView2
still initialising, would otherwise hang the turn.

`OnText` also fires on the background thread, so the panel `Queue`s each
chunk to the UI. Same discipline as the desktop's streaming memo.

Two gotchas `desktop/uDesktopMain.pas` already documents and this inherits:
`WindowsEngine := EdgeIfAvailable` **before** `Parent` is assigned (line
5718 — the other order silently gets the IE engine), and WebView2 loads
string content into an opaque origin, so `LoadFromStrings` tests do not
exercise a real navigation's security context.

## History is the host's job

`Chat(prompt)` is one user message; `ChatHistory(history, …)` takes the
whole transcript and returns the reply. The component keeps nothing between
calls and writes nothing to `workspace/sessions/`. So the browser app owns a
`TMessage[]` per tab, appends the user turn and the reply each time, and
passes the array in. `desktop/` does exactly this by hand already.

If history should survive a restart, the app serialises that array itself —
per tab, under `PASCLAW_HOME/workspace/browser/`. Phase 3.

## What is reused

| from | what |
|---|---|
| `src/pkg/agent/PasClaw.Agent.pas` | the agent — loop, prompt, tools, hooks, provider |
| `src/pkg/tools/PasClaw.Tools.Obj.pas` | `TPasClawTool` base |
| `src/pkg/agent/PasClaw.Agent.Hooks.pas` | `TPasClawHook` base |
| `samples/component-console/SampleConfigured.dpr` | the embed pattern: create, `SetProvider`, `RegisterTool`, `OnText` |
| `desktop/uDesktopMain.pas` | `JsonStr`, the WebView2 engine-ordering fix, `EnsureLiveBrowsers`, FMX style loading, the per-project history array |
| `studio/PasclawAccessibility*.pas` | screen-reader support, drop-in |
| `desktop/FMXStyles/` | the theme |
| `scripts/check-pascal-shape.py` | the structural-lint convention |

## Phases

| phase | deliverable | size |
|---|---|---|
| **0 — skeleton** | `browser/PasclawBrowser.dpr`: WebView2 pane with address bar, chat pane, splitter. `TPasClawAgent` created with `LoadConfigFromDisk = True` so the user's existing `config.json` provider works. `ChatHistory` on a `TTask`, `OnText` queued to the memo. Browse and chat side by side; the agent knows nothing about the page yet. | small |
| **1 — page context** | `RunOnBrowser` bridge; a `BeforeTurn` hook adding `[page: …]`. "What does this page say?" works. The bridge is proven with nothing else in the way. | small |
| **2 — tools** | Six `TPasClawTool` subclasses on the bridge, registered at startup. "Change the heading to X" works. | medium |
| **3 — safety and polish** | `BeforeToolCall` confirm gate on mutating tools, per-site remember; `UserDataFolder` under `PASCLAW_HOME` so logins persist; `AfterToolResult` steering after `browser_navigate`; per-tab history persistence; structural lint for engine-before-Parent. | medium |

One PR each. Phase 1 is the first useful build.

## Tests

- **`RunOnBrowser`** against a fake `TWebBrowser` behind an interface:
  result marshalled, timeout fires, late callback ignored.
- **The six tools** against that same fake, with canned JS results: argument
  validation, the 24 KB cap and `offset`, handle resolution in
  `browser_find` → `browser_click`. Pure Pascal, on FPC, in `make test`.
- **The hooks**: `BeforeTurn` appends exactly one context message and never
  duplicates it; `BeforeToolCall` cancels a mutating call and returns the
  synthetic "declined" result when the gate says no.
- **The outline extractor** (the JS behind `browser_page mode=outline`) as a
  fixture: HTML in → expected JSON out, through headless Chromium in a
  Python test the way `docs/screenshots/capture.py` already does.
- **Structural lint**: `WindowsEngine` assigned before `Parent` in any unit
  under `browser/`.

The FMX form is Delphi/Windows only and cannot build in CI — the same
position as `desktop/` and `studio/`. The list above is what makes that
tolerable: everything that can be wrong in an interesting way sits below the
form and is reachable without it.

## Known limits, stated now

- **Top frame only.** `EvaluateJavaScript` runs in the main document.
  Cross-origin iframes are invisible and untouchable. A page that is mostly
  an iframe will look empty; the tool result should say so.
- **Delphi 11+.** The callback form of `EvaluateJavaScript` is what makes
  reading a result possible at all. Pin it in the `.dproj` and README.
- **WebView2 runtime.** Evergreen on Windows 11; on 10 it may need the
  redistributable, which the tree's `webview2-redist` history covers.
- **Windows only** for now. `TWebBrowser` on macOS is WebKit and the bridge
  differs; out of scope.
- **The web UI and TUI cannot see the browser's session.** In-process means
  the transcript lives in the exe. Memory and facts are still shared through
  the workspace, which is the part that matters. If someone later wants the
  session itself visible elsewhere, that is the one case for embedding
  `TPasClawServer` beside the agent — not for the first three phases.

## Open questions

1. **Confirm-before-mutate default.** On, with a per-site override, is the
   safe default for a tool that can submit forms on a logged-in bank. Lean
   on.
2. **Own `PASCLAW_HOME` or the user's?** The user's, so the agent brings its
   memory into the browser and takes what it learns back out. History is
   per-tab regardless.
3. **Parallel read-only tools.** The component defaults `Cfg.Parallel` to
   `False`. `browser_page` + `browser_find` in one turn would benefit, but
   both funnel through one UI thread anyway, so the gain is small. Leave
   off until measured.

## Build order

0 → 1 → 2 → 3, one PR each. Phase 1 before 2 because the bridge is the
risky piece and a single hook proves it end to end.
