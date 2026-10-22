# ragbench / verify — does "done" mean done?

Fourth run of the improve-mode loop against PasClaw's building ability
(`docs/agent-loop-plan.md`, candidate #2). The metric is the **false
success rate**: tasks the agent reports done that a check it never saw
fails. The harness is `run_verify.sh` with `worker_verify.py`.

## The setup

The worker's first draft of `rag.py` has a bug its own test does not
catch: `chunk()` ignores the overlap. Its test passes, so it reports done.
Two held-out scenarios live in a directory outside the workspace:
`01_chunk_overlap.py` (200 words, window 80, overlap 20 → three chunks,
the second starting at word 60) and `02_ranking.py` (the right document
ranks first). The harness always runs them itself afterwards as ground
truth. With `VERIFY=1` the gateway is also given the directory as
`verification.scenarios`, and PasClaw runs them after the model's final
answer, feeds failures back as one more user turn, and re-runs, for at
most `max_rounds` (2).

```sh
make
bench/ragbench/run_verify.sh verify-baseline          # scenarios only as ground truth
VERIFY=1 bench/ragbench/run_verify.sh verify-after    # PasClaw runs them too
```

## Results (2026-10-22)

| run | turns | request bytes | agent said | ground truth | `verification` field |
|---|---|---|---|---|---|
| before (no scenarios configured) | 2 | 48,136 | done, tests pass | chunk scenario **fails** | none |
| after (`verification.scenarios` set) | 4 | 101,340 | fixed, reported again | both pass | `ok: true, rounds: 2, passed: 2` |

Before: a false success, invisible to PasClaw and to the caller. After:
the first round reported 1 of 2 failed, the feedback named
`01_chunk_overlap.py` with its assertion message, the model rewrote
`chunk()`, the second round passed, and `/v1/chat` returned the outcome
beside the answer. The CLI prints the same line in green or red.

## Profile of the cost

Two extra turns: the fix (a write) and the final answer that triggers the
re-check. Both are necessary; a verified outcome cannot come from fewer
model calls than one fix and one answer. The scenarios themselves ran in
about 100 ms per round. Request bytes grew with the history (the previous
"done" and the feedback stay in it, so the model can see what it claimed).
No change was made in this pass.

## What the measurement does not cover

- A model that argues with the scenario instead of fixing the code. The
  feedback says "fix the cause, not the check" and names only the
  scenario's file name, never its path or body; the agent cannot read or
  edit what it cannot find, but a model could still give up. `max_rounds`
  bounds that.
- Scenario quality. A scenario that checks the wrong thing verifies the
  wrong thing; that is the operator's held-out set, and this harness only
  shows that PasClaw enforces it.
- Docker: scenario paths are host paths run through the active shell
  backend; a docker backend needs the directory bound into the container.

## Worker note

The worker first judged "did I already apply the fix" from its own earlier
tool-call arguments and looped: PasClaw trims large write arguments in the
history it replays, so the content is not there to grep. Judging from the
tool results after the feedback turn is the right shape, and a real model
would do the same from its own transcript.
