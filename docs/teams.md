# Agent teams

A **team** is a ready-made set of [standing agents](./agents.md) with
roles, reporting lines and a shared task board. One command creates it,
points it at work, and leaves it running.

```sh
pasclaw team up software-team --goal "an invoice tracker for my shop"
pasclaw team up software-team --project invoice-desk   # work a board you already have
```

Or in the desktop: **Start → New Team…**, or just type *"spin up a
software team to build an invoice tracker"* into Ask PasClaw. All three
drive `POST /v1/teams/up`.

## What ships

| Template | Agents |
|---|---|
| `duo` | Foreman, 10x Developer — the smallest team that plans, builds and reports |
| `software-team` | Foreman, Product Manager, 10x Developer, UI Psychologist, Test Engineer |

Every role prompt is built from the same six sections, because the
sections are what make a team a system instead of five chatbots:

1. **Who you are** — one sentence.
2. **What you own** — the artifact this role is accountable for.
3. **What you do NOT own, and who does** — "requirements are the PM's;
   the environment is the Foreman's; closing your own bug is the Test
   Engineer's". This is what stops two agents doing the same work, or
   both assuming the other had it.
4. **How you work** — the same loop for everyone: *read messages → read
   the board → do one increment → update the board → report only if
   something changed that your manager must know*.
5. **Who you talk to** — work goes through the **task board**; messages
   are for exceptions only (blocked, done, need a decision).
6. **What done means** — it ran or was checked, the board says so,
   your manager heard. Claiming done without evidence is the one
   prohibited move.

