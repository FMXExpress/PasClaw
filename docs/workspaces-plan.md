# Workspaces: isolation, and where the desktops go

A plan for resolving a tension the desktop work exposed and then papered
over. Written to be argued with before any of it is built.

---

## 1. The problem, named properly

"Workspace" is currently doing two jobs that pull in opposite directions:

**As a virtual desktop.** Switching is cheap, instant and cosmetic. Linux
workspace 1 → 2 changes which windows you see; it does not change what your
programs can read. Nothing is isolated, and nothing should be — that is the
whole point of the metaphor.

**As a tenant.** "Business A in workspace 1, business B in workspace 2, and
they must not know each other." Switching is consequential. What the agent
remembers, what it has read, what it can reach — all of it changes.

These cannot be the same object. The first wants to be free; the second
wants to be a wall. Today PasClaw ships the *word* from the first and
delivers neither: a workspace separates projects, pages and the desktop
layout, and shares memory, sessions and skills. That is the worst of both —
too heavy to flick between like desktops, too porous to hold two businesses.

The fix is to stop overloading the word. **The isolation boundary and the
screen arrangement are different things, and one nests inside the other.**

---

## 2. The proposal

```
Workspace              the wall. One body of work, one memory, one set of
  ├── Desktop 1        sessions. Switching is deliberate.
  ├── Desktop 2        the view. Which windows are on screen. Switching is
  └── Desktop 3        instant and changes nothing the agent can see.
        └── Projects   what you are building. Live in the workspace, and
                       may appear on any desktop.
```

- **Workspace** keeps its name. It already means "a bounded body of work"
  everywhere else in software (VS Code, Slack, GitHub), the directories are
  already `workspace`, `workspace2`, `workspace3`, and the CLI is already
  `pasclaw workspace`. What changes is that we stop *describing* it as a
  virtual desktop, and start making the isolation real.
- **Desktop** is new, and is only a saved arrangement of windows. Cheap to
  create, cheap to switch, invisible to the agent.
- **Projects** stay exactly what they are.

### Why not "projects are the desktops"

It was the other option on the table and it does not survive contact with
the suite. Notes, Mail and Calendar are three separate projects that you
want on screen *at the same time*; a project is a unit of work product, not
a unit of attention. Project-as-desktop also means you can never have two
arrangements of the same project — reading view and building view — which is
one of the things desktops are for.

Projects are nouns. Desktops are views of them. Keep them apart.

### The third axis that already exists

PasClaw already has **profiles** (`pasclaw profile use`, `--profile`,
`$PASCLAW_PROFILE`), which scope *configuration* — provider, model, limits.
So there are three orthogonal things, and only one of them is new:

| Axis | Question it answers | Status |
|---|---|---|
| **Profile** | Which model and provider settings? | built |
| **Workspace** | Which memory, sessions, files? | half-built |
| **Desktop** | Which windows are on screen? | not built |

This matters for a concern that would otherwise need inventing: *"business A
and business B have different API keys."* They do not need per-workspace
credentials — a workspace can name a **profile**, and switching workspace
switches config with it. One new field, no new mechanism.

---

## 3. What isolates, what shares

Isolation is only useful if the line is drawn deliberately. Proposal:

| | Scope | Why |
|---|---|---|
| **Memory** (facts, notes, index) | workspace | The whole point. Business A's facts must not prime business B's turns. |
| **Sessions** | workspace | A transcript is the most direct leak: "what did we say about the acquisition". |
| **Projects, tasks, jobs** | workspace | Already scoped. |
| **Answer pages** | workspace | Already scoped. |
| **Knowledgebase** | workspace | Indexed documents are the second most direct leak. |
| **Checkpoints** | workspace | Undo must not reach across a wall. |
| **Cron entries** | workspace | See §6 — the hard one. |
| **Desktop layout** | desktop, inside workspace | The view. |
| **Skills** | **two-tier** | A "format a commit message" skill is *yours*; a client's house style is *theirs*. Merge `$PASCLAW_HOME/skills` (global) with `<workspace>/skills` (local), workspace wins on a name clash. |
| **Providers, API keys, model config** | global, or per-workspace **profile** | Re-entering an Anthropic key per business is hostile. A workspace naming a profile covers the case where they genuinely differ. |
| **MCP servers** | global for now | Flag as an open question; a client-specific MCP server is a plausible want. |

### The optional escape hatch, and why it is optional

