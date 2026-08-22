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
pasclaw project seed            # install the system suite
pasclaw mail sync               # optional: fill Mail from IMAP
```

Open <http://127.0.0.1:8088/desktop>. The full agent chat + configuration
surface is still at `/`, and opens inside the desktop as a window: Menu →
**Agent Console**.

For the native client, see [`desktop/README.md`](../desktop/README.md).

---

## The hierarchy

| Level | What it is | Where it lives |
|---|---|---|
| **Workspace** | A separate set of projects, pages and desktop layout. Switching one is like switching virtual desktops. | `$PASCLAW_HOME/workspace`, `workspace2`, `workspace3`, … |
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
which is how a subagent or a second gateway runs against another set of
projects without editing your config.

**A workspace is a wall.** Memory (facts, notes, MEMORY.md), sessions,
skills, the knowledgebase, checkpoints, cron state, projects, pages and the
desktop layout are all per-workspace. Business A in workspace 1 and business
B in workspace 2 do not know each other: what the agent remembers, what it
has indexed, and what its sandbox can reach all switch together, and
`workspace_isolation_tests` proves it — including that with
`restrict_to_workspace` on, the sandbox *refuses* a read into the other
workspace rather than merely not finding anything.

Single-workspace installs are untouched: every path resolves byte-for-byte
to what it was before (also pinned by test). One caveat: **one gateway
serves one active workspace at a time** — for truly concurrent work in two
workspaces, run two gateways on different ports.
[`workspaces-plan.md`](workspaces-plan.md) has the full design story.

**Desktops live inside a workspace.** The taskbar pager `[1] [2] [+]`
(Ctrl+Alt+←/→) switches *desktops*: numbered window arrangements, cheap,
instant, invisible to the agent. Each keeps its own layout, saved on the
gateway. Switching *workspaces* moved to the menu (**Switch Workspace…**)
behind a confirmation that names what it does — because after the isolation
work it genuinely changes what PasClaw remembers, and the consequential
action should not have the one-click gesture.

**A workspace can name its profile:**

```sh
pasclaw workspace bind workspace2 security
```

Working in `workspace2` then applies the `security` profile's config —
per-business providers, keys or sandbox settings with no new mechanism.
Precedence: `--profile` / `$PASCLAW_PROFILE` still win; the binding beats
the global `profile` field.

**Cron fires as its workspace.** New entries are stamped with the workspace
they were created in, and the scheduler pins its thread there for the
firing — business B's nightly job runs with B's memory and notes even while
you are looking at A. Shell skills carry the pin across the process
boundary too: children are spawned with `PASCLAW_WORKSPACE` set to the
pinned workspace, so a script that asks PasClaw for its workspace gets the
right answer. Entries created before tagging keep the old behaviour
(whatever workspace is active).

### Projects, tasks and jobs

```sh
pasclaw project list
pasclaw project new "Spam Filter"
pasclaw project show spam-filter
```

The agent can manage the same board itself through two tools, **off by
default**:

```json
{ "desktop_tools_enabled": true }
```

| Tool | Actions |
|---|---|
| `project` | `list`, `create`, `get`, `update` |
| `task` | `list`, `create`, `update`, `job` |

The desktop does not need them — both clients drive the board over HTTP, and
everything in this document works with the flag off. They exist for when you
want the *model* to open and close its own tasks. Off by default on purpose:
PasClaw's behaviour should not change for someone who never opens a desktop,
and two extra tools in the schema is two extra tools the model reads every
turn. Same opt-in shape as `cron_tool_enabled`.

Jobs are opened by the runtime when a turn starts working a task, so the
model only has to close them. Opening a job marks its task **active**;
reporting a job **done** closes the task. The desktop tree shows this live.

**Seeing it, and acting on it.** The **Projects** window is the whole chain
in one place — project → app / tasks → jobs — and every level is
double-clickable: a project opens its app or its chat, an app opens (or, for
a process app, opens its Run window), a task opens the project chat, a job
opens its log. Its buttons act on whatever is selected:

| Button | What it does |
|---|---|
| **Open** | The same as double-clicking the selected row |
| **New Task** | Add a task to the selected project |
| **Run Task** | Put PasClaw to work on the selected task — **this is what opens a job under it** |
| **Status** | Cycle the selected task: todo → active → done |
| **New Project** / **Edit App** | Create a project; edit the selected project's app source |
| **Rename** / **Delete** / **Refresh** | The selected project's title, the project itself, the board |

Run Task is the link that used to be missing from the desktop: without it a
task was a note to itself, and jobs only ever appeared because something
else happened to create one. The gateway answers as soon as the job is
*open* and runs the turn on its own thread, so the tree fills in through
live events rather than the window blocking for the length of the turn.

In the **web desktop** the same gesture is a **Run** button on the task row
itself, in the projects tree. It starts the job and opens its log in one
click — a job nobody can watch is the same silence as no job at all. A task
the agent is already working (`active`) is not offered the button; a
finished one is, since re-running a done task is an ordinary thing to want.
The row's own state arrives on the event feed, so it follows the job
without a reload.

The menu lists each project's **Tasks (n open of m)** under it, which opens
the Projects window with that project selected and expanded.

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

**Where it runs.** Set `shell_backend: docker` in config and the child runs
in a container instead of on your machine:

```
docker create --rm --name pasclaw-app-<project> \
  -v <project>/app:/app -w /app -p 127.0.0.1:<port>:<port> \
  [-e DECLARED_NAME=...] <image> sh -c "<the run line>"
