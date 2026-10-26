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
| `executive-team` | Chief of Staff routing eight C-suite officers — Strategy, Finance, People, Legal (General Counsel), Operations, Marketing, Product, Board Comms |

`executive-team` is a port of
[OpenExecutive](https://github.com/SenteLabsAI/OpenExecutive)'s virtual
C-suite into PasClaw's team machinery. Its orchestrator becomes the
Chief of Staff, its "route each question to the relevant few
specialists" becomes task assignment, and its economy is the wake
policy we already have: an officer with no mail and no open assigned
task is never woken, so nine agents cost like the two or three actually
working on the current question. The chief is told so directly — its
role says *two officers is a normal number; eight means you did not
think*.

Two things deliberately differ from OpenExecutive. Its specialists are
invisible — one synthesized voice, the architecture never shown;
PasClaw's whole desktop exists to *watch* agents work, so the officers'
tasks and documents are in the open while the chief still answers in
one voice (the synthesis lands as `docs/brief.md`). And officer
deliverables are **documents in the project** —
`projects/<project>/docs/*.md`, one file per deliverable, the path in
the task notes — because a recommendation that lives only in a chat
message is not a deliverable. The General Counsel role states in every
deliverable that it is an AI, not licensed counsel, and names which
points need a real lawyer.

```sh
pasclaw team up executive-team --goal "prepare our seed fundraise"
```

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
6. **Turns review on for the board** (unless the template opts out), with
   the template's reviewers. See [Review](#review-the-board-holds-the-rule).

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

## Review: the board holds the rule

The role prompts used to say "claiming done without evidence is the one
prohibited move" and "have the test engineer verify before you close it",
and nothing stopped either. On a team's board the **store** holds the
rule now, so no route to the board skips it
([plan](./team-board-plan.md), Phase 1):

```
task action=submit  project id evidence        builder: todo/active -> review
task action=verdict project id verdict=accept  reviewer: review -> done
task action=verdict project id verdict=reject reason
                                                reviewer: review -> active
```

- **An agent never marks its own work done.** `task update status=done`
  from an agent is refused with the `submit` it should have been, and a
  finished job (`task action=job status=done`, or the desktop's job
  runner) *submits* the task instead of closing it, with the job's
  summary as the evidence.
- **A submission needs evidence** — what was run and what it printed —
  and is recorded with who submitted it, when, and from which job.
- **The verdict is someone else's.** Refused from the submitter, from the
  task's owner, from anyone not on the reviewer list, and from a caller
  that cannot be identified: the caller is the agent whose turn is
  making the call (the same per-thread identity `agent action=send`
  uses), and a turn that is not a standing agent's — the desktop chat, a
  background subagent — is *not* treated as the operator. The refusal
  names who can give the verdict instead.
- **A reject needs a reason**, goes back to `active` with the same owner,
  and the reason is appended to the task's notes. The builder is
  messaged, which wakes it; the reviewers are messaged on a submit for
  the same reason. A task in review is not its builder's to move — only
  a verdict moves it.
- **Who reviews** is the template's `review.by` (`software-team`: `qa`).
  Without one, the submitter's `parent` reviews — in `duo`, the Foreman
  reviews the developer. A submitter is never its own reviewer, even when
  listed: the Test Engineer's own work goes to *its* parent.
- **The operator can do anything** — close a task in review, send it
  back, edit frozen criteria — from the desktop's **Accept** / **Reject**
  buttons, `POST /v1/projects/<p>/tasks/<t>/verdict`, or a `PATCH`. A
  person is the authority the review exists for, and every override is
  recorded as theirs.

**Criteria** are a task field of their own, one check per line, apart
from the notes. The Product Manager writes them while the task is
`todo`; once work starts they are **frozen** for agents ("reopen it —
status todo — to change them"), and a builder never writes the criteria
for its own task. The verdict is judged against them, and the `verdict`
result lists them back so a reviewer that skipped one is visible in its
own transcript.

**Held-out checks on submit.** Executables in
`$PASCLAW_HOME/scenarios/<workspace>/<project>/` (the
[verification](./configuration.md) scenario format: `*.sh`, `*.py`,
anything executable; run by name order, with the project directory as
the working directory) run before a submission is accepted. A red one
refuses the submit with its output, so work the operator's checks
already reject never costs a reviewer a turn. They live outside the
workspace for the reason verification scenarios do: a check the builder
can open is a check it can "fix". No directory, no gate.

**Receipts.** Every create, assign, start, submit, accept, reject,
reopen, criteria change and direct status change is a line in
`projects/<p>/activity.jsonl`, written by the store so the HTTP routes
and the desktop are recorded alongside the tool. `GET
/v1/projects/<p>/activity[?task=T0004&limit=50]` serves it, and the
desktop shows a task's history when its row is expanded.

**The file tools cannot go around it.** `task.json`, `job.json`,
`project.json` and `activity.jsonl` are refused to every file-writing
tool (whatever `restrict_to_workspace` says) with a pointer to the task
tool; the app the team builds and a job's `artifacts/` stay writable.
What this does not reach is `shell_exec`, whose writes cannot be
path-checked reliably.

A template opts its board out with `"review": false`; a project made by
hand or by the desktop's Ask path does not require review unless you
switch it on (`POST /v1/projects/<p>/review {"review":true}`), so one
person building one app sees no change.

## Needs you: one queue for your calls

Some things only a person can decide — spend money, pick between two
designs, hand over a key. An agent asks with `agent
action=ask_operator` (a `question`, optional `choices`, optional
`project` and `task`):

- **Only the top of the chain asks you.** An agent with a `parent` has
  its question delivered to the parent's mailbox, marked
  `[escalation]`; the parent decides, or asks in turn. The tool holds
  this, not the role prompt, so twelve working agents still produce only
  the questions their leads could not answer.
- A top-level agent's question becomes a **decision**:
  `workspace/decisions/D0012.json` — who asked, the question, the
  choices, the answer and who gave it. A question about a task **blocks
  the task** until it is answered, with a note saying what it waits on.
- **Needs you** on the desktop taskbar appears whenever something waits
  on you and counts it: open decisions, the gateway's pending permission
  `ask` requests (which had no window before), and tasks in review that
  no agent can give the verdict on. The window answers all three.
- **Off the desk.** With `decisions.channel` naming one of your
  configured channels, a new decision is posted there too. A reply of
  `D12 yes` in a chat with any of PasClaw's bots answers it — **only**
  from a sender listed in `decisions.answer_from` (`"telegram:12345"`);
  everyone else's reply is refused with the reason. `allow_senders`
  alone is not enough: an empty one lets anyone talk to the bot.
- **The answer** reaches the asker's mailbox (*"Operator decided D12:
  yes"*), which wakes it under the mail rule, and the task it blocked
  goes back to what it was doing. With choices, the answer must be one
  of them; a decision is answered once.
- Decisions are on the same footing as the board's records: the file
  tools cannot write them, so an agent cannot answer its own question.

`GET /v1/decisions[?open=1]`, `POST /v1/decisions/<id>/answer
{"answer":"yes"}`, and `GET /v1/needs-you` (open decisions plus reviews
only you can give) are the HTTP side.

## The wake loop

The gateway ticks every 30 seconds and, for each team whose own cadence
is due (`wake_minutes`, default 15):

- **supervises** — restarts runs whose process died;
- **reports stalls to the lead** — a task active with no progress for
  two cadences, whose owner is idle, produces a message to the
  *Foreman*, not another poke at the stuck worker. Waking a stuck worker
  repeats the stall; telling its manager is what unsticks it;
- **hands back expired claims** — see *Leases* below;
- **wakes agents that have a reason to run** — pending messages, *ready*
  tasks assigned to them, ready unassigned work for an agent that takes
  from the pool, or tasks **waiting for their verdict**. A task
  in review wakes its reviewer, not its owner: it is not the owner's to
  move. An agent with nothing to do is left alone: a loop that burns a
  provider call per agent per tick to be told "no news" is a bill, not
  a team;
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

**Work that waits on other work says so.** A task's `waits_on` lists the
tasks it needs (`task action=update waits_on=["T0002"]`). It is
**ready** when every one of them is done — computed, not stored, so it
cannot go stale — and only a ready task wakes its owner. When the last
prerequisite closes, the board messages the dependent's owner, which
makes the team due on the next tick. An edge to a task not on the board,
to itself, or one that would close a cycle is refused when it is set.
`blocked` stays for waits outside the board ("needs the operator's API
key"). The Foreman stops being the scheduler: nobody has to remember to
unblock anything.

**`task action=next`** is how a worker takes work: it claims the oldest
ready `todo` task assigned to the caller, or — for an agent whose
template says `"takes": "any"` — the oldest ready *unassigned* one. The
scan and the claim happen under one lock, so two agents asking at once
get two different tasks, or one of them hears *nothing is ready* with the
reasons (what its own tasks wait on, what it already holds). The claim
makes the task active and the caller's, with a **lease**.

**Leases.** An agent that starts or claims a task holds it for
`teams.claim_lease_minutes` (default 120); the owner touching the task —
any update, a note — renews it, and the task leaving `active` drops it.
On each tick, an active task whose lease ran out **while its holder runs
no turn** — the same turn-lock test supervision uses to spot a dead run,
so a long legitimate turn is never cut — goes back to `todo` with an
`expire` receipt, back to the pool if it was claimed from there, and the
lead is told. Before, a task held by a dead run waited for the stall
report two cadences later and for the lead to do something.

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
  That notice is the only thing the pause writes anywhere; nothing is
  queued for the agent to read later. An earlier version did push a
  "wind down" note into each busy agent's steering queue, and it had to
  go: a turn drains its queue at the top of an iteration, *after* the
  boundary check, so once the flag is set the next boundary cancels the
  turn before the next drain. The note could never reach the turn it
  was written for — it sat there until the operator resumed, and the
  resumed turn read "stop, do not pick up another task" as fresh
  instruction and stood back down.
- **Supervision respects it too.** `POST /v1/agents/supervise` restarts
  agents, and restarting is starting a turn, so it refuses with 409
  while paused. Pass `{"dry": true}` to see the verdicts without acting
  — the desktop's **Supervise** button does that automatically when the
  system is paused, and reports "would restart: …".
- **The pause is on disk.** A gateway restart cannot quietly resume a
  system the operator stopped — of the ways this could fail, that is
  the one that would matter most.

**Removing** has two grains. A single agent: the **Retire** button on
its roster row, or `DELETE /v1/agents/<name>`. A whole team:
`DELETE /v1/teams/<name>` or `pasclaw team rm`. Both keep the
**conversation** and the **project** — a conversation is not garbage
because the role that held it was retired, and the work the team did is
the operator's, not the team's.

Retire is refused while anyone involved is **mid-turn** — pause first,
then retire once the turn has stopped. For a team the check runs over
every member *before* anything is deleted, and the refusal names who is
still working: a half-retired team is worse than one still standing.

A team's roster for this purpose is its template's **agent list**, not
its wake list. Those differ the moment a custom template names a subset
in `wake.who` on purpose — a reviewer meant to run only when work is
handed to it, say — and retiring off the wake list would leave the rest
of the team sitting in the roster while reporting the team retired.

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
      "parent": "boss", "takes": "any" }
  ],
  "kickoff": "Goal: {{goal}}  Project: {{project}}",
  "wake": { "minutes": 15 },
  "review": { "by": ["boss"] }
}
```

`takes` is `"routed"` (the default: only what is assigned to it) or
`"any"` (it may also claim unassigned ready work with `next`).
`review.by` must name agents in the template; leave it out and each
submitter's parent reviews. `"review": false` (or `{"required": false}`)
leaves the board without review.

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