Roles carry checklists rather than adjectives (the Test Engineer's is
"empty input, wrong input, out of order, twice") and each ends on one
anti-pattern line ("the 10x is never claiming done untested, not
volume").

**Building apps.** An app is files: `projects/<name>/app/index.html` and
`app.json`. The Developer's role says so, because the `desktop` tool's
`build_app` asks a *connected browser* to build and there may be no
browser watching. Workers write files; the Foreman uses the desktop
tool only to *show* the result.

## What `team up` does

1. **Seeds the agents** — idempotent on slug. An agent that already
   exists is **kept and reported**, conversation and edited role intact,
   the same contract `SeedSuiteReporting` has. Parents are created
   before their reports.
2. **Binds a board** — creates the project in goal mode, uses yours in
   project mode. In goal mode the project is named from a **short title
   derived off the front of the goal**, not the whole sentence: *"A book
   comparison app: enter up to 4 book titles and compare them side by
   side"* becomes `book-comparison-app`, not a 63-character slug that
   then appears in every path, task listing and message the team sends.
   Same rule the desktop's Ask path has always used, now server-side so
   a team and a hand-built app name things alike. The full goal is kept
   as the project's description.
3. **Sends the kickoff** to the lead, goal or board named.
4. **Starts the lead's first run**, so something happens in seconds.
5. **Writes the team's state file**, which is what the wake loop reads.

Templates are validated before anything is created: unique slugs, every
`parent` naming an agent in the same template, no reporting cycles, and
**model tiers rather than model ids** (`primary` / `fast` / inherit) —
a template that pinned a model name would go stale the day the name did.

## Tasks have owners

Tasks carry an `assignee` (an agent slug). The Foreman sets it through
the `task` tool; the board shows `@dev` on the row. This is not
decoration — it is how the wake loop knows who has work, and how two
workers avoid grabbing the same task. A handover said only in a message
is invisible to everything else.

## The wake loop

The gateway ticks every 30 seconds and, for each team whose own cadence
is due (`wake_minutes`, default 15):

- **supervises** — restarts runs whose process died;
- **reports stalls to the lead** — a task active with no progress for
  two cadences, whose owner is idle, produces a message to the
  *Foreman*, not another poke at the stuck worker. Waking a stuck worker
  repeats the stall; telling its manager is what unsticks it;
- **wakes agents that have a reason to run** — pending messages, or open
  tasks assigned to them. An agent with nothing to do is left alone: a
  loop that burns a provider call per agent per tick to be told "no
  news" is a bill, not a team;
- **parks a finished team** — a board fully done for two ticks stops
  being woken.

The wake list defaults to **every agent in the team**, not just the
lead. That was a real bug before it was a default: with only the lead
eligible, a worker holding an assigned task never ran, because an agent
cannot start another agent's turn and nothing else was looking.

**Mail skips the cadence.** The 15-minute wake is there to stop an idle
agent being re-woken every tick about the same unfinished task — nothing
new has happened. A *message* is the opposite: new information, from a
colleague now waiting on the answer. Making it wait out the cadence
meant a lead delegated and the whole team sat still for fifteen minutes,
with the handoff — the entire point of having a team — the slowest thing
in the system. So a team with mail waiting is due immediately.

**Block work that waits on other work.** Only `todo` and `active` tasks
wake their owner, so the Foreman marks a downstream task `blocked` and
says what it waits on. Without that, a review task created up front
wakes the reviewer to look at a project with nothing in it yet.

```sh
pasclaw team status        # who is up, their board, last tick
pasclaw team down duo      # park it: agents, conversations and board stay
pasclaw team rm duo        # retire it: the agents go, conversations stay
pasclaw team pause "lunch" # stop everything, running turns included
pasclaw team resume
```

## Stopping and removing

**Pause is the brake**, and it stops the system rather than asking it to:

- **No new turns start** — the tick, the run route and `team up` all
  check it. `POST /v1/agents/pause {"paused":true}`, the **Pause all**
  button in the roster, or `pasclaw team pause`.
- **Turns already running end too**, at their next *safe boundary*. The
  tool loop asks whether it has been stopped at exactly two points:
  before it calls the model, and after a round's tool calls have all
  come back and landed in the history. Both are moments where the turn's
  state is consistent, which is the whole design — a turn cut between a
  file write and the board update that belongs with it leaves exactly
  the half-finished mess someone hitting stop is trying to avoid. What
  this cannot interrupt is a single provider call already on the wire;
  that is what the stream idle timeout is for. What it *can* stop is the
  thing that actually runs away: a turn grinding through its whole
  iteration budget.
- **Whatever the turn did is kept.** A stopped turn still persists its
  transcript and still ends with a note in the conversation saying it
  was stopped, where it stopped, and what it had already done — so the
  agent's next turn picks up instead of starting the same work again.
- **Busy agents also get a note**, pushed into their steering queue and
  read between tool calls. That is the courtesy on top, not the
  mechanism: an agent that reads it gets to write down where it had got
  to before the loop lets it go. It stops either way.
- **The pause is on disk.** A gateway restart cannot quietly resume a
  system the operator stopped — of the ways this could fail, that is
  the one that would matter most.

**Removing** has two grains. A single agent: the **Retire** button on
its roster row, or `DELETE /v1/agents/<name>`. A whole team:
`DELETE /v1/teams/<name>` or `pasclaw team rm`. Both keep the
**conversation** and the **project** — a conversation is not garbage
because the role that held it was retired, and the work the team did is
the operator's, not the team's. Retire is refused on an agent that is
mid-turn; pause it first.

## Watching it work

Agent runs now **narrate**. Each tool call publishes an `agent-activity`
event, and the agent's chat window appends it live. Before this, an
agent's window sat frozen until the run finished — the session file is
only written when a turn ends, so a window that dutifully refreshed was
re-reading an unchanged file.

The Foreman's role tells it to **run the screen**: `open_agent` opens a
teammate's window when work is assigned, then `tile`; `minimize_all`
when the board is done. Those are ordinary `desktop` actions — agents
have always had that tool, nothing had ever told one to use it.

## Your own templates

Drop a JSON file in `workspace/teams/`. A user template **overrides a
built-in of the same name**, so `software-team.json` means *your*
software team.

```json
{
  "name": "duo",
  "title": "My Duo",
  "agents": [
    { "name": "boss", "title": "Boss", "role": "…", "model": "" },
    { "name": "hand", "title": "Hand", "role": "…", "model": "fast",
      "parent": "boss" }
  ],
  "kickoff": "Goal: {{goal}}  Project: {{project}}",
  "wake": { "minutes": 15 }
}
```

`pasclaw team export <file>` writes the live roster out as one of these
— how a team you hand-tuned becomes a team you can share.

## Flags

Teams need two model-facing flags that are off by default:

```json
{ "desktop_tools_enabled": true, "agent_tools_enabled": true }
```

The first lets the team manage its task board, the second lets members
message each other. `team up` **warns** when either is off and names it,
rather than seeding a team that cannot reach its own board — which
looks like model stupidity and is not.

`agent_tools_enabled` also **gates the model's `team_up` action**. The
`desktop` tool is registered always, because gating window management
behind a flag meant a fresh install could not answer "tile these" — but
`team_up` is not window management: it seeds standing agents, creates a
project and starts a turn, which is precisely what this flag exists to
let an operator decline. With the flag off the action is refused before
anything is published, and is not advertised to the model at all.

The **HTTP route stays open**. A person clicking **New team…** is the
operator, and gating them behind a switch meant for the model is the
same category error `/v1/agents` already documents.
