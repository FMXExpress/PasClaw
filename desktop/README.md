# PasClaw Desktop (FireMonkey)

The native desktop client. Windows, icons, a taskbar and virtual desktops
instead of a chat log — see [`../docs/desktop-plan.md`](../docs/desktop-plan.md)
for what it is and why.

It is the twin of the browser client the gateway serves at `/desktop`. Both
drive the same HTTP surface through
[`PasClaw.Client.Api`](../src/pkg/component/PasClaw.Client.Api.pas), so a
project you start in one appears in the other, and both take their colors from
the same generated palette table so a given style looks the same in each. What
the native client adds is a real style engine and **F11**, which makes the app
fill the screen and *be* the desktop.

## Requirements

- **RAD Studio / Delphi** with FireMonkey (Win64, macOS or Linux). This is a
  Delphi project; FPC has no FMX, so it is not part of `make`.

That is the whole list. Clone PasClaw, open the `.dproj`, build, run — on a
**local build** the 27 styles are there and the picker is populated on first
launch. (Remote macOS / Linux targets need one extra step; see below.)
Everything the project needs is in this repository:

| What | Where | From |
|---|---|---|
| Shared client library | `../src/pkg/{component,json,utils}` | this repo |
| Retro window manager | [`retro/`](retro/) | vendored, MIT |
| 27 styles + 221 skins | [`FMXStyles/Retro/`](FMXStyles/Retro) | vendored, MIT |

