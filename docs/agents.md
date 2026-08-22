# Standing agents

A **subagent** is a call: the parent spawns a specialist, the specialist
answers, it is gone. A **standing agent** is the other shape — a name, a
role, and a conversation that outlives the process. It is what you need
for an organisation rather than a fan-out: a lead that still exists
tomorrow, a project lead you can message on Thursday about what it did on
Monday.

This is Phase 1 and 2 of the multi-agent plan: the roster, and the mailbox
agents reach each other through. Scheduling — deciding *when* an agent
runs — is Phase 3 and is deliberately not here.

## An agent is three files, and two of them already existed

```
workspace/agents/<name>/agent.json      the manifest
workspace/agents/<name>/messages.jsonl  what it was told, append-only
sessions/agent-<name>.json              its conversation
```

The session is a **real session**, not a private store. `pasclaw resume`,
the Library window, session export, the append-only transcript record and
the per-session turn lock all work on an agent with no special-casing
anywhere — because an agent's conversation is an ordinary conversation
whose id happens to start with `agent-`.

That is also what makes an agent durable in the sense that matters:
`pasclaw` can restart underneath it and the agent is still there, still
knowing what it was doing. A background subagent cannot survive that by
construction — its jobs "live and die with the session".

| Field | Meaning |
|---|---|
| `name` | the slug, and the directory; `[a-z0-9-]`, bounded, never a traversal |
| `title` | human label |
| `role` | what this agent is for |
| `model` | model override; empty inherits whatever the runner uses |
| `parent` | the agent it reports to; empty is top level |
| `created` / `updated` | `created` is preserved across updates — an agent's age is part of what it is |

Creating is **idempotent on the slug**: the same contract `CreateProject`
has, for the same reason — an agent re-running its own setup step must not
fail the job.

## Messages: one queue, two honest wordings

`AgentSend` is the point of Phase 2. There are two situations and one
mechanism:

- the target is **mid-turn** → the message lands in its steering queue and
  it sees it *between tool iterations*, without waiting for the turn to end
- the target is **idle** → the same queue holds it, and its next turn
  drains it as the first thing it reads

One mechanism because [steering](./configuration.md) already **is** a
durable append-only queue with a directory mutex and stale-lock recovery.
Writing a second one would have been writing the same file format with
fewer tests behind it. What differs between the two cases is only what we
can honestly tell the sender — so the reply says `mid-turn` or `queued`
rather than "sent" both times, and adds a sentence explaining what that
means for when the agent will act.

Liveness is read from the session's **turn lock** (`TryEnter`), not from a
status flag. The lock is already the truth; a flag would be a second copy
of it that can disagree.

Every message carries its sender in the envelope — `Message from <who>:
…`. Steering folds text into the system prompt, and an unattributed
instruction arriving mid-turn is exactly the shape a prompt injection
wants.

### The record outlives the queue

`messages.jsonl` is the accountability half. The steering queue is
**consumed** on drain, so without a record "who told whom what" survives
only inside whichever transcript happened to fold it in. Every send is
appended there *before* it is delivered, and the append is what is
checked: a message we delivered but cannot account for is the worse
failure of the two.

## The `agent` tool

Off by default, behind its own flag:

```json
{ "agent_tools_enabled": true }
```

Separate from `desktop_tools_enabled` rather than folded into it: that
flag answers "may the model manage the project board", this one answers
"may the model create colleagues and message them", and an operator can
reasonably want either without the other.

```
agent  action = list | create | get | delete | send | inbox
```

`list` and `get` report **live** `busy` and `pending` alongside the stored
fields — a roster without those is a list of names.

Deliberately **not** in the tool: starting a turn on another agent's
behalf. Delivery and execution are different questions, and an agent that
could make another agent run would need a scheduling policy to stop two of
them driving the same session at once. The turn lock serialises turns; it
does not decide who may start one. Phase 3 owns that.

## HTTP

| Method | Path | Purpose |
|---|---|---|
| GET/POST | `/v1/agents` | roster / create |
| GET/DELETE | `/v1/agents/<name>` | inspect / retire |
| POST | `/v1/agents/<name>/send` | `{"from":"…","text":"…"}` |
| GET | `/v1/agents/<name>/messages` | the durable record |

