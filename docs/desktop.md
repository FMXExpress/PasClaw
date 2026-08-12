# PasClaw Desktop

A desktop-paradigm client for PasClaw: windows, icons, a taskbar and virtual
desktops instead of a chat log. Two frontends over one backend —
a **web UI** the gateway serves at `/desktop`, and a **FireMonkey app** in
[`desktop/`](../desktop/) built on
[Cross-Platform-Retro-OS-Styles](https://github.com/FMXExpress/Cross-Platform-Retro-OS-Styles).

The organizing idea: **PasClaw answers with software, not with text.** Ask it
to handle your email and the deliverable is a small app that runs in a window
on your desktop, not an essay about how you might do it.

The design rationale lives in [`desktop-plan.md`](desktop-plan.md); this page
is how to use what is built.

---

## Quick start

```sh
pasclaw gateway                 # http://127.0.0.1:8088
pasclaw project seed            # optional: install Notes, To Do, Brain
```

Open <http://127.0.0.1:8088/desktop>. The classic chat UI is still at `/`.

For the native client, see [`desktop/README.md`](../desktop/README.md).

---

## The hierarchy

| Level | What it is | Where it lives |
|---|---|---|
| **Workspace** | An isolated agent world — its own memory, sessions, skills and projects. Switching one is like switching virtual desktops. | `$PASCLAW_HOME/workspace`, `workspace2`, `workspace3`, … |
| **Project** | A thing being built, usually an app, plus its tasks. | `<workspace>/projects/<name>/` |
| **Task** | A unit of intent inside a project. | `.../tasks/T0001/` |
| **Job** | One agent run working a task. | `.../tasks/T0001/jobs/J0001/` |

Everything is a JSON manifest on disk — greppable, syncable, no database.

### Workspaces

The original `workspace/` directory **is** workspace #1; nothing moved when
this landed. New ones are siblings:

```sh
pasclaw workspace list
pasclaw workspace new "Home"     # creates workspace2
pasclaw workspace use workspace2
```

`$PASCLAW_WORKSPACE` overrides the active workspace for a single process,
which is how a subagent or a second gateway runs in another world without
editing your config.

In the desktop, the taskbar's `[1] [2] [3]` pager switches workspaces
(Ctrl+Alt+←/→). Switching closes the current desktop's windows — they belong
to the workspace, not to the browser tab.

### Projects, tasks and jobs

```sh
pasclaw project list
pasclaw project new "Spam Filter"
pasclaw project show spam-filter
```

The agent manages the same board itself through two tools:

| Tool | Actions |
|---|---|
| `project` | `list`, `create`, `get`, `update` |
| `task` | `list`, `create`, `update`, `job` |

Jobs are opened by the runtime when a turn starts working a task, so the
model only has to close them. Opening a job marks its task **active**;
reporting a job **done** closes the task. The desktop tree shows this live.

---

## Apps

A project's app lives in `projects/<name>/app/` and is described by
`app.json`:

```json
{
  "name": "Spam Filter",
  "kind": "page | html | python | fpc | delphi",
  "entry": "index.html",
  "window": { "width": 640, "height": 480, "icon": "Mail" },
  "permissions": { "network": ["imap.gmail.com:993"], "env": ["IMAP_PASSWORD"] }
}
```

Five kinds, cheapest first:

| Kind | What it is | How it opens |
|---|---|---|
| `page` | A static HTML document, **no scripts**. What an answer page is. | Served, opened in a window |
| `html` | A self-contained page **with** scripts, using the state store below. | Served, opened in a window |
| `python` | A script the runner spawns. | `POST /v1/apps/<p>/run` |
| `fpc` | `build` runs first (`fpc ...`), then the binary. | `POST /v1/apps/<p>/run` |
| `delphi` | `build` via a RAD Studio toolchain, then the binary. | `POST /v1/apps/<p>/run` |

`permissions.network` and `permissions.env` are **shown to the user before
the app opens**, not buried in a file nobody reads.

### Running the process kinds

```
POST /v1/apps/<project>/run     {"confirm": true}   -> {state, port, url, command}
POST /v1/apps/<project>/stop
GET  /v1/apps/<project>/runlog  -> combined stdout+stderr, capped
```

Running an agent-written `run` line is arbitrary code execution on your
machine. That is the deal the app factory makes — the same one `shell_exec`
already makes — and the runner is explicit about it:

- **Nothing starts without consent.** A `run` without `"confirm": true`
  answers **409** and hands back the exact command, so a client can show the
  user what they are approving. A confirmation that hides the command is
  theatre.
- The child's cwd is the project's `app/` directory.
- **Secrets never come from `app.json`.** An app declaring
  `permissions.env` gets those names filled from `projects/<n>/app/.env`, a
  file only you write. Nothing else from the parent environment is inherited,
  so an app cannot read your provider keys just by existing.
- A `{port}` in the `run` line gets a free port (8700+) and the app's URL
  comes back in the response; `$PORT` is also set.
- One child per project, tracked and killable. Every child is stopped when
  the gateway stops.

What the runner does **not** do yet: run the child inside the Docker shell
backend. That backend's `Exec` is one-shot, so a long-lived server would have
no handle to stop. Until that is wired, a `python` app runs on the host.

### Persistence without a backend

Most useful small apps need a little state — filter rules, a todo list, a
reading log — and spawning a Python process for that is absurd. Every project
gets a key/value store at `projects/<name>/app/state.json`, reachable at:

```
GET    /v1/apps/<project>/state           list keys
GET    /v1/apps/<project>/state/<key>     {"key","exists","value"}
PUT    /v1/apps/<project>/state/<key>     body is the value
DELETE /v1/apps/<project>/state/<key>
```

An unset key answers **200 with `exists: false`**, not 404 — every app's first
run reads keys it has never written.

Apps do **not** call that endpoint directly. They include the SDK the gateway
generates per project:

```html
<script src="pasclaw.js"></script>
<script>
  const books = await pasclaw.getJSON("books", []);
  await pasclaw.setJSON("books", books);
</script>
```

The SDK also exposes a **narrow read window** onto the agent's own surfaces,
which is what the Calendar, Library and Cookbook suite apps are built on:

```js
const crons = await pasclaw.read("cron");      // also: sessions, providers,
const pages = await pasclaw.read("pages");     //       projects
```

The allowlist is enforced **server-side** in `PasClaw.Gateway.Desktop`, so it
holds however the app is opened. There is no `config` surface and no write
side; a provider entry reports `has_key: true/false` and never the key.

**Why the indirection.** App frames are sandboxed *without*
`allow-same-origin`, so generated code cannot reach the desktop's DOM or the
operator's bearer token. That also puts them in an opaque origin, which blocks
their own network access. So the SDK posts a message to the desktop, which
makes the call **scoped to the project the frame actually belongs to** — an
app cannot name another project's store. Opened standalone (a plain tab, the
native client's browser window) the page is genuinely same-origin and the SDK
falls back to `fetch`. Same two calls either way.

### Containment

Generated apps are model-authored code, written from text that web pages may
have influenced. Three layers hold them:

1. **Path resolution** — `/apps/<project>/...` resolves only inside that
   project's `app/` directory, and only for an allowlisted extension set.
   Traversal (`..`, encoded, absolute, backslash, NUL) is rejected twice: on
   the raw request text and again on the resolved path.
2. **CSP** — `page` kind gets `script-src 'none'; connect-src 'none'`;
   `html` may run its own inline scripts and reach *only* this gateway.
   Neither may be framed by a foreign site.
3. **Sandbox** — the desktop frames apps with `sandbox="allow-scripts
   allow-forms"`, no same-origin.

Running `python` / `fpc` / `delphi` apps is arbitrary code execution by
design, scoped the way `shell_exec` already is — configure the Docker shell
backend and they run containerized.

---

## Live updates

```
GET /v1/desktop/events        Server-Sent Events
```

The board changes while you watch it, so the clients subscribe rather than
poll. Events are small JSON objects with a monotonic `seq`:

```json
{"seq":42,"ts":"...","type":"job","project":"spam-filter",
 "task":"T0001","id":"J0001","status":"running"}
```

Types: `projects`, `project`, `task`, `job`, `joblog`, `app`, `page`,
`workspace`, plus `hello` on connect and `gap` after an overflow.

Each subscriber has a **bounded queue (256), oldest dropped**. A browser tab
that stops reading cannot grow the server's memory; when it overflows it gets
a `{"type":"gap"}` marker instead of the lost events, and the correct client
response to a gap is to refetch what it displays. There is no replay buffer —
the state is on disk and cheap to re-read.

---

## Answer pages

A search or a question about your own data ends as an HTML **document**, not
as chat text: sections, tables, comparison grids, citations as real links —
the layout chosen to fit the answer.

```
POST   /v1/pages     {"query": "...", "kind": "search|data|report"}
GET    /v1/pages     history
GET    /pages/<id>/  the rendered document
```

Pages live in `<workspace>/pages/`, so browsing history is part of the
workspace.

**Two guarantees are enforced in Pascal, not asked of the model:**

- **The sources strip.** The model writes the page *body*; PasClaw writes the
  frame, which always ends with the list of sources and the generation time.
  A page with no sources renders an explicit "could not be grounded" notice
  rather than looking authoritative.
- **No scripts.** Bodies are stripped of `<script>`, `<iframe>`, event-handler
  attributes and `javascript:` URLs before framing, and served under a
  script-free CSP.

Generation runs the real agent loop: the gateway registers its page
generator at startup (`InstallDesktopCallbacks`), so `POST /v1/pages` with a
`query` researches and renders. A gateway with **no provider configured**
answers 503 and says so; a caller may also POST a rendered `body` directly.

The same wiring backs `POST /v1/projects/<n>/tasks/<t>/run`, which opens a
job, runs a turn on its own thread (the HTTP call returns the job id
immediately), streams output into the job log, and closes the job. A task
whose **last** job finishes is closed automatically — `done` when the job
succeeded, back to `todo` when it failed. A task you marked `blocked` is
never quietly reopened.

---

## Blueprints

A project exports as a blueprint — its app files and task *titles*, and
explicitly **not** its state store, task notes, job history, or environment:

```sh
pasclaw project export notes > notes.json
pasclaw project import notes.json
```

```
GET  /v1/projects/<name>/blueprint
POST /v1/projects/import      {"blueprint": "...", "name": "optional"}
```

Importing never overwrites: a name that exists gets `-2` appended, because the
point of a blueprint is that the recipient gets their **own** copy to remake.

---

## The system suite

```sh
pasclaw project seed
```

Installs seven apps into the active workspace:

| App | What it shows | Built on |
|---|---|---|
| **Notes** | A notepad | the state store |
| **To Do** | Your own list, separate from the agent's board | the state store |
| **Brain** | What PasClaw remembers, as cards you can tear up | the state store |
| **Calendar** | Your month, plus the agent's scheduled jobs | `read("cron")` |
| **Library** | Every page, session and project, filterable | `read("pages"/"sessions"/"projects")` |
| **Cookbook** | Which model answers, in plain language | `read("providers")` |
| **Mail** | An inbox the agent triages | the state store + the Email channel |

They are not built in. Each is an ordinary project with an ordinary
`app.json`, using the same `html` kind and the same state store your own apps
use — so you can open Notes, read its source, and ask PasClaw to add a word
count, and it is not a special case when you do. Seeding never overwrites an
existing project, so a suite app you have remade survives an upgrade.

---

## Period-native output

The desktop renders structured agent output as **real UI**, not markdown.
When a reply contains a fenced block:

````
```pasclaw-ui
{"ui":"wizard","title":"Plan","steps":[{"title":"...","body":"..."}]}
```
````

…the user gets a wizard whose **Next** button approves each step and whose
**Finish** turns the steps into real tasks on the board. A decision arrives
as a message box with buttons, and the chosen label comes back as the user's
next chat turn:

````
```pasclaw-ui
{"ui":"ask","text":"IMAP or the Gmail API?",
 "buttons":[{"label":"IMAP","value":"IMAP"},{"label":"Gmail API","value":"Gmail API"}]}
```
````

The convention is optional and fail-safe: text outside the block stays
visible, and a malformed block degrades to raw text rather than vanishing.
The builder prompt teaches it, so no model change is needed.

Each style also carries a short **voice** appended to the system prompt —
Apple System answers like a 1984 Macintosh, Win95 like a wizard, Synthwave
with a little neon. It costs one sentence and is what makes the style picker
feel like it changes the machine rather than the paint.

---

## HTTP reference

Every route below sits inside the gateway's existing bearer-auth gate.

| Method | Path | Purpose |
|---|---|---|
| GET/POST | `/v1/workspaces` | list / create |
| POST | `/v1/workspaces/activate` | switch active workspace |
| GET/POST | `/v1/projects` | list / create |
| GET/PATCH/DELETE | `/v1/projects/<name>` | inspect / edit / remove |
| GET | `/v1/projects/<name>/blueprint` | export |
| POST | `/v1/projects/import` | import |
| GET/POST | `/v1/projects/<n>/tasks` | list / create |
| GET/PATCH | `/v1/projects/<n>/tasks/<t>` | inspect / edit |
| POST | `/v1/projects/<n>/tasks/<t>/run` | start an agent turn (503 without an agent) |
| GET/POST | `/v1/projects/<n>/tasks/<t>/jobs` | list / open |
| GET/PATCH | `/v1/projects/<n>/tasks/<t>/jobs/<j>` | inspect / report |
| GET | `/v1/projects/<n>/tasks/<t>/jobs/<j>/log` | tail |
| GET | `/v1/apps/<project>` | app manifest |
| GET/PUT/DELETE | `/v1/apps/<p>/state/<key>` | per-app state |
| POST | `/v1/apps/<p>/run` | start a process app (needs `confirm`) |
| POST | `/v1/apps/<p>/stop` | stop it |
| GET | `/v1/apps/<p>/runlog` | its captured output |
| GET | `/v1/apps/<p>/read/<surface>` | allowlisted read window |
| GET | `/v1/desktop/events` | SSE: board changes |
| GET | `/apps/<project>/…` | app assets (+ virtual `pasclaw.js`) |
| GET/POST | `/v1/pages` | history / generate |
| GET/DELETE | `/v1/pages/<id>` | inspect / remove |
| GET | `/pages/<id>/` | rendered document |
| GET | `/desktop` | the web desktop client |

---

## Styles

Both clients take their palettes from the **same source**: the `PALETTES`
table in the styles repo's `tools/generate_retro_styles.py`, which is what the
`.style` files themselves are generated from. The web client's CSS is
extracted from it, never hand-copied:

```sh
scripts/export-retro-palettes.py \
  --styles-repo ../Cross-Platform-Retro-OS-Styles --inject
```

That rewrites the block between the `BEGIN/END GENERATED PALETTES` markers in
`src/pkg/gateway/desktop.html`. Re-run it after changing a style's palette;
the committed page already contains all 27, so a fresh clone needs nothing.

---

## Tests

```sh
make test-desktop
```

Covers the workspace layer (including the back-compat path), the project
store and tools, the app factory (with the full path-traversal suite at both
the resolver and the routing layer), the HTTP surface, and blueprint data
hygiene. `test-client-api` additionally exercises the shared native-client
library against a live gateway when `PASCLAW_TEST_GATEWAY` is set, and skips
itself otherwise.

The FireMonkey client needs Delphi and is not part of `make`.

## Known limits

Stated plainly rather than left to be discovered:

- **Process apps run on the host**, not in the Docker shell backend (see
  above). Treat a `run` line the way you treat `shell_exec`.
- **Open apps through the desktop.** An `html` app opened as a *top-level*
  page is same-origin with the gateway, so it can reach `/v1/*` and read a
  token you stored in the desktop's `localStorage`. Inside the desktop it is
  sandboxed into an opaque origin and can do neither. If your gateway is
  token-gated, treat generated apps as trusted-only when opened standalone.
- **The FMX client is unbuilt here.** It has no Delphi in CI; the shared
  client library it depends on is tested, the UI is not.
