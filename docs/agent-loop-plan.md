# Improving PasClaw with its own loop

A plan for using the improve-mode method (benchmark, profile, improve,
verify, research) on PasClaw itself, with PasClaw as the subject and a
scripted "model" standing in behind the relay provider so every run makes
the same decisions and the measurement isolates PasClaw. The harness is
`bench/ragbench/` (request bytes, turns, and now per-turn wall time).

What the October 2026 field survey says the frontier is: not a smarter
model but better orchestration -- load less and the right things, execute
workflows instead of narrating steps, keep durable state and drop
replaceable clutter, spend computation selectively, verify independently,
and leave reusable procedures behind. Two of those PasClaw already has in
the architectural form (tool discovery via progressive disclosure, code
execution via Code Mode and `tool` inside `execute_code`). The rest are
candidates below, ranked by how cleanly the loop can measure them.

## Candidates

| # | Theme | PasClaw today | Metric | First change |
|---|---|---|---|---|
| 1 | **Runtime overhead per turn** | Unmeasured. Six turns took 12.3 s with a model that answers instantly: ~2 s per turn is PasClaw | Gap between the model's response and the next request it receives (`gap_ms` in the worker log) | Profile the gap; replace polling waits with event waits |
| 2 | **Independent verification** | Rule 3 asks the model to state what a check did not cover; the goal judge grades the agent's own transcript | False-success rate: tasks reported done that a scenario outside the workspace fails | `pasclaw build --scenarios <dir>`: held-out checks the agent cannot read or edit, failures fed back as one more turn, capped retries |
| 3 | **Selective computation** | `auto_router` by surface shape; `background_model` for distill, compaction, maintain | Share of calls on the cheap tier across a mixed task set, with #2 as the quality guard | A `decision_model` role with one typed call shape, used by the router, heartbeat triage, promptware, skill review |
| 4 | **Drop replaceable clutter** | Output cap, reversible condensation, compaction, pruning; nothing clears a re-fetchable tool result | Bytes per turn on a 15-turn task | Clear `read_file` / `grep_files` / `list_dir` results older than N turns to a one-line handle |
| 5 | **Experience becomes a skill** | Distiller proposes, operator approves | Turns on a second similar task after the first left a skill | Only after a baseline shows whether the distiller fires on build tasks |
| 6 | **Join a running session** | Attach mode shows a turn's result when it ends | Not a loop metric | Per-session SSE feed |

## Protocol

1. **Benchmark.** One fixed task, the playbook worker, the metric for
   this candidate. Record the exact command. Three runs when the metric
   is time; one when it is bytes or turns (those are deterministic).
2. **Profile.** Break the metric down until one component is both large
   and avoidable. Timestamps, request dumps, log lines.
3. **Improve.** Change one thing. If the profile points at two, build
   twice and measure each alone.
4. **Verify.** Same command, same inputs. Before and after, both numbers,
   and the project output diffed. State what the run did not cover.
5. **Research.** When the profile does not suggest a fix: the code path,
   the library's documented behaviour, what the other projects did.
6. **Repeat** from 2 with the new profile until the next component is
   either necessary or too small to be worth a change.

A change that does not move the number is reverted and said so.

## Chosen first: #1, runtime overhead

Cheapest to benchmark (no new code), a fixed cost paid on every turn of
every task, and each fix exposes the next hotspot, which is what makes
the loop repeat. Results go in `bench/ragbench/OVERHEAD.md`.
