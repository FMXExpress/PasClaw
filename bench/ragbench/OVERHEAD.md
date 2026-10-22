# ragbench / overhead — PasClaw's own time per turn

Third run of the improve-mode loop against PasClaw's building ability
(see `docs/agent-loop-plan.md`), for the runtime's own cost per turn: the
time between the model's answer and the next request it receives, with a
model that answers instantly. The harness is `run.sh` with `worker.py`,
whose per-turn log carries `gap_ms`; `probe.py` polls `/v1/relay/status`
to split a gap into before-enqueue and after-enqueue.

## Results (2026-10-22, six-turn RAG task, identical decisions)

| | wall for 6 turns | gap per turn |
|---|---|---|
| before | 12.2 s | 2,012 / 2,014 / 2,012 / 2,021 / 2,113 ms |
| after | 0.1 s | 0 / 0 / 1 / 1 / 1 / 102 ms |

The 102 ms on the last turn is the test run plus ingest/query inside
`shell_exec`, which is the task's own work. Project files byte-identical.

## Profile

- The gap was the same 2,012 ms whether the tool was `list_dir`,
  `write_file` or `shell_exec`, so not tool work.
- `/v1/relay/status` showed `pending` never above 0 and `inflight`
  flipping to 1 only at the end of each gap: the request was enqueued
  and dequeued within 10 ms. The 2 s were spent **before** enqueue, inside
  the agent loop.
- `strace -f -tt -e nanosleep` on the gateway during a run: one thread
  slept 25 ms exactly 80 times per gap. `LOCK_SPIN_MS = 25` and
  `LOCK_MAX_WAIT_MS = 2000` in `PasClaw.Agent.Steering`.
- The loop drains the steering queue at every iteration top.
  `DrainSteering` took its `mkdir` lock before checking whether a queue
  file existed. In a home nobody had steered, the steering directory did
  not exist, `CreateDir` on the lock path failed with ENOENT on every
  spin, the stale-lock check could not run, and the wait ran out at
  2,000 ms. Every iteration, every session, on the gateway, the CLI and
  the TUI, until the first `pasclaw steer` created the directory.

## Improve

`DrainSteering` returns before locking when no queue file exists (a file
that appears afterwards is drained next iteration, which is what a
contended lock already did). `AcquireLock` creates the steering directory
first, so a real push/drain from a fresh home contends instead of
failing. Pinned by `steering_fastpath_tests`.

## What the measurement does not cover

A relay model that answers instantly; with a real provider the per-turn
cost is dominated by inference and this 2 s was hidden inside it, which
is why nobody saw it. Tool work is not in the gap (the last turn's 102 ms
is real). Homes that had been steered at least once never paid it.

## Next

With the gap at the millisecond level the runtime loop has reached the
point where the remaining time is necessary work. The plan's next
candidate is independent verification (`docs/agent-loop-plan.md`, #2).
