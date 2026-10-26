# ragbench — request bytes to build a RAG pipeline

The improve-mode loop (benchmark, profile, improve, verify, research) run
against PasClaw's own building ability. The metric is the lowest number
of request bytes (≈ tokens) PasClaw needs to accomplish one fixed task.

## What it measures

A scratch gateway runs the task through `POST /v1/chat` with the **relay
provider**; `worker.py` stands in for the model. It pulls every request
off `/v1/relay/poll`, records its size (system prompt, tool schemas,
history, tool results) and answers from a fixed playbook: list the
directory, write `rag.py`, write a test, write a sample doc, run the test
plus one ingest/query, then a final answer. The decisions are identical on
every run, so a before/after comparison measures PasClaw's overhead
(prompt, schemas, result verbosity, iteration count), not model variance.

```sh
make                              # build/pasclaw
bench/ragbench/run.sh baseline    # default gateway
NOMCP=--no-mcp bench/ragbench/run.sh baseline-nomcp
```

Output per run lands in `bench/ragbench/out-<label>/`: every request
envelope (`req-N.json`), `log.json` with the size table, the gateway log,
and the project the agent built. The script prints the table and the
session's stats.

## Results (2026-10-21, this harness, 6 turns, identical decisions)

| run | request bytes | visible tools | note |
|---|---|---|---|
| gateway `--no-mcp`, before | 228,556 | 36 | `--no-mcp` skipped the only call that registers `tool_search` and defers the long tail |
| gateway default, before | 156,064 | 19 | tools 15.7 KB of a 24.2 KB request (65%), system prompt 7.8 KB (32%) |
| after: four more tools deferred, `--no-mcp` fixed | **132,562** | 15 | same files written, same test output; `--no-mcp` now identical |
| after, on `main`, first cut (memory_write deferred too) | 128,710 | 15 | `--no-mcp`: 128,935 |
| **after, on `main`, final** (memory_write kept visible: rule 5 recommends it) | **136,942** | 16 | |

The before/after rows were measured on the opencode2 stack build (36 tools registered); the last row is the same change rebased onto `main`, which registers fewer tools, so its absolute number is lower.

### 2026-10-23: the set that shipped

Same harness, today's `main` against the PR as merged into it. `shell_background` and `memory_fetch` went back to visible: a hidden tool is one the model stops choosing (without `shell_background` it blocks in `shell_exec`), so only `desktop` joins the long tail, and the gateway reveals that one the moment a desktop connects. A desktop never connects in this harness, so `desktop` stays deferred here.

| run | request bytes | visible tools |
|---|---|---|
| `main`, default | 156,142 | 19 |
| `main`, `--no-mcp` | 228,634 | 36 |
| PR, `desktop` + `memory_fetch` + `shell_background` deferred | 140,872 | 16 |
| **PR as shipped, `desktop` deferred** (default and `--no-mcp` identical) | **150,160** | **18** |

Every run wrote the same five files and passed the same test. Keeping the two tools visible costs about 1.5 KB per request against the three-tool set. Against `main` the PR saves about 1 KB per request, and a third of every request under `--no-mcp`.

Profile of one request after the change: tools 11.8 KB, system prompt
7.8 KB (Rules 4.5 KB, Deferred Tools 0.7 KB), conversation 0.5 KB
growing to 3.8 KB by turn six. Tool results are already terse (`wrote N
bytes to <path>`). What the measurement does not cover: a task that needs
one of the deferred tools pays one extra `tool_search` turn (about 20 KB
on this profile), so a `db_`- or `spawn`-heavy task is not represented by
this number; nor is model quality, which a fixed playbook cannot see.

## Next candidates, by size

1. The Rules section (4.5 KB, 19% of a request) is re-sent every turn.
   Trimming it is a prompt-quality change that this harness cannot judge.
2. Fewer turns: the loop already dispatches several tool calls from one
   response in parallel; a model that batches the three writes would do
   this task in four requests instead of six.
