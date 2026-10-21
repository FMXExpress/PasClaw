# ragbench / turns — model calls to build a RAG pipeline

The improve-mode loop run a second time against PasClaw's building
ability, this time for the lowest number of **turns** (model calls) to
accomplish the same task. Same gateway + relay-provider harness as
`run.sh`; the worker is `worker_turns.py`.

## How the worker decides

The five tool steps are fixed (list the directory, write `rag.py`, write
the test, write the sample doc, run the test plus one ingest/query), but
how many of them go into **one response** follows what PasClaw's prompt
says. Each policy is a substring test on the system prompt, auditable in
the request dumps:

| policy | licensed by | effect |
|---|---|---|
| `listing_in_prompt` | the Workspace section lists the directory (`Top-level entries:`) | the look-around `list_dir` turn is skipped |
| `batch_writes` | the rules say state-changing calls may share a response | the three writes go in one response |
| `in_order` | the rules say calls execute in listed order | the dependent `shell_exec` check rides in the same response, last |

That is the honest shape of "a model that reads the rules": a prompt that
never mentions batching writes gets one call per turn.

```sh
make
bench/ragbench/run_turns.sh turns-baseline      # prints turns=N and the per-turn sizes
```

## Results (2026-10-21, identical tool steps and outputs on every run)

| prompt | turns | request bytes |
|---|---|---|
| before: rule 7 only licenses batching reads; writes "split the batch" | 6 | 146,734 |
| rule 7 rewritten: every call in a response runs before the next model call, in listed order, so writes and their check can share one response | 3 | 72,902 |
| plus the Workspace section's one-line directory listing | **2** | **49,218** |

The project files (`rag.py`, `tests/test_rag.py`, `docs/sample.md`) were
byte-identical across the three runs and the test output the same.

## Profile that led here

Of the six baseline turns: one was a `list_dir` on a directory PasClaw
already knew (it is the sandbox workspace); three were writes whose
contents the model already had, sent one per turn because the prompt
only licensed batching *reads*; one was the test run, which depends on
the writes but can follow them in the same response because the loop
executes a response's calls in order (`PasClaw.Tools.ToolLoop`:
read-only calls form a parallel batch, each mutating call is a batch of
one, all before the next model call); one is the final answer, which no
change removes. Floor: 2.

## What the measurement does not cover

- A model that batches writes it is *not* sure about: the rule tells it
  to split only when a later call needs a result it has not seen. Whether
  real models apply that judgement well is a quality question this
  fixed-policy worker cannot see.
- Larger trees: the listing is capped at 40 names and shows the top level
  only, so a task deeper in a tree still needs a `list_dir`.
- The byte saving is a consequence of fewer turns on this profile, not a
  separate optimisation; `README.md` covers the per-request cost.