docker start pasclaw-app-<project>
```

Only the app's own directory is mounted, and the port is published to
**loopback**, never `0.0.0.0` — a containerised app must not become reachable
from your network because Docker helpfully bound a wildcard. Nothing is
privileged and nothing is on the host network.

This deliberately drives the `docker` CLI rather than reusing the shell
backend's `Exec`, which is one-shot: a long-lived server started through it
would have no handle to stop. A created-then-started container has an id, so
`stop` and `runlog` have something to address.

**A remote daemon works, with one limit.** `docker context use` or
`DOCKER_HOST` points the CLI somewhere else, and PasClaw asks docker where it
is rather than reading the environment — a context switch repoints the CLI
without touching env vars, and guessing wrong here fails silently. When the
daemon is remote:

- the app directory is **copied in** with `docker cp` instead of bind-mounted,
  because a `-v` path resolves on the *daemon's* filesystem and would leave
  the app looking at an empty `/app`;
- an app that **serves a port is refused**, with the reason. A published port
  binds the daemon's loopback, which this gateway cannot reach, and publishing
  `0.0.0.0` instead would expose your app to that host's whole network.
  Console apps still run.

Every run record carries `backend: "host" | "docker" | "docker-remote"` and
the run window shows it, so you always know which side of which boundary your
app is on.

### Which machine is "local"

The two clients are not symmetric, and pretending otherwise would be the
kind of lie that costs you an afternoon:

| | FireMonkey client | Web client |
|---|---|---|
| `html` / `page` apps | in the app's own browser view — **your machine** | in the browser — **your machine** |
| `python` / `fpc` / `delphi` apps | spawned by the gateway it is talking to | spawned by the gateway it is talking to |

If you run `pasclaw gateway` on the same machine as the client, everything is
local and the distinction never comes up. Point either client at a gateway on
another box and it splits: HTML apps still run in front of you, because a web
page runs where it is rendered, while a process app runs where the gateway is,
because that is the machine with the filesystem, the ports and the compiler.

So the web UI cannot build you a *native* app that runs on your machine —
there is nowhere to put it. What it can build is HTML apps that run in your
browser, and console or server apps that run on the gateway host and show
their output (or their port) in a window. The FireMonkey client, run beside a
local gateway, is the configuration where "PasClaw builds software for this
computer" is literally true.

The run window names the host, and `GET /v1/desktop/config` reports it, so a
client never has to assume.

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
const crons = await pasclaw.read("cron");
const hits  = await pasclaw.read("kb", "expenses");   // kb takes a query
```

| Surface | What it is |
|---|---|
| `cron` | scheduled agent jobs |
| `sessions` | the session list |
| `providers` | the model catalogue, `has_key` only — never the key |
| `pages` | answer-page history |
| `projects` | the board |
| `memory` | the distilled facts the model is primed with |
| `notes` | markdown notes under `memory/notes/` |
| `skills` | what can be scheduled |
| `tasks` | the calling project's tasks (scoped by the route, not the app) |
| `kb` | the knowledgebase — searched server-side; takes a query |
| `checkpoints` | how far undo reaches |

The allowlist is enforced **server-side** in `PasClaw.Gateway.Desktop`, so it
holds however the app is opened. There is no `config` surface and no write
side; a provider entry reports `has_key: true/false` and never the key.

Reading and writing cannot make anything *happen*, and some apps need that —
Mail has to be able to go and fetch. So there is a third verb, and it is an
allowlist too:

```js
const r = await pasclaw.action("mail-sync");             // {filed: 3}
await pasclaw.action("note-save", { title, body });      // args ride as JSON
```

`POST /v1/apps/<project>/action/<name>` runs only names the gateway
implements, and only for the project each one belongs to:

| Action | Whose | What it does |
|---|---|---|
| `memory-remember` / `memory-forget` | Brain | edit the facts the model is primed with |
| `note-save` / `note-delete` | Notes | write markdown under `memory/notes/` |
| `task-add` / `task-done` | To Do | edit the real project board |
| `cron-add` / `cron-remove` | Calendar | schedule an installed skill |
| `mail-sync` | Mail | fetch from IMAP |
| `mail-draft` | Mail | summarise a message and draft a reply |

An unknown action and a real action asked for by the wrong project both
answer **404**. The pairing is the security property, not the name list:
without it any app could drive `memory-forget` and edit what the assistant
knows about you.

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
have influenced. Four layers hold them:

1. **Path resolution** — `/apps/<project>/...` resolves only inside that
   project's `app/` directory, and only for an allowlisted extension set.
   Traversal (`..`, encoded, absolute, backslash, NUL) is rejected twice: on
   the raw request text and again on the resolved path.
2. **CSP** — `page` kind gets `script-src 'none'; connect-src 'none'`;
   `html` may run its own inline scripts and reach *only* this gateway.
   Neither may be framed by a foreign site.
3. **Sandbox** — the desktop frames apps with `sandbox="allow-scripts
   allow-forms"`, no same-origin.
4. **A second origin** — see below.

Running `python` / `fpc` / `delphi` apps is arbitrary code execution by
design, scoped the way `shell_exec` already is — configure the Docker shell
backend and they run containerized.

#### Serving apps from their own origin

Inside the desktop an app is sandboxed and harmless. Opened as a *top-level*
page — a plain browser tab, "Open in browser" — it is same-origin with the
gateway, which means it can call `/v1/*` and read whatever the desktop left in
`localStorage`, including your bearer token. Sandboxing cannot help there;
there is no frame.

The fix is a boundary the browser already enforces. Give apps a **second
port**, and they are a different origin:

```sh
pasclaw gateway --port 8080 --apps-port 8081
```

That second listener serves `/apps/*` and exactly three API paths —
`state`, `read` and `action`, each scoped to the app that asked. It refuses
`/v1/chat/completions`, `/v1/config`, the project board, `run`, and
everything else; the allowlist is a function (`IsAppScopedPath`) with tests
on both halves. An app that goes looking for the desktop's `localStorage`
now gets a `SecurityError`, because it is not the desktop's origin.

The desktop learns the arrangement rather than assuming it:

```
GET /v1/desktop/config -> {"apps_isolated": true, "apps_origin": "http://127.0.0.1:8081"}
```

and frames apps from there. Apps keep working when you *don't* pass
`--apps-port` — one origin, sandboxed frames, as before — so this is an
upgrade, not a requirement. If your gateway is token-gated and you open
generated apps standalone, use it.

**The apps port is not bearer-gated, by construction.** The whole point of
the second origin is that app code never sees the operator token: the
desktop frames apps without it, and the standalone SDK sends none. Gating
those routes on that token would mean handing the untrusted origin the very
credential the split exists to protect. So on the `--apps-port` listener the
app surface — `/apps/*`, `/pages/*`, and the per-app `state`/`read`/`action`
paths — answers without a bearer, and everything else on it still 401s. The
main port is unchanged: the same paths require the token there. Keep the
apps port on localhost, or behind your own proxy auth, if that origin needs
to be private.

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
`workspace`, `turn-queued`, `agent`, plus `hello` on connect, `ping` on an idle
feed, and `gap` after an overflow.

**The feed proves it is alive, and the client checks.** After ~15s of
quiet the gateway sends `{"type":"ping"}` — a data frame, not an SSE
comment, because `EventSource` never surfaces comments to the page: a
connection that had died upstream was indistinguishable from a quiet one.
The desktop runs a watchdog on that: 45s without any message means
reconnect and re-read, rather than sit "live" showing a board that stopped
updating.

**Subscribe, then re-read — on the hello frame.** The client subscribes
only after its first load succeeds (subscribing behind an auth wall just
loops), which leaves a window where events published during those reads
reached nobody. Opening the desktop while an agent was mid-turn left the
board stale until the user happened to touch it.