This surface is **not** behind `agent_tools_enabled`. That flag governs
what the *model* may do; a person driving their own gateway is a different
actor asking a different question — the same distinction the Calendar's
cron button documents. A message that arrived over HTTP is
indistinguishable from one an agent sent: same queue, same record.

Retiring an agent removes its manifest and record and drops anything still
queued — an undeliverable message should not wait to be folded into
whatever future conversation reuses the name. The **session is left
alone**: a conversation is not garbage because the role that held it was
retired.

## Running an agent

```
POST /v1/agents/<name>/run    {"prompt": "..."}   # prompt optional
```

The turn runs on a background thread, against the agent's **own
session** — it loads the stored conversation, runs under that session's
turn lock, drains the mailbox through the steering key, and files the
result back. That is what makes an agent something you can message on
Thursday about Monday; a stateless turn would answer with no memory of
either.

`prompt` is usually absent. An agent woken with nothing to say is told
to check its messages and carry on — and the messages arrive through the
steering queue like any other, so a woken agent is never shown the same
instruction twice (once as the user turn and once as a note).

**A second run is refused, not queued.** The turn lock would serialise it
safely, but "safely" there means the caller waits an unknown time for a
thread it cannot see. An agent that is already working does not need to
be told to work — it needs to be *told something*, which is what the
mailbox is for and which reaches it mid-turn anyway. The refusal is a
409 and says exactly that.

Runs are capped at **8 in flight**. Unbounded, one supervision sweep over
fifty stale agents would open fifty provider connections at once and the
real limit would be the provider's rate limiter, discovered as failures.
The ninth is told to try again shortly, which a caller can act on.

Run state lives in the manifest — `run_state` (`idle`/`running`/`done`/
`failed`), `run_start`, `run_end`, `run_note` — because a process that
died mid-run must leave behind the fact that it *was* running. Nothing in
memory can tell a supervisor that.

## Supervision

```
POST /v1/agents/supervise   {"stall_minutes": 0, "idle_minutes": 0, "dry": false}
```

A route rather than only a timer, for two reasons: it is how the sweep is
tested without waiting out an interval, and it is how one agent
supervises another — a lead's turn can call it — rather than supervision
being a privilege only the process has. Two leads that are each other's
`parent` supervise each other, which is the shape the plan was written
for.

The verdicts are computed by a **pure** function (`SuperviseAgents`) that
reads state, decides, and reports without starting anything. `dry: true`
returns exactly what the acting pass would do.

| Verdict | When |
|---|---|
| `restart` | the manifest says `running` but **no turn holds the session lock** — the process that owned it is gone |
| `restart` | the last run `failed` |
| `restart` | `idle_minutes` set and the agent has not run in that long |
| `stalled` | running, lock held, but longer than `stall_minutes` — **reported, not killed**: something *is* working, and killing it loses whatever it has done |
| `ok` | everything else, including an agent that has never run |

The dead-run check is the only failure a supervisor can *actually*
detect, and it is exact: a live turn holds the lock, so `running` + free
lock is producible by nothing else. Checking the lock rather than the
clock is what stops a legitimately long run being declared dead.

The parent is told **before** the restart. A restart that works is still
news — the point of two leads watching each other is that the other one
knows — and a restart that fails to start would otherwise be silent.

## The roster (desktop)

**Start → Agents** opens the roster: every agent, its live state, how
many messages are waiting, and what its last run left behind. Rows carry
**Message** (into the mailbox, and it tells you *which* delivery
happened) and **Wake** (a turn now, disabled while it works).
Double-click opens the agent's conversation — an ordinary session
window — showing both what the agent said and what it was **told**,
because "why did it do that" is usually answered by a message somebody
sent it.

It repaints on the `agent` event rather than polling, so an agent that
starts working updates the roster with nobody touching anything. The
event carries only the name: run state and pending count are read live,
and an event that carried them would be stale the moment it was queued.

## What this still does not do

- **No scheduler.** Something must call `run` — an operator, a
  supervisor sweep, a cron entry. There is no "wake every 20 minutes"
  built in yet.
- **No delegation depth limit.** An agent with the `agent` tool can
  message any other agent, and nothing bounds how deep a chain of
  instructions goes. Message storms are possible; the run cap bounds the
  damage but does not prevent the traffic.
- **A cycle in `parent` is not detected** beyond an agent reporting to
  itself. Delivery never walks the parent chain, so a cycle costs a
  confusing org chart rather than a hang.
