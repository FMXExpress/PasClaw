# Agent team templates

The standing-agent system (roster, mailbox, runs, supervision — see
[agents.md](./agents.md)) works, but starting a team means hand-typing
every agent: name, role, who it reports to, then messaging each one into
motion. That is building the org from scratch every time. This plan makes
teams **ready-made**: pick a template, state a goal, and the team exists
and starts working.

The shape already has a precedent in this codebase: the system suite.
`SeedSuite` installs a catalogue of apps into a workspace, idempotently,
skipping (and reporting) anything the user already owns. A team template
is the same contract applied to agents instead of apps.

## What a template is

One JSON file describing a team:

```json
{
  "name": "software-team",
  "title": "Software Team",
  "description": "A six-role team that takes a goal and ships an app.",
  "agents": [
    { "name": "foreman",  "title": "Foreman",          "parent": "",
      "model": "primary", "role": "…full role prompt…" },
    { "name": "pm",       "title": "Product Manager",  "parent": "foreman",
      "model": "fast",    "role": "…" },
    { "name": "dev",      "title": "10x Developer",    "parent": "foreman",
      "model": "primary", "role": "…" },
    { "name": "ui",       "title": "UI Psychologist",  "parent": "foreman",
      "model": "fast",    "role": "…" },
    { "name": "qa",       "title": "Test Engineer",    "parent": "foreman",
      "model": "fast",    "role": "…" }
  ],
  "kickoff": "The operator's goal: {{goal}}\nBreak it into a project with tasks on the board, assign owners by messaging them, and report back what the plan is.",
  "wake": { "spec": "*/15 * * * *", "who": ["foreman"] }
}
```

- `model` is a **tier**, not a model id — `primary`, `fast`, or empty to
  inherit. Tiers resolve through the same chain the rest of the gateway
  uses, so a template never hard-codes a model name that goes stale.
- `kickoff` is the one message that starts the machine, sent to the
  top-level agent(s) with `{{goal}}` filled in from what the user typed.
- `wake` is what makes the team autonomous (below).

Built-in templates compile into the binary as a catalogue (`TeamTemplates`,
same shape as `SuiteApps`); user templates are plain files in
`workspace/teams/` and override built-ins by name. A team you built by
hand can become a template: export the current roster to a file, share it.

## The built-in catalogue

Two templates to start. `duo` — a Foreman and a 10x Developer, the
cheapest thing that demonstrates the loop. `software-team` — the six
roles below. Both are software templates because that is what PasClaw
builds; the mechanism is generic and a research or writing team is just
another file.

### Role prompts: one skeleton, six characters

Every role prompt has the same five sections, because the sections are
what make a team a system instead of six chatbots:

1. **Who you are** — one sentence of identity.
2. **What you own** — the artifact this role is accountable for.
3. **How you work** — a concrete loop, always the same shape: *check your
   messages → check the board → do one increment → update the board →
   report if something changed that your parent needs to know.*
4. **Who you talk to** — route **work through the task board** (create
   and update tasks) and use **messages for exceptions** (blocked, done,
   need a decision). Never idle-chat another agent. The board is shared
   state everyone can see in the desktop; a decision made only in a
   message is invisible.
5. **What done means** — tested/checked, recorded on the board, reported
   up. Claiming done without evidence is the one prohibited move.

The characters (full text ships in the template; these are the cores):

**Foreman** *(lead, reports to the operator)* — Owns the plan. Turns the
goal into a project and tasks, assigns each task by messaging its owner,
reviews what comes back, and is the only agent who reports to the
operator unprompted. On each wake: read messages, walk the board, unblock
or reassign anything stalled, run the supervision sweep, and if the board
is done, say so and stop waking the team.

**Product Manager** — Owns what "it" is. Rewrites the goal as user
stories with acceptance criteria *before* the developer starts; answers
the developer's "what should happen when…" questions; cuts scope rather
than letting tasks balloon. Every acceptance criterion is a task note the
Test Engineer can execute.

**10x Developer** — Owns the code. Ships the smallest increment that
works, runs it before claiming anything, and reports failure as plainly
as success. Asks the PM when requirements are ambiguous instead of
guessing; asks the Foreman when blocked on environment. The "10x" is not
volume — it is never having to be asked twice, never claiming done
untested, and leaving the project so the next turn can pick it up cold.

