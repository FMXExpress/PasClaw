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

## What this does not do yet

- **Nothing runs an agent.** A message reaches an agent the next time
  *something* runs a turn on its session. Scheduling, long-running
  autonomous work, and delegation depth are Phase 3.
- **No supervision.** Nothing restarts a wedged agent or notices one has
  stopped answering. Phase 4.
- **A cycle in `parent` is not detected** beyond an agent reporting to
  itself. Delivery never walks the parent chain, so a cycle costs a
  confusing org chart rather than a hang.
