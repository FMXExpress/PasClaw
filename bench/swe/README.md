# SWE bench harness

A self-contained adapter that runs PasClaw against SWE-shaped tasks and
reports a Pareto frontier across settings. Same author/judge pattern as
`bench/locomo/` — the eval lives inside this repo, no external services
required for the harness to run end-to-end.

## What this measures

The **subject under test** is PasClaw's agent loop: system prompt,
tool surface, plan-mode gates, profile defaults, condenser, output-cap,
loop-shaping defaults. The **provider is held fixed across the sweep** so
any pass-rate delta is attributable to PasClaw settings, not provider
variance.

The bench is shaped after SWE-bench (real bug-fix tasks with a failing
oracle test) and Terminal-Bench v2 (operator workflows on a real
filesystem), per
[ArtificialAnalysis's coding-agents composite](https://artificialanalysis.ai/agents/coding-agents).
We do not vendor the public datasets — running them needs Docker + their
own license. Instead we ship a small **shape-matched fixture suite** of
PasClaw-shaped tasks; the architecture lifts directly to public benchmarks
in a follow-up by writing a fixture-loader that maps their schemas to
`manifest.json`.

## How it runs

```
                ┌──────────────────┐
                │   score.py       │  ← entry point, iterates the grid
                └────────┬─────────┘
                         │ for each (variant, fixture)
                         ▼
                ┌──────────────────┐
                │   run.py         │  ← drives one cell
                ├──────────────────┤
                │ 1. stage fixture │
                │ 2. start stub    │
                │ 3. pasclaw build │
                │ 4. run oracle    │
                │ 5. emit result   │
                └────┬────────┬────┘
                     │        │
                     ▼        ▼
            ┌─────────────┐ ┌──────────────────┐
            │ provider_   │ │ build/pasclaw    │
            │ stub.py     │◄┤ (--provider stub │
            │             │ │  api_base=local) │
            │ /v1/chat/   │ │                  │
            │ completions │ └──────────────────┘
            └─────────────┘
```

`provider_stub.py` is a localhost OpenAI-compatible HTTP server. It runs
in one of three modes:

- `--mock <transcript.jsonl>` — replay an offline transcript. Each line
  is one full chat-completion response. Used for harness self-tests
  and for paid-CI runs where you don't want to burn API tokens. Each
  fixture ships a `mock/default.jsonl` showing the "ideal" trajectory.

- `--proxy <upstream_base_url>` — forward each request to a real
  upstream provider (any OpenAI-compatible endpoint: Anthropic via
  its OpenAI-compat shim, OpenAI, Groq, OpenRouter, Ollama, …). Set
  `PROVIDER_STUB_UPSTREAM_KEY` to the bearer token.
  Optional `--record <transcript.jsonl>` snapshots the proxied turns
  for later replay.

- `--blocking <queue_dir>` — file-FIFO mode for live driving. Each
  POST atomically writes `queue/req_N.json`; the stub then polls
  `queue/resp_N.json` and returns its content when it appears. The
  driver (a human, this Claude Code session, or a subagent) is the
  live LLM in the loop. See `harness/start_cell.sh` /
  `harness/finalize_cell.sh` / `harness/driver_helper.py` for the
  bracket+helper pattern.

PasClaw is invoked via `pasclaw build -d <prompt>`, the one-shot
multi-iter mode designed for CI runs. It writes a workspace.zip-style
contract and exits when the agent emits a final assistant message.

## Sweep design

The variant matrix (`variants.json`) holds 6 cells today, picked OVAT
from the `max-build` profile to probe high-leverage knobs:

| variant | what changes | hypothesis |
|---|---|---|
| `baseline` | everything off | floor / control |
| `stock` | `TConfig.Create` defaults | no-profile fresh install |
| `max-build` | productive-coding defaults | upper bound on PasClaw "as shipped" |
| `max-build-low-iters` | iter budget 8 instead of 20 | tests the iteration ceiling |
| `max-build-plan-mode` | force plan-mode | tests forced planning |
| `low-token` | condenser + output cap + task-aware MEMORY slicing | cost vs intelligence |

Full grid is 6 variants × 4 fixtures = 24 cells. Adjust by editing
`variants.json` or passing `--fixtures` to `score.py`.

## Fixture format

Each fixture is one directory with this shape:

```
fixture/<slug>/
├── manifest.json            # prompt, oracle.cmd, scope_paths
├── pre-fix/                 # staged into the workspace at run start
│   └── ...
├── oracle/                  # NOT staged -- agent never sees these
│   └── test.sh
└── mock/                    # offline transcripts for --mock runs
    ├── default.jsonl
    └── <variant-id>.jsonl   # optional per-variant override
```

`manifest.json` schema:

```json
{
  "name": "<slug>",
  "category": "trivial-localisation|function-level-fix|operator-workflow|...",
  "shape_of": "<reference to a real PR or external benchmark>",
  "prompt": "<the task description the agent receives>",
  "scope_paths": ["src/", "report.json"],
  "oracle": {
    "cmd": "$FIXTURE_DIR/oracle/test.sh"
  }
}
```

The `oracle.cmd` shell string runs from the workspace cwd with
`$FIXTURE_DIR` and `$WORKSPACE` set; exit 0 = pass.
`scope_paths` is informational — files the agent writes outside it
are counted as `oos_edits` but not failed automatically (the user can
re-weight in their own analysis).

## Bundled fixtures

| slug | shape | category |
|---|---|---|
| `01-snippet-window-magic-number` | PR #309: lift hardcoded `24` to a named const | trivial localisation |
| `02-windows-shell-quoting` | PR #307: doubled-quote escaping in cmd.exe | function-level fix |
| `03-count-source-files` | operator: shell + structured output | operator workflow |
| `04-fix-yaml-syntax` | operator: surgical text edit, preserve other fields | operator workflow |

1 and 2 are bug-fix tasks (Phase A — SWE-bench-shaped). 3 and 4 are
operator workflows (Phase B — Terminal-Bench v2-shaped: file operations,
shell, structured outputs).

## Running

Smoke (offline, uses bundled mocks):

```sh
python3 bench/swe/harness/score.py --mock
# wrote bench/swe/results/frontier.md
# wrote bench/swe/results/sweep-<ts>.json
```

Real provider:

```sh
export PROVIDER_STUB_UPSTREAM_KEY=sk-...
python3 bench/swe/harness/score.py \
    --proxy https://api.openai.com   # or https://api.anthropic.com via its
                                     # OpenAI-compat shim, Groq, OpenRouter, Ollama
```

One-shot a single cell:

```sh
python3 bench/swe/harness/run.py \
    --fixture bench/swe/fixture/01-snippet-window-magic-number \
    --variant '{"id":"x","profile":"stock","max_iters":8}' \
    --proxy http://localhost:11434
```

### Live driving (human or Claude subagent as the provider)

For inside-the-session bench runs where you want a Claude (this one,
or a spawned subagent) acting as the LLM directly — no upstream API:

```sh
# 1. stage a cell, leaving stub + pasclaw running in background
RUN_ID="live-$(date +%s)"
bash bench/swe/harness/start_cell.sh \
    "$PWD/bench/swe/fixture/01-snippet-window-magic-number" \
    '{"id":"x","profile":"max-build","max_iters":10}' \
    "$RUN_ID"
# prints {run_dir, queue, port, pasclaw_pid, stub_pid}

# 2. drive each turn: read req_N.json, write the JSON response
RUN_DIR="bench/swe/results/run-$RUN_ID"
python3 bench/swe/harness/driver_helper.py status --queue "$RUN_DIR/queue"
# {"pending":[1],"answered":[],"next_seq":2}
cat "$RUN_DIR/queue/req_1.json"   # see what PasClaw is asking
# author /tmp/r.json as an OpenAI chat-completion response
python3 bench/swe/harness/driver_helper.py send-reply \
    --queue "$RUN_DIR/queue" < /tmp/r.json
# ... repeat until pasclaw.pid exits ...

# 3. finalize -- runs the oracle, writes result.json, kills the stub
bash bench/swe/harness/finalize_cell.sh "$RUN_DIR"
```

The Claude Agent SDK pattern: spawn one general-purpose subagent per
cell with the above sequence as its prompt. Multiple cells can run in
parallel — each binds a random port and lives in its own RUN_DIR. Real
sweep results captured this way live alongside mock/proxy results in
`results/`, scored by the same `score.py`.

## Metrics

Per cell:

- `passed` — oracle exit code == 0
- `metrics.turn_count`, `tool_calls` — counted at the stub layer (the
  source of truth for "what the model asked for"). Note these are
  what the model requested, not what PasClaw allowed — plan-mode can
  silently no-op a mutating tool, which is itself a useful signal
  (`max-build-plan-mode` fails the snippet-window fixture for exactly
  this reason on the bundled mocks)
- `metrics.tokens_in`, `tokens_out` — from the provider response's `usage` field
- `oos_edits` — count of files written outside `scope_paths`
- `wall_clock_s` — harness-timed
- `oracle.{stdout, stderr, exit_code}` — full oracle output captured

Aggregate (per variant, in `frontier.md`):

- `pass_rate` = passed / n
- `tokens_per_solved` = total tokens on passing runs / passed
- `oos_per_run` = total oos_edits / n
- `frontier=yes` iff no other variant strictly dominates on
  (pass-rate higher, tokens/solved lower, oos lower)

Pick the frontier row whose tradeoff matches your deployment: maximum
intelligence (highest pass-rate), token economy (lowest tok/solved at
acceptable pass-rate), or production safety (zero `oos`).

## Why this design — design notes per Perplexity research

The
[Perplexity SWE-bench research](https://www.perplexity.ai/search/e8d52ef2-c48a-4005-bcf7-f7b4146ef16e)
called out four practices we built in:

1. **"Real historical bugs from your repos"** → fixtures 01 and 02
   are PR-shape-matched.
2. **"Trajectory quality"** → `tool_calls` per turn is already logged
   at the stub layer; comparing against gold trajectories is a one-line
   `score.py` extension when a fixture ships a gold trajectory.
3. **"Cost + safety beyond pass-rate"** → `tok/solved` and
   `oos_per_run` are first-class frontier axes.
4. **"Treat benchmarks as orientation, your own task suite as the gold
   standard"** → the harness is provider-agnostic and fixture-agnostic
   so adding more shapes is just dropping a new directory under
   `fixture/`.

## Adding a fixture

```sh
mkdir -p bench/swe/fixture/05-my-task/{pre-fix,oracle,mock}
# author manifest.json, pre-fix tree, oracle/test.sh
chmod +x bench/swe/fixture/05-my-task/oracle/test.sh

# sanity-check the oracle is bi-stable
( cd /tmp && rm -rf wt && mkdir wt && cp -r bench/swe/fixture/05-my-task/pre-fix/* wt/ \
    && cd wt && FIXTURE_DIR=$(realpath ../../bench/swe/fixture/05-my-task) "$FIXTURE_DIR/oracle/test.sh" )
# ^ should FAIL (pre-fix has the bug)

# Now apply your gold patch in wt/ and re-run -- should PASS.
```

For the mock transcript, the simplest path is to do one real `--proxy`
run with `--record` against your favourite upstream provider; the
resulting JSONL becomes the bundled `mock/default.jsonl`.

## First live-driven results

Five cells driven with Claude as the LLM (no upstream API), using the
`--blocking` mode + start_cell.sh / finalize_cell.sh / driver_helper.py
flow:

| fixture | variant | driver | passed | turns | tool_calls | wall_s |
|---|---|---|---|---|---|---|
| 01-snippet-window-magic-number | stock         | this session, manual | yes | 3 | 2 | 77 |
| 01-snippet-window-magic-number | max-build     | subagent (parallel)  | yes | 2 | 1 | 100 |
| 01-snippet-window-magic-number | low-token     | subagent (parallel)  | yes | 2 | 1 | 101 |
| 02-windows-shell-quoting       | max-build     | subagent             | yes | 2 | 1 | 112 |
| 03-count-source-files          | max-build     | subagent (parallel)  | yes | 4 | 3 | 141 |

5/5 pass. The subagents on fixture 01 both converged on a 2-turn solution
(skip the read, go straight to fs_write) -- the manual cell took 3 because
I read first. Fixture 03 needed 4 turns because PasClaw's shell sandbox
denied the subagent's first try at `shell_exec "wc -l $(find ...)"`:

> PasClaw's shell sandbox blocks `$(...)` command substitution as a
> forbidden pattern. The agent had to split the count and the write into
> separate tool calls.

That's a real behavior finding surfaced through the bench — exactly the
kind of trajectory-quality signal Perplexity §"Trajectory quality"
calls out as the second metric beyond pass-rate.

### Token-metric caveat for live-driven runs

`provider_stub.py` reads `tokens_in` / `tokens_out` from the response's
`usage` field — which is authoritative for proxy and mock runs (real
provider, or recorded transcript). For `--blocking` runs, the human or
subagent author rarely bothers to fill in honest numbers, so the stub
now applies a char-count fallback (~1 token per 4 chars) when the
provider returns 0 or 1. That estimator was added in this same commit,
so the first live-driven sweep above predates it and its tokens columns
are not meaningful. Re-running with the same RUN_IDs after the change
will produce comparable token data.

## Out of scope (v1)

- **Real SWE-bench Verified / Lite.** Needs Docker + per-instance
  Python envs; a separate fixture-loader is straightforward but
  deferred until we want a public anchor.
- **GAIA, AgentBench, WebArena.** Different task shapes (browser,
  reasoning, multi-env); we'd reuse `provider_stub.py` + a different
  fixture schema.
- **DeepSWE / SWE-Atlas-QnA composite.** Useful for orientation
  against the ArtificialAnalysis leaderboard; another deferred
  fixture-loader. The variant matrix here can score those tasks
  unmodified once loaded.