The catch-up read is triggered by `hello`, and the ordering is the whole
point: the handler emits the response headers first (which is what fires
`EventSource`'s `open`), calls `DesktopSubscribe` second, and writes
`hello` third. So `hello` is the earliest frame that proves this reader is
on the publisher's list — a re-read fired on `open`, or right after
constructing the `EventSource`, can still race the handshake and land
before the server has anyone to publish to. Hooking it to the frame also
covers every way a feed begins: the first subscribe, the watchdog's
reconnect, and `EventSource`'s own automatic retry after a transient drop.

**Every terminal state reaches the stream.** Three of them used to be
missing, which meant the events a client would most want to act on were the
ones it never got:

- `{"type":"app","state":"exited"}` when a child ends on its own. Previously
  only recorded in a state field, so the Run window learned about a crashed
  app on its next tick and anything not polling never learned at all.
- `{"type":"app","state":"failed"}` when a launch cannot start. Only the
  caller saw the 400; a second desktop on the same workspace sat on
  "stopped" with no idea a start had been attempted.
- `{"type":"page"}` when a page is saved. `PublishPage` existed and nothing
  called it, so the end of the longest thing the gateway does — a research
  turn, minutes of it — was announced to nobody.

### Notifications (FireMonkey client)

Long work finishes while you are looking at something else, which is the
whole reason the FMX client turns three of these events into OS
notifications through `TNotificationCenter`:

| Event | Notification |
|---|---|
| a job reaching `done` / `failed` | **Job done** / **Job failed** — an agent turn on a task, minutes later |
| a `page` arriving | **Report ready**, titled with the question it answers |
| an app reaching `exited` / `failed` | **App stopped** / **App failed** |

Terminal outcomes only. A job going from queued to running, a task turning
active, the board being refetched — those are the tree's business, and a
toast per step would train you to dismiss them without reading.

And **only when the desktop is not the active window**. If you are looking
at it, the tree updating in front of you *is* the notification. Anything
queued while it had focus is dropped rather than held, so alt-tabbing away
does not produce a burst about things you already watched.

**Menu → Notifications: on/off**, remembered in `~/PasClaw/desktop.ini` —
*not* in the desktop layout. The layout is shared: both clients read and
write one state document per workspace, and the web client's writer replaces
it wholesale, so a preference parked in there would survive exactly until
someone opened `/desktop`. It does not belong there anyway — a layout
follows you between clients, while whether *this machine's* notification
centre gets used is about this machine.

On a system with no notification centre the row says `unavailable` rather
than offering a switch that does nothing.

Each subscriber has a **bounded queue (256), oldest dropped**. A browser tab
that stops reading cannot grow the server's memory; when it overflows it gets
a `{"type":"gap"}` marker instead of the lost events, and the correct client
response to a gap is to refetch what it displays. There is no replay buffer —
the state is on disk and cheap to re-read.

---

## Answer pages

**Which model.** A search, data or report page runs on the *fast* model:
these are summarise-and-format jobs, and the flagship makes them slower and
dearer without making them better. The model is resolved as `fast_model`
from config, then the auto-router's easy tier when that router is on, then a
known small model for the provider in use, then the main model unchanged —
so it works out of the box and can be pinned. The easy tier moves its
**provider** along with its model: `easy_model` is an override on
`easy_provider`, so a Groq tier under an Anthropic primary switches both or
neither. **Research keeps the main
model**: it plans, reads several sources and synthesises, and downgrading
that would show.

**Follow-ups.** `POST /v1/pages` takes an optional `revise` naming a page
this question continues. The generator is handed that document and returns a
complete revised body — as a *new* page, because a page is the record of an
answer at a time and editing it in place would falsify it. An id naming no
page is treated as an ordinary new question rather than failing the request.
A revision runs on whichever model its *kind* calls for, so a follow-up on a
search page stays quick and one on a report stays thorough.


A search or a question about your own data ends as an HTML **document**, not
as chat text: sections, tables, comparison grids, citations as real links —
the layout chosen to fit the answer.

```
POST   /v1/pages                {"query": "...", "kind": "search|data|report|research"}
GET    /v1/pages                history
GET    /pages/<id>/             the rendered document
POST   /v1/pages/<id>/promote   turn it into an app
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

### Deep research

`kind: "research"` (the Browser's **Research** button) is not a longer
search — it is a named three-phase shape the model is told to follow:

1. **Plan.** Break the request into sub-questions *before* searching, so the
   reading is directed rather than opportunistic.
2. **Read.** Search each sub-question separately and fetch the promising
   results — a snippet is not a source. Several *independent* sources, and
   where they disagree, enough reading to say why.
3. **Synthesise.** Structure the page by sub-question rather than by source,
   keeping what was found separate from what it means.

It runs for minutes, so it narrates: each tool call becomes a
`page-progress` event on `/v1/desktop/events`, and the Browser shows a
progress dialog with what the agent is doing right now. The bar creeps
toward but never reaches done — nobody knows how many sources a question
needs, and a fake 100% is worse than an honest "still going". The phases
tell the run's actual story in order: **Planning** the sub-questions,
**Drafting** the first full report, **Deepening** it round by round (each
round rewrites the draft with what it found), **Saturated** when a round
stops finding new ground, and **Writing** the final report.

### Make this interactive

`POST /v1/pages/<id>/promote` copies a page into a new project as an `html`
app. The **Make interactive** button in the Browser does it in one click,
opens the app, and puts its icon on the desktop.

The copy is the design. A page is the record of an answer at a time, so
editing it in place would falsify the history; the app is the part that
changes. Two things travel with it: the sources footer (provenance does not
stop mattering because a document became editable) and a `pasclaw.js` tag,
so the first "now make it sort by date" has an SDK to reach for.

**Near-duplicates are named out loud.** `CreateProject` is idempotent, so
every caller that means "a NEW project" first reserves a free slug —
`timer`, then `timer-2`, `timer-3`. Reserving quietly is how a workspace
fills up with seventeen variations of one idea, each build stepping over
the last without a word. So the step-over is now reported: building from
the shell names the projects that already match and offers to continue in
the newest one instead (the default), and promotion says in its status bar
how many neighbours the new app has. The disambiguation was always right;
doing it silently was not.

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
| **Notes** | A notepad whose notes PasClaw can read | markdown in `memory/notes/` |
| **To Do** | Your list and the agent's board, unified | the real task store |
| **Brain** | What PasClaw remembers, as cards you can tear up | the fact store the model is primed from |
| **Calendar** | Your month, the agent's scheduled jobs, and a way to add one | `read("cron")` + `cron-add` |
| **Library** | Every page, session, project and indexed document | `read("pages"/"sessions"/"projects"/"kb"/"checkpoints")` |
| **Cookbook** | Which model answers, in plain language | `read("providers")` |
| **Mail** | An inbox the agent triages, summarises and drafts replies for | IMAP + `mail-draft` |

**They are not toys over private state.** Brain reads the same fact store the
model is primed from, so tearing up a card genuinely makes the next turn not
know it. A note is a markdown file in the directory the memory index walks,
so writing one is the cheapest way to tell PasClaw something durable. A to-do
is an ordinary task on the project board — the agent can see it and close it.
Calendar writes real `crons[]` entries. That equivalence is the point; a
suite over its own copies would have been easier and would have meant
nothing.

Each is an ordinary project with an ordinary
`app.json`, using the same `html` kind and the same surfaces your own apps
use — so you can open Notes, read its source, and ask PasClaw to add a word
count, and it is not a special case when you do. Seeding never overwrites an
existing project, so a suite app you have remade survives an upgrade.

### Filling Mail from your inbox

Mail starts as a list you can type into. Point it at IMAP — the same
credentials the email channel uses — and it fills itself:

```sh
export PASCLAW_EMAIL_IMAP_HOST=imap.example.com   # _PORT defaults to 993
export PASCLAW_EMAIL_IMAP_USER=you@example.com
export PASCLAW_EMAIL_IMAP_PASS=...

pasclaw mail sync          # or press Sync in the app
```

Each subject gets a category — **Risk**, **Deadline**, **Decision**,
**Request**, **FYI** — from a keyword pass, and you can cycle it with a
click. The rules are deliberately dumb and there is no model call: this runs
on a timer, and paying for a guess you can correct in one click is a bad
trade. Ask the agent to re-tag them properly when it matters.

Two properties are worth knowing about, because they are what make it safe to
leave running:

- **It never marks anything read.** Fetches use `BODY.PEEK[]`, not
  `RFC822.HEADER` — which RFC 3501 says sets `\Seen`. Listing your inbox must
  not mark it read, and it must not drain the email channel's unseen set out
  from under it. The cost is that a peek pulls the whole message, so it takes
  the newest 25 rather than the mailbox.
- **It files each message once.** A UID ledger means re-syncing the same
  window changes nothing, and a message you *deleted* from the list stays
  deleted. Deleting is a decision; a sync that quietly overruled it would be
  worse than missing mail.

This is not the email channel. That one routes each message **through the
agent loop and replies over SMTP** — a bot answering your mail. This only
reads headers and files them: no agent, no reply, nothing sent. They share
credentials and can run side by side.

For a hands-off inbox, put it on the cron:

```sh
pasclaw cron add "*/15 * * * *" "pasclaw mail sync"
```

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

## Conversations live on the server

Every chat window in the desktop -- a project's chat, and the shell -- is a
view of a PasClaw session, not a transcript the browser owns.

The window holds what is on screen and nothing else. When you send a turn it
posts the one message you typed, with `X-PasClaw-Session` naming the
conversation and `session_context: true` asking the gateway to supply the
rest. The gateway loads the stored transcript, runs the turn against it, and
files the answer back before the stream closes. Reopening the window -- or
opening it in a different browser against the same gateway -- replays what
was filed.

This is how every other PasClaw surface already worked; the desktop was the
exception. It used to keep the conversation in a JS array, send that array as
the request context, and `PUT` it back afterwards, which cost the
conversation's full length in both directions on every single turn, let two
windows onto the same project overwrite each other's transcripts, and undid
the tool loop's compaction each turn because the browser still held the long
copy and sent it again.

Session ids are derived, not stored: `desktop-<project>` for a project chat,
`desktop-shell` for the shell. They are real sessions -- `pasclaw resume`,
`pasclaw learn` and the Library window all see them. See
[Gateway § `session_context`](./gateway.md#v1chatcompletions-with-session_context--server-held-conversations)
for the wire format.

Turns on one conversation run one at a time: the gateway serializes
same-session turns, so two screens submitting to the same project queue
rather than corrupt each other. The parked screen is told -- the gateway
publishes a `turn-queued` event addressed to the client id the request
carried in `X-PasClaw-Client`, and that screen's reply bubble reads
"waiting for another turn on this conversation to finish" instead of
sitting silent. The first streamed token of the real answer paints over
the notice; it never enters the transcript.

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
| POST | `/v1/apps/<p>/action/<name>` | allowlisted side effect, scoped per app |
| PUT | `/v1/apps/<p>/entry` | put an earlier version of the app back |
| GET/POST | `/v1/agents` | the standing roster / create one |
| GET/DELETE | `/v1/agents/<name>` | inspect / retire |
| POST | `/v1/agents/<n>/send` | put a message in its mailbox |
| POST | `/v1/agents/<n>/run` | give it a turn now |
| GET | `/v1/agents/<n>/messages` | what it was told |
| POST | `/v1/agents/supervise` | one supervision pass |
| GET | `/v1/desktop/events` | SSE: board changes |
| GET | `/v1/desktop/config` | how apps are served (origin, isolation) |
| GET/PUT | `/v1/desktop/state` | the workspace's window layout |
| POST | `/v1/pages/<id>/promote` | page -> app |
| GET | `/apps/<project>/…` | app assets (+ virtual `pasclaw.js`) |
| GET/POST | `/v1/pages` | history / generate |
| GET/DELETE | `/v1/pages/<id>` | inspect / remove |
| GET | `/pages/<id>/` | rendered document |
| GET | `/desktop` | the web desktop client |

`/v1/fs` (already part of the gateway) backs the **File Manager** window.
Opening an `.html` file from it loads it in a **new Browser tab** rather than
over whatever you were reading, and the tab remembers the *path*, so coming
back to it re-reads the file. It is fetched through `/v1/fs`, not as a
`file://` URL: a remote gateway's files are not on this machine, and the
browser control cannot send the bearer token.

**A file opens as what it is.** Both clients now agree on three cases,
where the web one used to answer all of them with source text or a byte
count:

- An `.html` file **renders**, with a Source button beside it. The frame
  carries an *empty* `sandbox` attribute — no scripts, no forms, no
  navigation, no same-origin — because a document found in the workspace
  is not trusted code, and one that could reach this origin could read the
  desktop's bearer token out of `localStorage`. It is passed as `srcdoc`
  rather than pointed at a URL, so `/v1/fs` keeps serving workspace files
  as text.
- A **binary** file opens in a hex view: offset, hex, and the printable
  column that makes a header or an embedded string readable. It pages
  through `/v1/fs/peek`, 1 KiB at a time, which reports the true size in
  `X-File-Total` — so a gigabyte file is inspectable without downloading
  it, which is the case that matters against a remote gateway.
- Anything else is text, and a truncated read still says so.

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
the resolver and the routing layer), the `docker run` argv the runner builds,
the HTTP surface including the action allowlist, the mail bridge's triage
rules and its idempotent merge, and blueprint data hygiene. It also runs as
part of plain `make test`. `test-client-api` additionally exercises the
shared native-client library against a live gateway when
`PASCLAW_TEST_GATEWAY` is set, and skips itself otherwise.

