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

That is the whole list. Everything the project compiles is in this
repository: the three PasClaw units it shares with the CLI, and the retro
window manager vendored under [`retro/`](retro/) (MIT, from
[Cross-Platform-Retro-OS-Styles](https://github.com/FMXExpress/Cross-Platform-Retro-OS-Styles)
— see [`retro/README.md`](retro/README.md) for how to refresh it). Clone
PasClaw, open the `.dproj`, build.

### Styles are optional

The `.style` files are **not** vendored — 6.7 MB of runtime assets is not a
build dependency. Without them the desktop runs in FireMonkey's default look
and Display Properties says where to get them. To get the 27 retro looks,
clone the styles repo anywhere and point at it:

```sh
git clone https://github.com/FMXExpress/Cross-Platform-Retro-OS-Styles.git
export RETRO_STYLES_DIR=<that checkout>/FMXStyles/Retro
```

A sibling checkout is found without the variable: `FindStyleDir` walks up
from the exe looking for `FMXStyles/Retro` or
`Cross-Platform-Retro-OS-Styles/FMXStyles/Retro`.

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
| `RETRO_STYLES_DIR` | Path to `FMXStyles/Retro` if it isn't a sibling checkout |

## What's on screen

- **Dock (left)** — the Projects → Tasks → Jobs tree. Double-click a project
  to open its app (or its chat, if it hasn't built one yet); double-click a
  job to tail its log.
- **Desktop icons** — one per project, same double-click behavior.
- **Taskbar** — open windows, plus `WS >` to move to the next workspace
  (also Ctrl+Alt+Right). Switching workspaces closes this desktop's windows,
  because they belong to the workspace, not to the client.
- **Chat window** — per project, streaming. It sends the builder-mode system
  prompt, so the agent's deliverable is an app rather than an essay. When a
  turn leaves a runnable app behind, the window opens it. **Versions** opens
  the app as an earlier turn produced it, and can put that version back.
- **App window** — the app in a `TWebBrowser`. An app that declares network
  access asks before it opens.
- **Run window** — for `python` / `fpc` / `delphi` apps, which are programs
  rather than documents. It shows the exact command *before* asking, names
  which of the three places it will run in (this host, a container, a remote
  Docker host), and tails the output live.
- **Browser** — a question in, a page out. **Search** is one pass;
  **Research** is the three-phase deep mode, which runs for minutes and
  narrates what it is doing in a progress dialog. **Make interactive**
  promotes the page you are looking at into an app you own.
- **File Manager** — the workspace directory, over `/v1/fs`. Read-only: that
  surface is already sandbox-checked and filters secret-bearing files, and a
  browse window is not the place to invent a delete button.
- **Library** — pages, sessions, projects, the knowledgebase and how far undo
  reaches.
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
  one, and failed with `F1026 File not found` everywhere else.
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
