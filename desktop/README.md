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
- **A sibling checkout of the styles repo.** The retro window manager and the
  27 `.style` files come from
  [Cross-Platform-Retro-OS-Styles](https://github.com/FMXExpress/Cross-Platform-Retro-OS-Styles).
  Nothing from it is vendored here — we build that project too, so it is
  referenced, not copied.

Expected layout:

```
<parent>/
  PasClaw/
    desktop/PasclawDesktop.dproj      <- this project
    src/pkg/component/PasClaw.Client.Api.pas
  Cross-Platform-Retro-OS-Styles/
    Source/FMX.RetroWindows.pas
    Source/FMX.RetroSkins.pas
    FMXStyles/Retro/*.style
```

Clone them side by side:

```sh
git clone https://github.com/FMXExpress/PasClaw.git
git clone https://github.com/FMXExpress/Cross-Platform-Retro-OS-Styles.git
```

If your checkout lives elsewhere, fix two things: the project's unit search
path (`..\..\Cross-Platform-Retro-OS-Styles\Source`) in the `.dproj`, and the
style directory at runtime — set `RETRO_STYLES_DIR` to the `FMXStyles/Retro`
folder. Without the styles the app still runs; it just has no looks to switch
between, and Display Properties says so.

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
  turn leaves a runnable app behind, the window opens it.
- **App window** — the app in a `TWebBrowser`. An app that declares network
  access asks before it opens.
- **Display Properties** — every `.style` in the styles directory, plus that
  style's color schemes (skins). Switching reskins the whole shell, chrome
  included, at runtime.

**F11** toggles fullscreen — the shell mode.

## Design notes

- **The window manager is not ours.** `TRetroDesktop` / `TRetroWindow` /
  `TRetroTaskbar` / `TRetroDesktopIcon` come from the styles repo and already
  handle dragging, 8-direction resize, activation, minimize-to-taskbar (or to
  desktop icons on Win 3.1 / CDE), windowshade collapse on the Apple styles,
  and taskbar docking per style. This unit builds a client on top of them.
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

## Tests

The UI needs Delphi and is not covered by `make test`. The half that isn't UI
— the client library both native clients share — is:

```sh
pasclaw gateway --port 8088 &
PASCLAW_TEST_GATEWAY=http://127.0.0.1:8088 make test-client-api
```

It skips itself (green) when `PASCLAW_TEST_GATEWAY` is unset.