Two things are asserted rather than executed here, on purpose, because the
alternative is that nobody checks them at all: the `docker run` argv (the
isolation policy in executable form — which directory is mounted, where the
port is published, what is *not* passed) is pinned as a string on machines
with no Docker, and the IMAP bridge is split so the merge half — where the
idempotence lives — is testable without a mail server.

The FireMonkey client needs Delphi and is not part of `make`.

## The chat transcript is not a browser (FireMonkey client)

It was, and that is what made the window a white square. A `TWebBrowser` is
a native control: it paints above all FMX content, so it needs a
snapshot-swap to coexist with overlapping windows, and its Edge engine
initialises **asynchronously** — hand it a document in the same turn you
create it and the document is dropped. Under the legacy IE engine that
worked by accident, which is why the failure only appeared once the
`WindowsEngine` ordering was fixed and WebView2 actually engaged.

The transcript is a `TVertScrollBox` of ordinary controls now — one per
markdown block, not one per turn:

| Block | Control |
|---|---|
| heading | a bold label, sized by level |
| paragraph | a wrapped label (consecutive prose lines join, so a hard-wrapped reply is not a column of one-liners) |
| bullet / numbered | an indented label carrying its own marker |
| quote | an indented, dimmed label |
| code fence | a read-only monospace `TMemo`, sized to its content — a fence is the one place the exact characters and line breaks *are* the content |
| rule | a `TLine` |