The fact store already carries a `Scope` field (`user` | `project` |
`session`). So `scope=user` facts — "Eli prefers Object Pascal", "reply
tersely" — *could* live in a shared store while `scope=project` facts stay
behind the wall. That is genuinely useful and costs almost nothing to build.

It is also a leak vector: one mis-scoped distillation and a client detail
lands in the global store. **Recommendation: build the wall first, ship it,
and only then consider the door.** If it is built, the shared store should be
append-only from the user's own hand (`pasclaw memory add`), never from
automatic distillation.

---

## 4. The refactor

~55 call sites hardcode `JoinPath(GetHome, 'workspace/...')`:

| Store | Sites | Notes |
|---|---|---|
| skills | 14 | loader, manage, pending |
| workspace root | 14 | export/import zip, fs browse |
| memory | 11 | facts db, index, notes, memory files |
| checkpoints | 5 | gateway ×2, TUI ×2, agent |
| sessions | 2 | `PasClaw.Session.Store.pas:384` |
| workflows, steering, kb-files | 3 | one each |

**The property that makes this safe:** `WorkspaceRoot('workspace')` returns
`<home>/workspace` — byte for byte what those call sites compute today. For
anyone who never creates a second workspace, routing through the resolver is
a *no-op*. That is what makes a change of this blast radius acceptable, and
it is the thing to verify first and keep verifying.

Not everything under `$PASCLAW_HOME` should move: `cache/`, `localvector/`,
`profiles/`, `run/`, `tmp/` are machine-level, not work-level. Leave them.

---

## 5. Desktops inside a workspace

Small, and mostly UI.

- **Storage.** `<workspace>/desktop/state.json` becomes
  `<workspace>/desktop/desktops.json` — a list of named arrangements plus
  which is current. The existing single-layout file migrates to desktop 1.
- **Route.** `/v1/desktop/state` gains an optional `?desktop=N`; the desktop
  list gets `GET/POST /v1/desktop/desktops`.
- **Affordance swap, and this is the part that matters.** Today the taskbar
  pager `[1] [2] [3]` and Ctrl+Alt+←/→ switch *workspaces*. They should
  switch **desktops**: frequent, cheap, reversible. Switching workspace
  becomes a deliberate gesture — a menu item that names what it is doing
  ("Switch workspace — this changes what PasClaw remembers"), because after
  this plan it genuinely does.

That swap is a behaviour change for anyone using the pager today. It is the
right one: the frequent, harmless action should have the cheap gesture, and
the rare, consequential one should not.

---

## 6. The hard parts

These decide whether the wall is real. Everything above is bookkeeping by
comparison.

### 6.1 The filesystem sandbox — do this first or none of it counts

The agent has `fs_read`, `fs_grep`, `shell_exec`. If `Sandbox.Workspace`
does not follow the active workspace, then separating the memory *files*
achieves nothing: the agent in workspace 2 reads
`../workspace/memory/facts.db` and the wall is decorative.

**Isolation begins at the sandbox, not at the store.** `Sandbox.Workspace`
must be workspace-derived, and `allow_read_paths` globs must be evaluated
relative to it. Anything else is theatre.

### 6.2 One process, one "active" workspace

`ActiveWorkspaceName` is process-global state read from config. But a
gateway serves many clients: a browser tab on workspace 1 and the FMX client
on workspace 2 are a perfectly ordinary thing to want, and today they would
fight over one global.

Options, roughly in order of cost:

1. **Per-request scope.** The desktop routes already know which workspace
   the caller means; thread it through as a parameter rather than reading a
   global. Correct, and touches every store signature.
2. **Per-connection scope.** A client declares its workspace on connect; the
   gateway keeps it per-session. Cheaper, but agent turns run on their own
   threads and would need the context propagated anyway.
3. **One workspace per gateway process.** Run a second gateway on another
   port for business B. Honest, zero new machinery, and genuinely the
   strongest isolation — two processes cannot leak to each other by
   accident. Ugly if you switch often.

**Recommendation: (3) as the shipped answer, (1) as the direction.** Say
plainly in the docs that concurrent multi-workspace serving is one process
per workspace until per-request scoping lands. A wall that only holds when
you remember to switch is not a wall.

### 6.3 The scheduler

A cron in business B must fire while you are looking at business A — but it
must run *as* B: B's memory, B's skills, B's sandbox. So cron entries stop
being "run in the active workspace" and become workspace-tagged, with the
scheduler establishing that workspace's context per firing.

