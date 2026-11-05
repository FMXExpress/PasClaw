# A team, run live, with the model played by hand

The team board ([plan](../../docs/team-board-plan.md)) was built and unit-tested
rule by rule, and none of that says whether a team *works*: whether a lead
can hand out work, whether the work reaches the worker, whether a finished
task makes the next one move. That only shows when agents run turns. This is
the improve loop — benchmark, profile, improve, verify, research — run on a
real team, with the model played by an operator through the relay provider.

## Method

- `pasclaw serve --max-iter 60` on a throwaway `PASCLAW_HOME` whose provider
  is `relay`, with `desktop_tools_enabled` and `agent_tools_enabled` on and
  the auto-router off.
- The operator is the relay worker: `fh_relay.py` from the FrontierHarness
  driver (`scripts/frontier-eval/` on the `claude/frontier-harness-eval`
  branch, commit `31742e2`) holds the poll stream and answers each job
  (`next`, `respond --call … / --content …`). One change for a team: two
  agents' jobs interleave, so `next` shows the delta against the previous
  job **of the same agent** (keyed on the system prompt's first line —
  agent turns carry no `session_id`), not the previous job. The replay
  below (`replay.py`) needs none of this; it holds its own stream.
- `pasclaw team up duo --goal "Build wordcount.py … with unit tests in
  test_wordcount.py; python3 -m unittest must pass."` The team's cadence is
  lowered to 3 minutes in its state file so a cadence-driven wake costs
  minutes, not quarters of an hour; mail-driven wakes do not depend on it.
- The operator plays the Foreman and the 10x Developer from their role
  prompts and tool results, nothing else. Run 2 repeats run 1's decisions
  everywhere the harness did not force a different move — the same code,
  the same tests (including the Developer's wrong expectation, 12 for 11,
  and its fix), the same reviews (accept T0001; reject T0002 because
  "an empty *file*" was tested only as `count("")`; accept the fix) — so the
  difference between them is the harness, not the operator.
- Numbers come from the relay spool: every job verbatim, the daemon's
  receive times, and the answer markers' times.

What this measures: what the harness makes a model do — calls, bytes,
wasted moves, waits. What it does not: model quality (the operator is not
the model a user runs), and absolute latency of a model turn (the operator's
think time is in the wall clock; the waits below are measured between an
answer and the next job, which is harness time).

## Findings

Run 0 is the first attempt; runs 1 and 2 are the measured pair.

