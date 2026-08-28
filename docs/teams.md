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
   project mode.
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
```

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