This is the single hardest piece, because it is where "active workspace as
global state" breaks first and most visibly. It may be the forcing function
for 6.2 option (1).

### 6.4 Subagents and background jobs

A subagent must inherit the workspace of the turn that spawned it. There is
precedent: checkpoints already propagate a context handle across threads
(`AdoptCheckpointHandle`). Workspace context should ride the same way.

---

## 7. Phasing

**Status: all eight phases are built.** Phases 6–8 landed as: desktops are
numbered layouts inside the workspace (`/v1/desktop/desktops`, the pager and
Ctrl+Alt+arrows page them, workspace switching moved behind a named
confirmation); `pasclaw workspace bind <ws> <profile>` applies a profile per
workspace via `workspace_profiles` in config.json; and cron entries are
stamped with their creating workspace, fired under a thread-scoped pin
(`SetThreadWorkspace`) so a tagged job runs as its own world without racing
concurrent requests. Remaining honest limits: a *prompt-kind* cron skill
that shells out spawns children with the process env, not the pin — noted,
not hidden; and per-request workspace scoping (§6.2 option 1) is still the
direction, one-gateway-per-workspace the shipped answer for concurrency.

**Earlier status: phases 1–5 are built** — one commit routed every hardcoded
`workspace/` path through `ActiveWorkspaceName` (memory, sessions, skills,
KB, checkpoints, cron state, heartbeat, steering, workflows, PLAN.md, the
Docker shell mapping, the sandbox browse root), a runtime switch repoints
the live gateway's sandbox via `OnWorkspaceSwitched`, and
`workspace_isolation_tests` pins both halves: the leak (including sandbox
refusal) and the single-workspace no-op. Skills shipped workspace-scoped
rather than two-tier. Phases 6–8 (desktops-in-workspace, profile binding,
cron tagging) remain.

Each step ships on its own and leaves the tree green.

| # | Step | Ships |
|---|---|---|
| 1 | **Sandbox follows the workspace.** Plus a leak test (see §8). | The wall's foundation. Without it nothing else is real. |
| 2 | **Sessions + checkpoints** through the resolver. | Transcripts and undo stop crossing. |
| 3 | **Memory** — facts db, index, notes, memory files. | The headline. Brain, Notes and distillation become per-workspace. |
| 4 | **Knowledgebase.** | Indexed documents stop crossing. |
| 5 | **Skills, two-tier** (global + workspace, workspace wins). | The one that is not pure isolation, and needs its own thought. |
| 6 | **Desktops inside a workspace** + the pager affordance swap. | The half of the original metaphor that was actually wanted. |
| 7 | **Workspace → profile binding.** | Per-business model/provider config, using machinery that exists. |
| 8 | **Cron workspace tagging**, and whatever per-request scoping it forces. | The hard one, last, once the shape is proven. |

Steps 1–4 are the product. 5–8 are the finish.

---

## 8. How we prove it

A refactor of this shape cannot be reviewed by reading it. It needs a test
that fails when the wall leaks:

```
workspace_isolation_tests
  in workspace1:  write a fact, a note, a session, a KB doc, a skill
  switch to workspace2
    - the fact is not in ActiveFacts
    - the note is not in ListNotes
    - the session is not in the session list
    - a KB search does not return the document
    - fs_read of workspace1's memory directory is REFUSED by the sandbox
    - fs_grep for a string unique to workspace1 finds nothing
  switch back
    - all five are there again
```

The last two matter most: they are the ones that catch a store that moved
correctly while the sandbox stayed put.

Plus a **no-op test**: with a single workspace, every resolved path equals
the string the old code produced. That is what lets this land without
changing anything for anyone who does not want it.

---

## 9. Risks, and what I would cut

- **This is a change to PasClaw's own behaviour**, which the desktop work
  deliberately avoided. That reversal is intentional and requested — but the
  no-op property (§4) is what keeps it honest, and it should be enforced by
  test rather than by care.
- **Skills two-tier is the weakest part.** Merging two skill sets with
  name-clash rules is a small policy engine, and policy engines grow. If it
  gets complicated, ship workspace-only skills and let people copy.
- **The `scope=user` shared memory door (§3) is the thing to cut first.** It
  is the only element that deliberately makes a hole in the wall we are
  building.
- **Per-request workspace scoping (§6.2 option 1) is a big refactor** hiding
  behind a small sentence. If it turns out to be the only way to make cron
  work, that should be its own plan, not a bullet in this one.