No native control, no snapshot, no engine, nothing that can be blank. The
parsing lives in `PasClaw.Client.Markdown` (`MarkdownToBlocks`,
`FlattenInline`) where FPC compiles it and `client_markdown_tests` asserts
it; the FMX side is left with "make a label, make a memo", which matters in
a file that has no compiler in CI.

The cost, stated plainly: an FMX `TLabel` has no rich text, so **bold and
links are flattened** — `**bold**` loses its asterisks and `[text](url)`
becomes `text (url)`, because dropping where something points is worse than
showing it. Structure survives; typography does not. PasClaw Studio's chat
reached the same trade.

Streaming still uses a memo, but it now sits *below* the transcript instead
of replacing it: with both as ordinary controls they can coexist, so the
settled conversation stays readable while the next reply arrives.

---

## Off the UI thread (FireMonkey client)

Every call into `TPasClawClient` is a blocking HTTP round trip, and most of
them used to run on the UI thread from a button handler. Locally that is a
stutter; against a gateway on another machine it is a frozen window.

One helper carries all of them:

```pascal
Async('Files',
  procedure begin  { the blocking call, results into captured locals }  end,
  procedure begin  { paint them, on the UI thread }                     end);
```

It enforces the three rules no call site should have to remember:

- **The client context is set inside the worker.** It is per-thread, so
  tagging it on the caller would attribute the call to whatever the main
  thread happened to be doing when the button was pressed.