Both vendored pieces come from
[Cross-Platform-Retro-OS-Styles](https://github.com/FMXExpress/Cross-Platform-Retro-OS-Styles);
[`retro/README.md`](retro/README.md) says how to refresh either.

### Using a different styles checkout

If you are working on the styles themselves, point the app at your copy and
it will use that instead of the vendored set:

```sh
export RETRO_STYLES_DIR=<styles-repo>/FMXStyles/Retro
```

Without the variable, `FindStyleDir` walks up from the exe looking for
`FMXStyles/Retro` — which finds the vendored copy — or
`Cross-Platform-Retro-OS-Styles/FMXStyles/Retro`, which finds a sibling
checkout.

### Remote targets (macOS / Linux over PAServer)

The walk-up finds the styles because the executable sits inside this
checkout. Build for a remote target and it does not: RAD Studio ships the
binary to the PAServer machine, which has no copy of the repository, so
`FindStyleDir` comes back empty and the picker says so. The styles are data
the project does not know it owns — nothing in `PasclawDesktop.dproj`
deploys them.

Either copy `FMXStyles/Retro` next to the deployed binary on that machine,
or set `RETRO_STYLES_DIR` there. Adding ~280 per-file deployment entries to
the `.dproj` would do it too, but hand-maintaining that list against an
upstream refresh is worse than the two-line workaround.

Only local Win64 has actually been run; the remote paths are reasoned from
how PAServer deployment works, not observed.

## Running

1. Start a gateway:

   ```sh
   pasclaw gateway              # http://127.0.0.1:8088
   ```

2. Open `desktop/PasclawDesktop.dproj` in RAD Studio and run it.

Environment:

| Variable | Meaning |
|---|---|
| `PASCLAW_GATEWAY` | Gateway base URL (default `http://127.0.0.1:8088`) |
| `PASCLAW_TOKEN` | Bearer token, when the gateway is token-gated |
| `RETRO_STYLES_DIR` | A styles directory to use instead of the vendored one |

## What's on screen

- **Menu** — the launcher, and the way into everything. Chat, Browser,
  Files, Library, Log, Projects, New Project, workspace switching and
  Display Properties, then every project in this workspace with its app
  listed underneath — click the app and it opens. That last part is how you
  reach the suite (Notes, Calendar, Mail and the rest): they are ordinary
  projects with ordinary apps, and the Menu saves you having to know that.
- **Projects window** — the Projects → Tasks → Jobs tree. Double-click a
  project to open its app (or its chat, if it hasn't built one yet);
  double-click a job to tail its log. Opened from the Menu; it was a fixed
  left dock with no chrome, sitting on top of the desktop icons that name
  the same projects.
- **Desktop icons** — one per project, same double-click behavior.
- **Taskbar** — open windows, plus `Desk >` to page virtual desktops and
  `WS >` to move to the next workspace (also Ctrl+Alt+Right). Switching
  either closes this desktop's windows, because they belong to the
  workspace, not to the client — the arrangement is saved against the
  desktop you are leaving and comes back when you return, geometry
  included.
- **Chat window** — per project, streaming, **rendering markdown** (headings,
  lists, code blocks, links) and with the model's tool use shown
  inline as it works: asking for an app should not look like a long silence
  followed by a sentence. It sends the builder-mode system prompt, so the
  agent's deliverable is an app rather than an essay. **Chat** on the Menu
  opens the project-less one instead — no builder prompt, just a
  conversation. When a
  turn leaves a runnable app behind, the window opens it. **Versions** opens
  the app as an earlier turn produced it, and can put that version back.
- **App window** — the app in a `TWebBrowser`. An app that declares network
  access asks before it opens.
- **Run window** — for `python` / `fpc` / `delphi` apps, which are programs
  rather than documents. It shows the exact command *before* asking, names
  which of the three places it will run in (this host, a container, a remote
  Docker host), and tails the output live.
- **Browser** — a question in, a page out, in **tabs**. Asking again with a
  page open *revises that page*; **New** opens an empty tab where a question
  starts a fresh one. **Search** is one pass and runs on the fast model.
  **Research** is the deep mode — it plans, reads several sources and
  synthesises — and opens a **chat window** rather than a progress box: it
  runs for minutes, narrates as it goes, and a follow-up there continues the
  report instead of starting over. **Make interactive** promotes the page
  you are looking at into an app you own.
- **File Manager** — the workspace directory, over `/v1/fs`. Read-only: that
  surface is already sandbox-checked and filters secret-bearing files, and a
  browse window is not the place to invent a delete button. Opening a file
  picks a viewer by what it is: `.html` renders in the Browser, a binary
  file opens a paged hex dump over `/v1/fs/peek` (a window of bytes at a
  time, so a huge file costs a window rather than a download), anything else
  opens as text.
- **Library** — what this workspace has accumulated: pages (what you looked
  up) and sessions (what you talked about). Double-click a page to read it
  in the Browser, a session to reopen that conversation with its history
  loaded.
- **Log** — the gateway's own log, replayed and then tailed live. Useful
  when the gateway is on another machine or was started by something that
  swallowed its output. It can only show what the gateway recorded: log
  level is a server-side filter applied before the buffer, so debug lines
  need `gateway.log_level` set to `"debug"` in `config.json` and a restart.
  No client-side switch can recover a line that was never emitted.
- **Display Properties** — every `.style` in the styles directory, plus that
  style's color schemes (skins). Switching reskins the whole shell, chrome
  included, at runtime.

The **window layout is saved per workspace** on the gateway, not locally, so
it survives a restart and follows you between the two clients: arrange a
desktop in the browser and this app opens with it.

**F11** toggles fullscreen — the shell mode.

## Design notes

- **The window manager is not ours.** `TRetroDesktop` / `TRetroWindow` /
  `TRetroTaskbar` / `TRetroDesktopIcon` come from the styles repo and already
  handle dragging, 8-direction resize, activation, minimize-to-taskbar (or to
  desktop icons on Win 3.1 / CDE), windowshade collapse on the Apple styles,
  and taskbar docking per style. This unit builds a client on top of them.
  They are copied into `retro/`, not edited: a `..\..\` path to a sibling
  checkout meant the project only opened on a machine that happened to have
  one, and failed with `F1026 File not found` everywhere else. The styles
  are copied for the same reason in its runtime form — the app compiled but
  came up with no looks to switch between, which is not a working desktop.
- **Dialogs are `TRetroWindow`s**, not `InputQuery` / `MessageDlg`. They wear
  the current style like everything else, and they are the same furniture the
  agent's own questions will use when the period-native output work lands
  (§7 of the plan).
- **The browser snapshot trick** is the demo's: `TWebBrowser` is a native
  control that paints above all FMX content, so an inactive window freezes
  its browser into a `TImage` and swaps the live control back on focus.
- **Windows report their own death** through `FreeNotification`, so closing
  one clears its dictionary entries rather than leaving a dangling pointer
  for the next Restore to walk.
- **Logic lives in the client library, not here.** Everything with a rule in
  it — what a run record means, how a directory listing is shaped, which
  page kinds exist — is in `PasClaw.Client.Api`, which FPC compiles and CI
  tests against a live gateway. This unit is widget wiring. That split is
  deliberate: no CI here has Delphi, so the less that lives in this file, the
  less is written blind.
- **The page request runs off the UI thread.** The gateway holds the request
  open for the whole turn — minutes, for research — and Indy blocks. Doing it
  inline would freeze the form, which would mean the progress dialog the mode
  exists to show could never repaint.

## Tests

The UI needs Delphi and is not covered by `make test`. Two things cover what
can be covered without it:

```sh
make test-client-api      # the shared library, against a gateway it starts
make lint-pascal-shape    # a method implemented but never declared
```

`test-client-api` starts its own gateway on a throwaway home and exercises
the routes this client depends on — projects, tasks, app state, files, pages
and promotion, desktop state, the run surface — then stops it again. It used
to skip itself unless you supplied a gateway, which meant the half that
matters most for the native client was never actually run.

`lint-pascal-shape` is a shape check, not a compiler. It catches a method
implemented but never declared — the mistake that survives review and dies
at the compiler — and it runs over the whole tree so it stays calibrated
against files that do compile. Two other checks were tried and removed for
crying wolf; the script says which and why.

**Neither is a substitute for building it.** The UI in this file has never
been through a compiler in this repo's CI. Expect a round of errors the first
time you open it in RAD Studio, and please push the fixes.