**UI Psychologist** — Owns the user's first five minutes. Opens what the
developer built and reviews it as a first-time human: what is the very
first thing a user sees, what do the labels assume, where does an error
leave you stranded, what takes three clicks that should take one. Files
each finding as a **task with a concrete rewrite** ("rename 'Execute
query' to 'Search'"), never an essay. Cognitive load, defaults, and error
wording are the beat; pixel taste is not.

**Test Engineer** — Owns "does it actually work". Takes the PM's
acceptance criteria and tries to break the build: empty inputs, wrong
inputs, doing steps out of order, doing it twice. Every break becomes a
task with exact reproduction steps. Re-tests fixed tasks before they
close — the developer does not close their own bug.

**Code Reviewer** *(optional; off in the default template to save turns)*
— Owns maintainability. Reads the app source for the bug categories a
runtime test misses: state that can't survive a reload, error paths that
swallow, duplication that will drift. Files tasks, tagged so the Foreman
can defer them below feature work.

## Firing it up — two ways in

The whole point is: enable the team, **point it at work, and set it
free**. There are two kinds of "work" to point at, and both are one
command:

**A goal** — the team invents the plan:

```
pasclaw team up software-team --goal "an invoice tracker for my shop"
```

**An existing project and its task list** — the team works the board
you already have:

```
pasclaw team up software-team --project invoice-desk
```

On the desktop: **Start → Agents → New team…** — pick a template, then
either type a goal or pick an existing project from a dropdown. Both
drive the same route:

```
POST /v1/teams/up   { "template": "software-team",
                      "goal": "…"  OR  "project": "invoice-desk" }
```

which does five things, in order:

1. **Seed the agents** — idempotent on slug, skip-and-report like
   `SeedSuiteReporting`; an existing agent keeps its conversation and its
   edited role.
2. **Bind the board.** Goal mode creates the project (free-name
   reservation, like every other build). Project mode uses the one you
   named. Either way the team's board exists before anyone runs.
3. **Send the kickoff** to the lead(s). Goal mode: "here is the goal,
   plan it onto the board". Project mode: "here is the board as it
   stands — read it, assign the open tasks, and get them moving". The
   difference is only the message; the machinery is identical.
4. **Start the lead's first run** so something visibly happens within
   seconds of the command.
5. **Install the wake cron** (below), stamped with the workspace like
   every cron entry.

### Tasks get an owner

Pointing a team at a task list exposes a real gap: a task today has no
**assignee**. The Foreman can message the developer "take T0003", but
nothing on the board records it, the wake loop cannot see it, and two
workers can grab the same task. So tasks grow an `assignee` field —
empty for unassigned, an agent slug otherwise — set by the Foreman
through the existing `task` tool, shown on the task row in the desktop
tree and the Projects window. "Open tasks it owns" then means exactly
what it says, for the wake loop and for each worker's own turn ("check
the board" = list tasks where assignee is me and status is not done).

`pasclaw team status` shows the roster with board progress;
`pasclaw team down` disables the wake entries (the off switch) and leaves
agents, conversations and board intact — parking, not deleting.

## The wake loop — closing the "no scheduler" gap

[agents.md](./agents.md) is explicit that nothing wakes an agent on its
own. Templates close it with the cron scheduler that already runs in the
gateway, via one new built-in skill:

**`team-tick`** (cron-fired, per team): run the supervision sweep
(restart dead runs — the existing `/v1/agents/supervise` logic), then for
each agent in the wake list that is idle **and has a reason to run**
(pending messages, or open tasks it owns), start a run. An agent with
nothing to do is left alone — a wake loop that burns a provider call per
agent per tick on "no news" is a bill, not a team.

Bounds, stated in the template and enforced by the tick: the existing
8-concurrent-runs cap, at most one run started per agent per tick, and a
team whose board has been done for two ticks stops being woken (the
Foreman's "say so and stop" from the role prompt, mechanically backed).

## Desktop

The Agents window grows the two things this needs and fixes what the
first audit found lacking:

- **New team…** replaces nothing — it sits next to **New agent…** and is
  a picker (template list + goal box), not a chain of prompt() dialogs.
- **Role text becomes visible and editable** — double-click a roster row
  already opens the conversation; the row gains an Edit that opens the
  role. Editing an agent's role mid-life is supported by the runtime
  (roles are re-read every turn); the UI just never offered it.
- A team badge on the roster groups members under their template name,
  with the wake state (`waking every 15m` / `parked`) shown where the
  operator can see why agents keep starting.

## Phases

1. **Template format + catalogue + seeding, and task assignees.**
   `TTeamTemplate`, the two built-ins, `POST /v1/teams` (list) and
   `/v1/teams/up` (seed only — no kickoff yet), `pasclaw team list/up`,
   the `assignee` field on tasks (store, `task` tool, desktop rows),
   tests pinning idempotency and skip-reporting. No autonomy yet: after
   this phase `team up` builds the org chart in one command.
2. **Kickoff + first run + wake loop.** Both entry modes (goal /
   existing project), the kickoff message, the immediate lead run, the
   `team-tick` skill and its cron entries, `team down` / `team status`.
   After this phase the demo is real: one command pointed at a task
   list, then watch the board move.
3. **Desktop.** Template picker, role editing, team grouping and wake
   state on the roster.
4. **Authoring.** `workspace/teams/` user templates, name-override of
   built-ins, `pasclaw team export <file>` from the live roster.

Phase 1 and 2 are each a PR; 3 and 4 are each small.