- **An exception in the work half cannot vanish or kill the process** — it
  lands in the Log window, named with its context.
- **The done half never runs after teardown**, and `FormDestroy` releases
  in-flight work before freeing the client. Waiting alone is not enough: a
  research turn is minutes *by design*, so any patience short enough to
  close a window promptly is short enough to expire while one is still out —
  and then free the client under it anyway. So the sockets are **cut** first
  (`TPasClawClient.CancelAll`, which every request registers itself with for
  the length of its call), and the bounded wait after that is expected to
  succeed rather than hoped to.

Two rules for the call sites themselves:

- A completion that paints into a window it did not create asks
  `WindowAlive` first. A window can be closed while its answer is in flight,
  and *reading a field of one of its controls to find out* is already the
  bug — the check compares pointer values against the window manager's live
  list and never dereferences.
- Anything polled or event-driven is **coalesced**: the board refresh and
  the Run-window poll each keep one request in flight, because an agent
  writing files produces a burst of events and a fixed timer beat can be
  shorter than the round trip it starts. Coalescing is not dropping — a
  request that arrives while one is out is remembered and run afterwards,
  since the answer already on the wire predates the change that prompted it.
- **Answers that can be overtaken are stamped and checked.** Directory
  listings carry a generation number, the hex pager checks its offset, the
  sources strip checks the page, and a file tab checks it is still the tab
  in front. Without that, navigating twice quickly lands you back where you
  came from when the slower answer arrives last.
- **Writes that must not reorder are serialised.** The layout save keeps one
  PUT in flight and the next one supersedes rather than queues, because the
  route has no ordering token and an older write finishing last would
  persist window positions the user had already moved away from.
- **Ordering against another call means sharing its worker.** Switching
  workspace captures the departing layout on the UI thread and sends it as
  the first act of the same worker that activates the new one — `/v1/desktop/state`
  is scoped to whichever workspace is active when it *arrives*, so two
  independent workers would race to write one workspace's windows into
  another.

Three things are still synchronous and are named here rather than left to be
discovered: the chat turn (`SendChat`), the tree rebuild — one call per
project for its tasks and one per task for its jobs — and the menu's
per-project manifest reads.

---

## One command, many screens

`Tool_Desktop` publishes onto the event feed, and **every** connected desktop receives it. For window management that is the point — ask for the windows to be tiled and every screen you have open tidies.

It is wrong for the actions whose effect outlives the tab. With two tabs open, one `build_app` ran twice: two turns against the same project, racing on one app directory and one session file, with one turn's history lost.

So the server names one executor. Each SSE subscriber is assigned an id and told it in the feed's `hello` frame; `PublishDesktopCommand` stamps the oldest live subscriber's id as the command's `target`. Clients run **every** action they receive except `build_app`, `edit_app` and `open_page`, which they run only when they are the target. A command with no target at all (an older gateway) is executed in full, which is the single-desktop behaviour that was there before.

Oldest-subscriber is arbitrary but *stable*, and stability is the property that matters: every command in a session lands on the same screen rather than scattering builds across tabs. The consequence worth knowing is that asking in a second tab can have the app open in the first one.

### The schema has to parse

`desktop`'s schema shipped with `"e.g. [{""do"":""tile""}]"` — the Pascal doubling convention applied to double quotes, where JSON wanted `\"`. It did not parse.

That would be a footnote if it failed loudly. It does not: providers inject a schema with `PutRaw`, and `PutRaw` answers an unparseable string by substituting `{}` **without a word**. So every real provider was told `desktop` takes no arguments, and the model did exactly as it was told — `desktop()`, empty, every time. No error text can argue a model out of the schema it was given; the coercion below was treating a symptom.

`make test-tool-schema` now parses every registered tool's schema, and the `ToProviderDefs` output too. Registration is where the mistake is made, so registration is where it is caught.

### The near misses are accepted

`desktop` is the only one of four sibling tools that takes a plural `actions` **array**; `project`, `task` and `agent` all take a singular `action` **string**. That is a strong prior toward the wrong key and the wrong arity, and it cost a real turn: *"build a book comparison app where I can enter 4 amazon book urls"* produced `desktop()` with no arguments at all and an error where the app should have been.

So four shapes are read as what they plainly mean, rather than refused:

| What arrived | Read as |
|---|---|
| `{"actions":[{"do":"tile"}]}` | itself — the documented shape |
| `{"actions":{"do":"tile"}}` | a one-item list |
| `{"actions":"[{\"do\":\"tile\"}]"}` | the parsed array |
| `{"action":"build_app","title":…}` or `{"do":"tile"}` | one action, `action` renamed to `do` |

