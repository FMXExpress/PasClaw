# PasClaw Desktop: plan

A new PasClaw client built on a **desktop paradigm** — windows, icons, a taskbar,
virtual desktops — instead of a chat-tab layout. Two frontends over one new backend
surface:

1. **A new web UI** (served by the gateway alongside the existing `webui.html`) that
   renders a retro desktop in the browser.
2. **A new Delphi FireMonkey app** built directly on the
   [Cross-Platform-Retro-OS-Styles](https://github.com/FMXExpress/Cross-Platform-Retro-OS-Styles)
   Desktop demo (`Demo/RetroDesktop`) — `TRetroDesktop` / `TRetroWindow` /
   `TRetroTaskbar` / `TRetroDesktopIcon` from `Source/FMX.RetroWindows.pas`, restyled
   at runtime by any of the 27 `.style` files + 221 skins. We build that repo too, so
   it is **referenced via a search path / sibling checkout, not vendored**.

The organizing idea: **PasClaw stops answering with walls of text and starts answering
with software.** The agent's deliverable for a request like *"handle my email spam"*
is a small app (HTML page, Python script+UI, or FPC/Delphi program) that is created
inside a Project, built by Jobs, and **runs as a window on the desktop**. Lovable for
your own machine, with Object Pascal as a first-class output.

---

## 0. Vision: what this is really for

Two goals sit above every feature below.

**Re-imagine the retro OSes as if they had shipped with AI.** Apple System,
Workbench, CDE, Win95 were great UIs *limited by the hardware of their day* —
every window was hand-filled by a human because software couldn't fill itself.
PasClaw Desktop asks: how would System 7 have felt if the machine could act? So
the styles are not nostalgia skins over a chat app; the **agent inhabits the
period's own idioms**:

- It speaks through **dialog boxes, wizards, and progress bars**, not markdown
  walls. A plan becomes a Win95-style wizard (Back / Next / Finish) whose steps
  are the Tasks it proposes; approving a step is clicking **Next**. Long answers
  arrive as a document window ("Notepad"/SimpleText), not a scrolling feed.
- **Working = the desktop working.** Jobs show as period furniture: the flying-
  pages copy dialog, an hourglass/watch cursor on the busy window, taskbar
  buttons that flash when a job needs input, `AUTOEXEC`-style boot text in the
  job log window.
- The assistant is a **desk accessory**, not a sidebar: Apple-menu item on Mac
  looks, a Program Manager group on Win31, a Workbench drawer on Amiga. Ask-the-
  agent is `Help → Ask…` — balloon help that actually answers.
- **Files are alive.** The File Manager window is the real workspace directory
  (the `/v1/fs` surface already exists); "arrange by" can mean *semantically*,
  and dropping a file on the agent icon means *do the obvious thing with this*.

Each look can carry its own small personality overlay (promptware per style —
terse and monochrome on System 6, exuberant on Synthwave), which costs nothing:
it's the same skills mechanism the agent already has.

**A personal agentic building platform + productivity suite.** The end state is
not "a chat client with windows" but an environment where **everyone builds
their own software around their own needs** — the spam filter, the invoice
reconciler, the reading tracker — and those apps accumulate. The desktop is the
inventory of what you've built (icons = your apps), Workspaces separate the
areas of your life (work / home / a client), and the suite grows by asking. The
productivity suite is therefore *seeded, not shipped*: a handful of starter
projects (notes, todo, file finder) that are themselves agent-built apps the
user can open, inspect, and remake — demonstrating that nothing on this desktop
is closed software.

---

## 1. The hierarchy: Workspaces → Projects → Tasks → Jobs

| Level | What it is | Where it lives | Desktop metaphor |
|---|---|---|---|
| **Workspace** | An isolated agent world: its own memory, sessions, skills, projects. PasClaw has exactly one today (`$PASCLAW_HOME/workspace`); we allow N. | `$PASCLAW_HOME/workspace` (default), `$PASCLAW_HOME/workspace2`, `workspace3`, … | A virtual desktop (Linux workspaces / macOS Spaces). Switching workspace switches the whole desktop. |
| **Project** | A thing being built — usually an app the agent is producing, plus its docs/data. | `<workspace>/projects/<name>/` | A node in the left-side tree; opening it opens its windows. |
| **Task** | A unit of intent inside a project ("add IMAP polling", "filter spam"). Has status, description, an ordered job list. | `<workspace>/projects/<name>/tasks/<id>/` | A row in the project's Task window / tree child node. |
| **Job** | One agent run executing (part of) a task — maps to a session + tool loop, or a background subagent. Has transcript, artifacts, exit status. | `<workspace>/projects/<name>/tasks/<id>/jobs/<id>/` | A progress row; double-click opens its live log window. |

### On-disk layout

```
$PASCLAW_HOME/
  config.json                    # gains "workspaces" + "active_workspace"
  workspace/                     # existing dir == "Workspace 1", untouched layout
    memory/  sessions/  skills/  cron/  ...
    projects/                    # NEW
      spam-filter/
        project.json             # manifest: name, kind, created, description
        app/                     # the app the agent builds (source + assets)
          app.json               # app manifest: kind, entry, run, build, permissions
        tasks/
          T0001/
            task.json            # title, status(todo|active|done|blocked), notes
            jobs/
              J0001/
                job.json         # status, session_id, started/ended, summary
                artifacts/       # files the job produced outside app/
  workspace2/                    # NEW: created on demand, identical shape
  workspace3/
```

Decisions baked in:

- **Back-compat first.** The existing `workspace/` dir *is* Workspace 1; nothing
  moves. New workspaces are sibling `workspaceN/` dirs (the user's naming), each a
  full copy of the shape (own `sessions/`, `memory/`, `skills/`, `projects/`).
- **Files are the database.** Manifests are plain JSON files, same pattern as
  sessions/cron today — greppable, syncable, no migration. IDs are zero-padded
  ordinals (`T0001`, `J0001`) so directory listings sort chronologically.
- **Isolation = sandbox.** A workspace switch repoints `Sandbox.Workspace`,
  the memory index, the session store, and the skills dir. Two workspaces never see
  each other's files unless the user says so.

### Backend changes (Pascal)

New package `src/pkg/projects/`:

- `PasClaw.Workspaces.pas` — enumerate (`workspace` + `workspace\d+` dirs), create,
  and switch workspaces; owns "active workspace" resolution (config field
  `active_workspace`, default `workspace`). Everything that currently hardcodes
  `JoinPath(GetHome, 'workspace/...')` (session store `PasClaw.Session.Store.pas:384`,
  memory, cron state, skills) is routed through it. This is the one **cross-cutting
  refactor** in the plan and the first thing to land.
- `PasClaw.Projects.Store.pas` — CRUD for projects/tasks/jobs manifests; status
  transitions; job↔session linkage.
- `PasClaw.Projects.Tools.pas` — agent-facing tools so the model can manage its own
  board: `project_create`, `project_list`, `task_create`, `task_update`,
  `job_report`. Jobs are *created by the runtime* when a chat turn or a
  `spawn`/`spawn_background` subagent starts under a task, so the transcript and
  status wire up automatically (reuses `PasClaw.Agent.Subagent*.pas`).

New gateway routes (`PasClaw.Gateway.Server.pas`, same dispatch style as today):

```
GET/POST        /v1/workspaces            list / create ("workspace2", ...)
POST            /v1/workspaces/activate   switch active workspace
GET/POST        /v1/projects              list / create (in active workspace)
GET/PATCH/DELETE /v1/projects/<name>
GET/POST        /v1/projects/<name>/tasks
GET/PATCH       /v1/projects/<name>/tasks/<id>
GET             /v1/projects/<name>/tasks/<id>/jobs     (+ /<id> detail)
POST            /v1/projects/<name>/tasks/<id>/run      start a job (agent turn)
GET             /v1/desktop/events        SSE: job progress, task status, app-ready
GET             /apps/<project>/          serve the project's built HTML app
POST            /v1/apps/<project>/run    run a python/native app via shell backend
POST            /v1/apps/<project>/stop
```

`/v1/desktop/events` reuses the gateway's existing SSE plumbing (chat streaming, log
tail) so both frontends get live job/task updates without polling.

---

## 2. The app factory (the Lovable part)

The agent needs to *prefer building apps over writing prose*. That's promptware plus
a thin runtime:

- **Builder mode.** A desktop-scoped system-prompt overlay (new
  `PasClaw.Agent.Prompt` section, toggled per session by the desktop clients):
  *"You are building software inside project X. Deliverables are apps, not essays.
  Choose the lightest kind that works: `html` (single self-contained page) →
  `python` (script, optionally with web UI) → `fpc`/`delphi` (native). Write the
  app under `projects/<name>/app/`, maintain `app.json`, keep tasks/jobs updated
  via the project tools."* Ship it as a built-in skill (`skills/app-factory/`) so
  it's editable promptware, not compiled strings.
- **`app.json` manifest** — the contract between agent and desktop:

  ```json
  {
    "name": "Spam Filter",
    "kind": "html | python | fpc | delphi",
    "entry": "index.html | main.py | src/SpamFilter.dpr",
    "run":   "python3 main.py --port {port}",
    "build": "fpc src/spamfilter.pas | (delphi_build)",
    "window": { "width": 640, "height": 480, "icon": "Mail" },
    "permissions": { "network": ["imap.gmail.com:993"], "env": ["IMAP_PASSWORD"] }
  }
  ```

- **Runners** (`PasClaw.Apps.Runner.pas`): `html` apps are just served
  (`/apps/<project>/`) and opened in a window (iframe on the web, `TWebBrowser` in
  FMX — the Retro demo already solves the native-control-over-FMX z-order problem
  with its snapshot trick in `uMain.pas:BrowserActiveChanged`). `python` apps run
  through the existing shell backend (including the Docker sandbox backend) with
  stdout captured to the job log; ones that serve HTTP get a port and open as a
  browser window too. `fpc`/`delphi` apps build via `shell_exec`/`delphi_build`;
  the binary launches as a normal OS process from the FMX client (web client shows
  a "built — download / run on host" card).
- **Iteration loop.** Each project window has its own chat box; messages route to
  `/v1/chat` with the project's session, cwd pinned to the project dir, builder
  overlay on. "Make the filter stricter" → agent edits `app/`, job completes,
  desktop gets an `app-updated` SSE event, the app window reloads. That reload loop
  is what makes it feel like Lovable.
- **Example flow** (the email case): *"Build me an app that connects to my IMAP and
  filters spam"* → agent creates project `spam-filter`, tasks (connect, classify,
  UI), runs jobs; produces a Python app with a small web UI; desktop pops a window
  with the running app; follow-up chat refines rules. Credentials go in per-project
  env (never in `app.json`), prompted for by the desktop, passed only to that app's
  process.

