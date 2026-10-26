# The team board holds its own rules

[Teams](./teams.md) and [standing agents](./agents.md) give PasClaw an
organisation: roles, reporting lines, a task board with owners, a mailbox,
a wake loop. What they do not give it is a rule the system *holds*. The
role prompts say "claiming done without evidence is the one prohibited
move" and "have the test engineer verify before you close it", and nothing
stops either from happening:

- any agent can set its own task to `done`, and `task action=job
  status=done` closes the task as a side effect (`Tool_Task`,
  `PasClaw.Projects.Tools`) -- the default path for a well-behaved run is
  to mark its own work finished;
- acceptance checks live in the task's `notes`, which the builder can
  edit after it has started;
- a dependency is a `blocked` task with a sentence saying what it waits
  on, and someone has to remember to unblock it;
- "report it to the operator" is prose in the lead's transcript; nothing
  collects the questions only a human can answer.

[Pullboard](https://pullboard.dev) is a work board for coding agents built
on the opposite premise: every rule is held by a mechanism, and breaking
one is refused on the spot with the rule's name and the next step. Its
core moves -- a second agent's verdict, a criterion frozen at claim,
dependencies that order the work, one queue for the human's calls,
repeated mistakes turned into proven rules -- map onto pieces PasClaw
already has. This plan brings them over.

**Where we enforce.** Pullboard enforces with git hooks because it does
not own the agent; that is also why it needs a doctrine rule saying
"never bypass a hook". PasClaw owns the tool loop, so every rule here is
held at **tool dispatch** -- in the `task` tool, the permission check, the
store -- where a model cannot skip it with `--no-verify`. It also means
team projects need not be git repositories, which most of them (a
`projects/<name>/app/` folder) are not.

## Not taken

- **Commit-message citations and git hooks.** See above.
- **Relay** (an end-to-end-encrypted mirror so agents on several machines
  share a board). The gateway already is the one board, reachable over
  HTTP with a token, `--attach` (#613) makes a remote terminal its client,
  and the channels reach a phone. Phase 3 uses those.
- **Light work to lighter models.** Team templates already pick model
  tiers per role, and the auto-router exists.
- **Blueprints** (starter rule sets per project type). A later extension
  of team templates, once Phase 4 has given a template something to
  carry: rules plus seed scenarios.

## Phase 1 -- a second agent's verdict, frozen criteria, receipts

One PR. It changes the fewest moving parts and everything after it builds
on the record it starts keeping.

### Review is a state, and the builder cannot leave it

`TTaskStatus` gains `tsReview` (persisted as `"review"`; appended to the
enum so existing ordinals and stored strings are untouched). Three new
`task` actions:

```
task action=submit  project id evidence      builder: active -> review
task action=verdict project id accept note   reviewer: review -> done
task action=verdict project id reject reason reviewer: review -> active
```

- **`submit`** records who submitted, when, the evidence (what was run,
  what it printed), and the job and session it came from.
- **`verdict` refuses the submitter.** The caller is the agent whose turn
  is making the call -- the same per-thread identity `agent action=send`
  already uses (`SetCallingAgent` / `GCallerAgent` in
  `PasClaw.Agents.Tools`, set by the agent runner around a turn). The
  refusal names who can verify instead: *"T0004 was submitted by dev;
  another agent must give the verdict -- qa reviews this team's work."*
- **`reject` needs a reason** and puts the task back to `active` with the
  same owner; the reason is appended to the task where the builder reads
  it, and the builder is woken. **`accept`** closes it.
- **Which projects require review.** A project gains `review: true`.
  `team up` sets it on the board it creates or binds; a project made by
  hand or by the desktop's Ask path does not, so a single user building
  one app sees no change. In a reviewed project:
  - `task update status=done` from an agent is refused with the
    `submit` it should have been;
  - `task action=job status=done` submits instead of closing;
  - the **operator** -- a call with no calling agent: the desktop, the
    HTTP `PATCH /v1/projects/<p>/tasks/<t>` route, the CLI -- can still
    close anything. A human is the authority the review exists for, and
    a person blocked by their own board is the wrong failure. The
    override is recorded as theirs.
- **Who reviews** is the template's: a new optional `review.by` list of
  agent slugs (`software-team`: `qa`; the shipped Code Reviewer role when
  a template includes it). Without one, the submitter's `parent` reviews
  -- in `duo`, the Foreman reviews the developer. A submitter is never
  its own reviewer, even when it is listed.
- **The wake loop** wakes a task's reviewers while it is in `review`, not
  its owner (`TeamWakeDecisions`), and `TeamBoardDone` does not count a
  task in review as finished.
- **Parallel dispatch.** `GCallerAgent` is a threadvar set on the run's
  loop thread. `task` is a mutating tool, so it dispatches as a batch of
  one; Phase 1 checks that such a batch runs where the threadvar is set,
  and if it does not, carries the caller into the dispatch the way
  `Cfg.Workspace` already is carried into parallel workers. A verdict
  that cannot tell who is calling must refuse, never default to allow.

**Green at submit.** When a project has held-out scenarios
(`projects/<p>/scenarios/`, the same format as `verification.scenarios`
from #618, run by `RunScenarios`), `submit` runs them first and refuses a
red set with the failing output: work the operator's checks already reject
never reaches a reviewer. A project without scenarios submits as above.

### Criteria freeze when the work starts

`TTaskInfo` gains `Criteria`: the acceptance checks, one per line,
separate from `notes`. They can be written while the task is `todo`. Once
it is `active` -- someone has started -- an agent's edit is refused:
*"T0003 is active; its criteria are frozen. Reopen it (status todo) to
change them."* Reopening clears the owner, which is the point: the bar
moves only when the work is handed out again, not while someone is
working to it. The operator can always edit, recorded as theirs.

The verdict is judged against the frozen criteria: the reviewer's role
says so, and the `verdict` result lists them back so a reviewer that
skipped one is visible in its own transcript. The Product Manager's role
changes from "2-4 acceptance checks in the notes" to the `criteria`
field.

### Receipts

`projects/<p>/activity.jsonl`, append-only, one line per event:

```json
{"at":"2026-10-27T10:04:11Z","task":"T0004","event":"reject","by":"qa",
 "submitted_by":"dev","job":"J0002","reason":"empty title saves a row"}
```

Events: `create`, `assign`, `start`, `submit`, `accept`, `reject`,
`reopen`, `status` (a direct change, with who made it). Written by the
store functions, not the tool, so the HTTP route and the desktop are
recorded too. `GET /v1/projects/<p>/activity` serves it; the board's task
detail shows the history, and a reviewed task shows its verdict.

### Desktop

A `review` badge and colour on the board; the task detail shows the
submission's evidence and the verdict. The checklist mirror
(`desktop.html`, which reconciles a checklist with task statuses) treats
`review` as not-yet-done and must not flip it back to `todo`.

### Tests

- `task` tool: submit → review; verdict by the submitter refused, naming
  the reviewer; accept → done; reject without a reason refused, with one
  → active and the reason on the task; in a reviewed project an agent's
  `done` is refused and `job status=done` submits; in a plain project
  both behave exactly as today; the operator can close anything.
- Criteria: editable while todo, refused once active, editable again
  after reopen (which unassigns).
- Activity: each of the above leaves its line, attributed.
- Teams: a task in review wakes its reviewer and not its owner; a board
  with a task in review is not done.
- Scenarios: a red project scenario refuses `submit` with its output.

## Phase 2 -- dependencies, and "next"

- **`waits_on`**: a task lists the tasks it needs (`["T0002"]`). It is
  *ready* when every one of them is `done`. Ready is computed, not
  stored, so it cannot go stale; a cycle is refused when the edge is
  set. `blocked` stays for waits outside the board ("needs the
  operator's API key").
- **The wake loop** only wakes an owner for a *ready* task, and accepting
  a prerequisite makes its dependents' owners due on the next tick. The
  Foreman stops being the scheduler: no "mark blocked, remember to
  unblock".
- **`task action=next`**: claim the oldest ready task assigned to the
  caller, else -- when the caller's role takes unrouted work (template
  `takes: "any"`, default `"routed"`) -- the oldest ready unassigned one.
  Under the store lock, so two agents asking at once get two different
  tasks or one gets "nothing ready". The claim sets the owner and
  `active`, and writes a **lease**.
- **Leases.** A claim lasts `teams.claim_lease_minutes` (default 120).
  The tick finds active tasks whose lease ran out and whose owner holds no
  turn -- the same turn-lock test supervision already uses to find a dead
  run -- and puts them back to `todo` with an `expired` receipt and a
  message to the lead. Today a task held by a dead run waits for the
  stall report two cadences later and for the lead to do something; this
  frees it.

## Phase 3 -- one queue for the human's calls

- **`agent action=ask_operator`** (question, optional choices, optional
  task) creates a decision: `workspace/decisions/<id>.json` with who
  asked, the question, the answer, and when.
- **Only the top of the chain asks.** An agent with a `parent` that calls
  it has its question delivered to the parent's mailbox instead, marked
  as an escalation -- the parent decides or escalates. Pullboard's
  "questions go up the chain, and only your decisions reach you", held by
  the tool rather than asked of the role.
- **Needs you** in the desktop: a taskbar badge and a panel listing open
  decisions, together with the permission `ask` requests from #611, so
  there is one place for everything waiting on a person.
- **Off the desk.** A new decision is also sent through the configured
  channels (`send_message`, Telegram, ...). A reply that names the
  decision (`D12 yes`) answers it there.
- An answer reaches the asking agent's mailbox (*"Operator decided D12:
  ..."*), which wakes it under the existing mail rule, and unblocks the
  task it was attached to.

## Phase 4 -- a repeated cause becomes a proven rule

- A `reject` verdict carries a **cause**: a short key the reviewer picks
  (`untested-empty-input`, `wrong-path`), normalised to a slug and kept
  in the activity line.
- **Noticing.** When one cause rejects work twice in a project, the lead
  gets a message: the cause, the tasks, and the call that drafts a rule.
- **A draft needs proof.** `rule action=draft cause script` takes a
  scenario script (Phase 1's format) and must show it **fails** against
  the rejected submission and **passes** against the accepted fix.
  "Against" means a snapshot of the project at that point: a git
  worktree of the two commits when the project is a repository, else the
  checkpoint snapshot taken for that turn. A draft without that proof is
  refused, as Pullboard refuses it.
- **You decide.** The draft waits in Needs you. Approved, it joins
  `projects/<p>/scenarios/`, and from then on every `submit` is held to
  it by Phase 1's gate. Declined, the decline is recorded so the same
  cause does not nag again.
- The operator can write a rule directly with the same tool; it still
  needs the proof.

This is the piece most likely to change shape when it is built: proving
against snapshots of a non-git project is the open question, and it
should be settled before the rest of the phase.

## Phase 5 -- lanes

- A template agent may name a **lane**: path globs it owns
  (`"lane": ["projects/{{project}}/app/**"]`).
- The permission check gains an agent dimension: a file-mutating call
  from an agent with a lane, on a path outside it, is refused with whose
  lane it is in -- *"outside dev's lane: projects/x/docs/plan.md is pm's;
  message pm instead"*. The rule engine from #611 is where it goes; the
  calling agent is the same per-thread identity as Phase 1.
- Lanes bind the **file tools**. A shell command's writes cannot be
  path-checked reliably, and the plan says so rather than pretending. For
  a git-backed project the stronger form is a worktree per lane
  (`worktree_create`, #612), where a stray write lands in the agent's own
  checkout.

## Measuring it

A team run on the relay harness (`bench/ragbench`): a `duo` whose
scripted developer submits work that misses one criterion.

| | today | with Phase 1 |
|---|---|---|
| the task ends | `done`, with the bug | rejected with the reason, fixed, accepted |
| who said it was done | the developer | the Foreman, against the frozen criteria |
| what the board can show afterwards | a status | the submission, the verdict and why |

The cost to report is the extra turns and bytes of the review loop, the
same way `VERIFY.md` reported #618's.

## Phases

1. **Verdicts, frozen criteria, receipts** -- `review` state, `submit` /
   `verdict`, `review: true` on team projects, `criteria`,
   `activity.jsonl`, the scenario gate on submit, desktop badge. One PR.
2. **`waits_on`, `next`, leases.**
3. **Needs you** -- `ask_operator`, escalation to the parent, the panel,
   channels.
4. **Rigor** -- causes on rejects, the twice-rule notice, proven drafts,
   approval into the project's scenarios.
5. **Lanes** -- per-agent path scopes in the permission check; worktree
   per lane for git projects.

Open questions to settle before Phase 1 is built:

- Review on by default for team projects, off for everything else -- the
  recommendation above.
- In `duo`, the Foreman reviews the developer: acceptable, or should
  `duo` get a third, cheap reviewer role?
- The operator may close any task, recorded: the recommendation, against
  "operators submit too".