| # | what happened | why | fix |
|---|---|---|---|
| 1 | Run 0: the Foreman woke with no `task` tool; `tool_search` for it found only `desktop` and `spawn`. The team was "up". | the board tools sit behind `desktop_tools_enabled`; `pasclaw team up` never said so (the desktop's **New team…** did) | the CLI warned the same way at first; now a team's members always have the board and agent tools, and an ordinary chat asks you before using them ([teams](../../docs/teams.md#flags-none--it-asks)) |
| 2 | The Foreman's first move was `agent list` | the kickoff named the goal and the project, not the team | the kickoff names the team by assignable names |
| 3 | That one result was 8.25 KB, and stayed in the Foreman's history for every later call | `list` carried each agent's whole role prompt | `list` carries each role's first line; `get` has the rest |
| 4 | The Foreman created both tasks with `"assignee":"dev"`; neither had an owner | `create` read the assignee and dropped it, silently — the result did not mention it (an existing test had the same call and worked round it) | `create` takes `assignee` and says `(assigned to dev)` |
| 5 | `agent send {"to":"dev","message":…}` failed: *nothing to send* | the fields are `name`/`text`; the result answers with `"to"` | `to`/`message` accepted; the error names the fields |
| 6 | The Developer's progress note erased the Foreman's brief (the output format) | `update notes` replaced; every role is told to write its progress there | an agent's note is added under its name; the listing trims long trails |
| 7 | After T0001 was accepted nothing woke anyone — 4+ minutes and counting, the board not done, the team never parking | T0002 was ready and unowned; the wake loop offers unowned work only to takers, and `duo` has none | an unowned dependent tells the lead when it becomes ready; the tick reports ready unowned work to the lead after one cadence |
| 8 | The Foreman assigned T0002 and the Developer woke 162 s later | assigning tells nobody; the owner is found at the next cadence (15 min by default) | the board messages the new owner when it can start the task |
| 9 | In run 2 every handoff was mail, and still waited 2–30 s — 93 s of a 216 s run | the tick slept 30 s; mail skipped the team's cadence but not the sleep | queueing mail for an idle agent signals the tick, which runs the pass within a second (at most one mail-driven pass a second, so a pass that sends mail cannot spin); prompt-cache warming stays on the 30 s clock |
| 10 | Found while fixing 9: a stall report is mail, and mail makes a team due — so every due pass re-sent the report for as long as the lead had not acted (every 30 s before, every second after 9) | the reports ran on any due pass | reports, the done-board count and the cadence stamp move on cadence passes only; a pass mail brought forward is not a tick |

Finding 7 was verified live: the gateway was restarted on the stuck run's
home with the fix, and the next tick woke the Foreman with *"Task T0002 …
is ready and nobody owns it … Assign it"*; the run finished from there.

Every fix has a test (`team_board_tests`, `team_review_tests`,
`desktop_routes_tests`), and each was revert-checked — the fix undone, the
suite run, the failure seen — fourteen of fourteen caught. The CLI warning
was checked by hand against a home with the flags off and on; the tick
thread's loop, which no unit test reaches, by run 3.

## Numbers

| | run 1 (before) | run 2 (after) | |
|---|---|---|---|
| provider calls | 36 (Foreman 17, Developer 19) | **29** (12, 17) | −19% |
| request bytes | 1,320,953 | **955,870** | −28% |
| Foreman request bytes | 673,658 | **380,811** | −43% |
| tool calls | 31 | 25 | |
| error results | 1 | 0 | |
| wakes | Foreman 5, Developer 3 | Foreman 4, Developer 3 | |
| kickoff → board done | 20 m 22 s (with the stall, ended by a restart) | **3 m 36 s** | |

Handoff waits, from the answer that caused a wake to the wake's first job:

| handoff | run 1 | run 2 |
|---|---|---|
| Foreman assigns → Developer starts | 7 s (by message) | 13 s (the board's notice) |
| submit T0001 → reviewer | 23 s | 2 s |
| accept T0001 → Developer on T0002 | **never** (695 s with a restart and a cadence) | 20 s |
| … then assigned → Developer | 162 s (cadence) | — |
| submit T0002 → reviewer | 14 s | 7 s |
| reject → Developer | 11 s | 30 s |
| resubmit → reviewer | 13 s | 21 s |

### Run 3: the same answers, replayed with no think time

`make bench-teamboard` (`replay.py`) replays run 2's 29 answers
(`duo-wordcount.json`) through a fresh gateway, each the instant its job
arrives, and stops if a job's message count differs from the one it
replaces — the recording would no longer apply. With the operator's think
time gone, the wall clock is the harness's own. Two binaries that differ
only in the tick (finding 9):

| | 30 s tick (before 9) | mail-signalled tick |
|---|---|---|
| 29 answers, first job → last answer | **180.4 s** | **5.3 s** |
| each handoff (answer → the next agent's first job) | 29.5–29.9 s | 0.5–0.8 s |
| provider calls / request bytes | 29 / 947,030 | 29 / 947,030 |
| the board's own tests afterwards | pass | pass |

Request bytes are not quite deterministic: 947,030 on most runs and
949,783 (+0.3%) on about one in six, on the same binary — timing-dependent,
not yet traced. Compare runs on calls and waits; treat a byte delta under
0.5% as noise.

The 30-second figure is the worst case: answers that arrive instantly
phase-lock to the tick, so each handoff waits nearly a full slice. With a
real model's turn lengths the wait averages half a slice — run 2 measured
15.5 s per handoff. Either way it was most of a team's idle time, and it is
now under a second. (The first handoff can read as −0.0 s: the Developer is
woken by the board's notice while the Foreman's turn is still running.)

One wait the signal does not cover: mail queued by **another process** —
`pasclaw team up`'s kickoff, sent by the CLI — signals that process, not the
gateway, and waits for the next slice as before. The desktop's **New team…**
runs in the gateway and starts the lead's turn itself.

To re-record after a change that alters what an agent sees (the replay
says `DIVERGED`): run the team live as in *Method*, then turn its spool
into the fixture — one `{agent, messages, answer}` per job, in order.

Where a request's bytes go: tool schemas are 21.5 KB of a fresh 27.2 KB
request (79%), and 59% of every byte in run 1, 65% in run 2 — the fixes
cut the conversation, not the schemas, so the schemas' share grew. The
system prompt is 4–5.5 KB. The conversation is the rest, and it grows
across wakes because an agent's session persists: the Foreman's last call
carried 19.9 KB of it in run 1 and 9.6 KB in run 2 (no roster dump, fewer
calls).

## Run 4: a security sweep

The [Security Engineer](../../docs/teams.md#security-a-sweep-that-stays-fixed)
and [findings](../../docs/teams.md#findings) run the same way. The method
is the one above, with a different start: a seeded app, `notes`, with
three real holes. `search()` builds SQL with `%` formatting, so one
owner's search can return another owner's notes. `read_attachment()`
joins the caller's file name onto a folder, so `../notes.py` reads the
source. And a live API key is a constant in that source. The team was
`pasclaw team up security --project notes --goal "Sweep the notes app
for security holes and fix them"`, with the operator playing the Foreman
and the Security Engineer from their roles.

What happened, in order: the Foreman created the sweep task for `sec`.
`sec` read the app, grepped for sinks, and demonstrated both attacks
(Ann's search returned Bob's *secret plan*; the traversal returned the
source line holding the key). It filed three findings, each with its
kind as the cause and the attack as its criteria, and each was
snapshotted as filed (S0001). It submitted the sweep, then fixed the
holes one at a time, each with a test that sends the attack. The Foreman
reran every attack and test before each verdict. It asked the operator
to rotate the leaked key, an action outside the workspace, without
blocking the code fix on the answer. Each accepted fix brought the board's notice, and
`sec` drafted a check written to the hole's *kind*. All three were
**proven on the first draft**: each failed on the snapshot taken when
the finding was filed, quoting the vulnerable line, and passed on the
accepted fix. The operator approved them in Needs you, and the project's
held-out checks now gate every later submit.

Do the checks catch more than the line they were proven on? Each was run
on the fixed app, then on copies with a *new* instance of its kind put
back:

| the app | no-sql-from-strings | no-joined-path-open | no-secrets-in-source |
|---|---|---|---|
| as fixed | pass | pass | pass |
| plus a new `count()` with an f-string query | **FAIL** | pass | pass |
| plus a new `read_export()` opening a joined path | pass | **FAIL** | pass |
| plus a new `mail.py` holding a password literal | pass | pass | **FAIL** |

Findings:

| # | what happened | why | fix |
|---|---|---|---|
| 11 | `sec`'s first sweep call sent `grep_files` a regex alternation and got "no matches" | the role said *grep_files finds the sinks*; `grep_files` matches one literal string (its schema says so, and the role's wording won) | the role gives the one call that works: `shell_exec grep -rnEi '<sinks and secret names>' projects/<p>/app/` |
| 12 | then `shell_exec grep -E '…\|eval\(\|…'` was refused: *forbidden token "eval"* | the denylist splits on shell metacharacters, so a pattern's `eval` is a token, and a security sweep is the one job that has to search for it | the denylist stays as it is. The role searches `eval(` with `grep_files`, which runs no shell, and a test runs the role's command through `ShellAllowed` |
| 13 | the operator could not see or answer the team's decisions from the desktop: `GET /v1/decisions` and `/v1/needs-you` were **404** in a running gateway | `IsDesktopPath`, the list of paths the gateway hands to the desktop router, never had them; the route tests call the router directly | added, and a test walks every route the router answers through that list. This predates the security work and would have hidden every `ask_operator` and proven rule from the desktop |
| 14 | three approvals in the same second cost `sec` two wakes | the first approval started a turn that ended on its first call, and the notes delivered mid-turn carried over to a new turn | not changed: nothing was lost, and the cost is one call. Batching mail that lands together is the mailbox's question, not the board's |
| 15 | `rule list` showed `"causes": []` with three findings on the board | it listed only the causes that had rejected work | each cause lists its findings |

Not a finding: the agents' tool list had no `desktop` tool. That's by
design. The tool waits behind `tool_search` until a desktop subscribes to
the event feed, and none was connected.

| | run 4 |
|---|---|
| provider calls | 42 (Foreman 16, Security Engineer 26) |
| request bytes | 1,739,796 |
| tool calls / error results | 44 / 1 (the `eval` refusal) |
| findings filed, demonstrated, fixed, accepted | 3, 3, 3, 3 |
| checks drafted, proven at the first draft, approved | 3, 3, 3 |
| kickoff → last check proven | 7 m 38 s (the operator's think time included) |
| the same 39 answers replayed (`security-notes.json`) | **5.2 s**, handoffs 0.5–0.8 s |

`make bench-teamboard` replays both runs. This fixture carries the
seeded app, and it is **ordered**: answers go out in the recorded order
across agents. A check for a hole can only be proven after the Foreman
accepts the fix, and an instant replay would otherwise race past the
verdict. The replay checks the board is done, the app's tests pass, and
three proven rules are waiting. When a wake from the recording never
comes, it stops after 45 s and names it. With the finding side of the
proof undone, it reports `STALLED after 37 of 39 answers: no job for
Security Engineer`: the third notice never came. Every behaviour of the
security work and of these fixes was revert-checked, 25 of 25 caught,
including the bench's own.

## Research: what else is on the table

- **Schemas are the bulk.** 22 tools per agent turn, `task` alone 2.7 KB.
  `bench/ragbench` already deferred the long tail behind `tool_search`;
  a team member's surface is narrower again (a developer does not draft
  rules; nobody on `duo` needs `web_fetch`), so per-role tool sets are the
  next large cut. Not done here: hiding a tool is a behaviour change — a
  hidden tool is one the model stops choosing — and wants its own run.
- **Sessions persist across wakes.** That is the design (an agent picks up
  cold work from its own history), and it is also why the Foreman's 12th
  call carries its 1st call's results. Compaction exists; a team member's
  wake is a natural point to fold the previous turn into a summary.
- **The system prompt is not stable across calls**: 14 changes in run 2's
  29. Mail is folded in as a note (`[user steering received mid-turn]`) on
  the call it arrives with and gone on the next, and the progress ledger
  (`Files written/edited: …`) grows as a turn writes files. Both sit at the
  end, so the role text before them is a stable prefix; whatever a provider
  caches *after* the system prompt is not. Measured as a fact only — it
  predates the board, and changing it is a prompt-cache question for
  `bench/agentloop`, which owns that property.