---

## 3. Web UI: the retro desktop in the browser

New standalone page served by the gateway (keep the existing `webui.html` untouched
as the "classic" UI): `src/pkg/gateway/desktop.html` at `GET /desktop`, embedded via
the same `.rc` resource mechanism as `webui.html`. Same house rules: **one file,
vanilla ES2020, no JS toolchain.**

- **Window manager** (~500 lines of JS): absolutely-positioned window divs over a
  desktop div — title-bar drag, 8-edge resize, z-order/activation, minimize to
  taskbar, maximize, cascade. Mirror the behaviors documented in the Retro repo
  (click-anywhere activates + starts the drag, double-click title maximizes, edge
  maximize) so web and FMX feel identical.
- **The styles.** The FMX `.style` files derive from
  [classic-stylesheets](https://github.com/nielssp/classic-stylesheets) /
  system.css, and the repo's `docs/palettes.md` + `tools/generate_retro_styles.py`
  define a **role-based palette system** (window face, bevel light/dark, title
  active/inactive, accent…). Port that: one `desktop.css` written entirely against
  `--role-*` CSS variables + a palette JSON per look (Win95, Win31, MacOS9, CDE,
  NeXTSTEP, Synthwave, ClaudeCode/Dark first; the rest are palette drops). A small
  generator in the styles repo (which we also control) can emit these palette JSONs
  from the same source the FMX styles are generated from, so **both clients share
  one palette definition** and skins keep working. Bevels are 1–2 px `border-color`
  tricks — exactly what these looks were originally made of, so fidelity is high.
- **Layout:** left dock = **project tree** (Projects → Tasks → Jobs, live status
  glyphs); taskbar = open windows + workspace switcher (`[1][2][3]` pager buttons,
  Ctrl+Alt+←/→) + Menu button (New Project / New Workspace / Display Properties /
  Classic UI link); desktop icons per project (double-click = open its app or its
  chat). Windows: **Chat** (per-project, SSE streaming — reuse the existing webui
  chat JS), **App** (iframe on `/apps/<project>/`), **Jobs** (live log tail),
  **Display Properties** (style + skin picker, straight from the demo's
  `BuildStylePicker`).
- **Period-native agent output** (the §0 vision, made concrete): the chat window
  renders structured agent output as period UI, not markdown. A proposed plan
  (`plan_write` already exists in `PasClaw.Tools.PlanWrite.pas`) renders as a
  wizard dialog whose pages are the Tasks; a clarifying question renders as a
  modal message box with real buttons; running jobs render the classic progress
  dialog. This is a client-side mapping over the same `/v1/chat` + tool-event
  stream — no new model protocol needed to start (a `ui_hint` field on tool
  events can come later).
- Workspace switch = one `POST /v1/workspaces/activate` + full desktop state
  reload; per-workspace window layout persisted to `<workspace>/desktop/state.json`
  so each "virtual desktop" remembers its windows.

---

## 4. FireMonkey app: `desktop/PasclawDesktop.dproj`

A new top-level `desktop/` project (sibling of `studio/`), starting **from
`Demo/RetroDesktop/uMain.pas`** — it already demonstrates everything we need:
desktop + taskbar + menu-bar styles, windows with real FMX controls, the style/skin
picker, the `TWebBrowser`-in-a-window snapshot workaround, `FreeNotification`
window-lifetime tracking, and F11 kiosk mode.

- **Dependencies, not vendoring:** add `..\..\Cross-Platform-Retro-OS-Styles\Source`
  to the project search path and load styles from its `FMXStyles/Retro/` dir
  (reuse the demo's `FindStyleDir` walk-up, plus a configurable path in the INI).
  Document the sibling-checkout requirement in `desktop/README.md`.
- **Reuse Studio's plumbing:** `studio/MasterDetail.pas` already has the gateway
  HTTP client, SSE streaming chat, session handling, config editor. Extract its
  API layer into a shared unit (`src/pkg/component/PasClaw.Client.Api.pas`) used by
  both Studio and Desktop rather than copy-pasting.
- **Shell mapping:** left-docked `TTreeView` (or a `TRetroWindow` pinned as a
  drawer) = Projects→Tasks→Jobs; `TRetroTaskbar` = open windows + workspace pager;
  `TRetroDesktopIcon` per project; Chat/Jobs/Display windows as `TRetroWindow`s.
  HTML apps open in `TWebBrowser` windows pointed at the gateway's
  `/apps/<project>/`; native built apps launch as OS processes (and, later, FMX
  apps can be loaded in-process as packages — not in v1).
- **Two run modes:** *client* (talks to a running `pasclaw gateway`, works today)
  and *all-in-one* (embed `TPasClawServer` from `PasClaw.Agent` so the desktop app
  IS PasClaw — single exe, F11 = the "retro OS shell" experience).

---

## 5. Phases

| Phase | Deliverable | Touches |
|---|---|---|
| **1. Workspaces** | `PasClaw.Workspaces.pas`, path-resolution refactor, `workspaceN` dirs, `/v1/workspaces*`, CLI `pasclaw workspace list/create/switch`, tests | config, session, memory, cron, skills, gateway |
| **2. Projects/Tasks/Jobs** | `PasClaw.Projects.Store/Tools.pas`, REST routes, `/v1/desktop/events` SSE, job↔session/subagent linkage, tests | new pkg, gateway, agent |
| **3. Web desktop v1** | `desktop.html`: window manager, project tree, taskbar, per-project chat, jobs window, 3 palettes (Win95, ClaudeCodeDark, Synthwave) | gateway |
| **4. App factory** | `app.json`, runners (html serve + python run), builder-mode skill/prompt, app windows with live reload | new pkg, gateway, promptware |
| **5. FMX desktop v1** | `desktop/` project from the RetroDesktop demo: gateway client, tree, chat + app windows, style/skin picker, workspace pager | new top-level dir, shared client unit |
| **6. Polish** | full palette set from shared generator, per-workspace desktop state persistence, native app build/launch (`fpc`/`delphi_build`), all-in-one FMX mode, docs | styles repo + both clients |
| **7. Period-native AI** | wizard/dialog/progress rendering of agent output in both clients, per-style personality overlays (promptware), agent-aware File Manager window, seeded starter projects (notes/todo/finder as agent-built apps) | both clients, promptware |

Phases 3 and 5 are independent once 1–2 land; 4 slots between them and is where the
product thesis lives.

## 6. Risks / open questions

- **Path refactor blast radius (Phase 1).** Everything assumes one workspace.
  Mitigation: `TWorkspaces.Active` is the *only* source of the workspace root; land
  it with no behavior change (active = `workspace`) before adding N.
- **Style fidelity on the web.** The FMX styles are generated; the web port must
  come from the same palette data or the two clients will drift. Do the palette
  export in the styles repo (we own it) — never hand-copy hex values.
- **Running agent-written apps is arbitrary code execution — by design.** Scope it
  the way `shell_exec` already is: run through the configured shell backend
  (Docker backend = containerized apps for free), per-app `permissions` surfaced in
  the UI before first run, per-project env for secrets.
- **Simultaneous workspaces?** v1: one active workspace per gateway process
  (switch = repoint). If truly-parallel desktops are wanted later, the store/index
  handles are already per-workspace objects, so N live workspaces is an extension,
  not a rewrite.
- **Tasks vs existing `workflow` engine.** They're different layers: workflows are
  deterministic tool DAGs; Tasks/Jobs are agent intent + runs. A Task *may* execute
  a workflow; no merge needed in v1.