Same trade the app manifest makes when it reads `type` as a synonym for `kind`: a request should not fail over a word when what was meant is unambiguous.

The rename applies **wherever an action object can arrive** — inside the documented array, inside a singular object under `actions`, inside a stringified array, at the top level. `runShellActions` looks up `SHELL_ACTIONS[a.do]` and reads nothing else, so an action that reaches the feed still keyed `action` is published, reported to the model as *sent*, and then dropped by the screen as unknown. A success the caller never receives is worse than the refusal this coercion replaced, so the misspelt key is renamed — not merely tolerated, and not duplicated alongside `do`.

One exception, deliberately: if an item in an array cannot be read at all — not an object, or carrying no action name — the array is passed through exactly as it arrived. That is a malformed request rather than a near miss, and the screen naming it beats quietly reshaping the array around it.

A call that genuinely carries no action is still an error — coercion is for near misses, not for guessing. But the error now contains a **worked call** the model can copy, because that text is the whole of what it reads before its retry, and "missing required argument" is not something you can act on.

## Steering a running turn

While a turn runs, the composer's button reads **Stop** — and pressing it stops. The Enter key carries the third meaning: **Enter with text in the box steers the running turn** instead of killing it. "Also make the header blue", typed mid-build, used to stop the build it was amending. The note goes to `/v1/steer` with the conversation's session id, the running loop picks it up at its next iteration, and the transcript shows it arrow-marked (`↳ also make the header blue`). Enter on an empty box still stops, so the keyboard-only path to Stop survives.

Both composers steer — the project chats and the shell.

## Narrow screens

The desktop metaphor assumes a screen with room to float windows on. Below **720px** of browser width it stops pretending:

- The **dock becomes a drawer** instead of a permanent left edge. At 390px it was taking 232 of them — 60% of the screen for a sidebar. It slides in over the stage when you open it (Start → Projects, or the tree button) and dismisses when you tap outside.
- **Windows open full.** There is no room to float in, and a saved arrangement from a laptop was designed for a screen this is not.
- **Desktop icons are hidden.** They are a pointer-and-big-screen affordance; the dock is the way around on a small one.

Independently of the breakpoint, **window geometry is clamped to the stage** whenever it arrives from outside `createWindow` — a layout restored on a different screen, the browser being resized, an agent placing a window. Before this a layout saved on a desktop and reopened on a phone put windows at 788px on a 390px viewport with no horizontal scroll, so most of every window was unreachable.

The breakpoint is on browser width, not device: a narrow window on a large monitor gets the same treatment, which is right, because the problem is width rather than what is holding it.

## Known limits

Stated plainly rather than left to be discovered:

- **A `run` line is arbitrary code execution.** With `shell_backend: docker`
  it happens in a container; otherwise it happens on your machine. That is
  the same deal `shell_exec` makes, and the run window tells you which one
  you got — but it is still the deal.
- **Docker mode is unverified end to end here.** The argv is pinned by test;
  no container has actually been started in this environment, local or
  remote.
- **The IMAP fetch half is unverified.** Triage, the merge and the excerpt
  capture are tested; the conversation with a real mailbox is not, because
  no account is configured in the build environment. PasClaw is an IMAP
  *client* -- there is no server component here and none is wanted.
- **Triage is keywords, not comprehension.** "Re: the thing" is FYI, and a
  politely-worded emergency will sort under Request. One click fixes it, and
  the pencil will re-read the message properly.
- **Mail never sends.** Drafts land in the app for you to send from your own
  client. Sending would need SMTP credentials, a consent gesture and an
  undo; the email channel is where "PasClaw answers your mail" lives,
  deliberately behind its own configuration.
- **Deep research holds the HTTP request open** for the length of the turn.
  The progress feed keeps the UI honest, but a proxy with a short timeout in
  front of the gateway will cut it off.
- **Artifact versions are per conversation.** A card captures what its turn
  produced, in that browser tab; closing the chat loses the history. The
  checkpoints package is the durable answer and is not wired to this yet.
- **Standalone apps need `--apps-port`.** Without it, an app opened as a
  top-level page is same-origin with the gateway. Inside the desktop it is
  sandboxed either way.
- **Facts are not workspace-scoped.** Brain deliberately reads the same
  `workspace/memory/facts.db` the agent does, which does not follow the
  active workspace. Showing workspace2's facts while the model is primed
  with workspace1's would be a prettier lie.
- **The FMX client is unbuilt here.** No CI in this repo has Delphi. It is at
  feature parity with the web client on paper -- Browser with Research and
  promotion, File Manager, Run window, artifact versions, saved layout -- and
  the library underneath it is compiled and live-tested, but the UI file
  itself has never been through a compiler. Expect a round of errors the
  first time it is opened in RAD Studio.
