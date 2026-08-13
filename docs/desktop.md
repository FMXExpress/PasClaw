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

Open <http://127.0.0.1:8088/desktop>. The classic chat UI is still at `/`.

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
`workspace`, plus `hello` on connect and `gap` after an overflow.

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
from config, then `auto_router.easy_model` when that router is on, then a
known small model for the provider in use, then the main model unchanged —
so it works out of the box and can be pinned. **Research keeps the main
model**: it plans, reads several sources and synthesises, and downgrading
that would show.

**Follow-ups.** `POST /v1/pages` takes an optional `revise` naming a page
this question continues. The generator is handed that document and returns a
complete revised body — as a *new* page, because a page is the record of an
answer at a time and editing it in place would falsify it. An id naming no
page is treated as an ordinary new question rather than failing the request.


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
needs, and a fake 100% is worse than an honest "still going".

### Make this interactive

`POST /v1/pages/<id>/promote` copies a page into a new project as an `html`
app. The **Make interactive** button in the Browser does it in one click,
opens the app, and puts its icon on the desktop.

The copy is the design. A page is the record of an answer at a time, so
editing it in place would falsify the history; the app is the part that
changes. Two things travel with it: the sources footer (provenance does not
stop mattering because a document became editable) and a `pasclaw.js` tag,
so the first "now make it sort by date" has an SDK to reach for.

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
