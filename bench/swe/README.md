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

## The cost / capability tradeoff

PasClaw's profiles aren't a "small is better" axis. Each one targets a
different operator scenario:

| profile | targets | what it carries |
|---|---|---|
| `baseline` | A/B controls | bare minimum, no feature tools |
| `lean-edit` | pure local editing | fs / shell / execute_code / memory_search / session_search; no web, no vault |
| `stock` | fresh install defaults | adds web_fetch + vault to lean-edit's core |
| `lean-stock` | stock + productive behaviors | same tools as stock, plus checkpoints / stats / 1h cache / distiller / orient-aware / auto-router |
| `lean-build` | productive coding (no skill authoring) | lean-stock + condenser + 16KB cap (adds tool_output_get) |
| `low-token` | aggressive token economy | lean-build + progressive_disclosure (skills_list/view) |
| `security` | sandboxed deployments | drops web_fetch + vault + adds workspace + shell denylist |
| `max-build` | **maximum capability** | every tool registered: skill authoring (skills_manage), skill discovery (skills_list/view), web research (web_fetch), library lookup (vault_search/get), agent memory (memory_search/fetch), session recall (session_search) |
| `all-on` | surface-area testing | max-build + auto_approve |

Each capability has a purpose:

- `web_fetch` — read documentation, fetch a known URL into the conversation
- `vault_search` / `vault_get` — discover library APIs and example code from the pasclaw.dev Code Vault. The agent searches for what would help its work.
- `memory_search` / `memory_fetch` — recall facts and decisions from prior sessions
- `session_search` — find prior tool-call output (e.g. an earlier grep result the agent forgot)
- `skills_list` / `skills_view` — discover and read user-installed skills (procedures the operator wants the agent to follow)
- `skills_manage` — create / install / remove skills mid-session (self-improving loop)
- `fs_edit_hashline` — surgical patches that preserve byte-exact context
- `fs_grep` — cross-file pattern search with built-in skip rules
- `execute_code` — multi-line scripts (heredocs, loops, fan-out)
- `tool_output_get` — re-fetch a tool output that got capped

`max-build` carries every one of those because its job is to be ready
for ANY task, including ones the operator can't predict. The bench's
job, then, is to find tasks where each capability **earns** its bytes:

- A task that needs cross-file pattern finding → exercises `fs_grep`
- A task that needs supporting library examples → exercises `vault_search`
- A task that needs a known URL's content → exercises `web_fetch`
- A task that depends on prior-session memory → exercises `memory_search`
- A task with a pre-installed procedural skill → exercises `skills_list/view`

If `lean-edit` and `max-build` solve a task in the same turn count,
the extra capability isn't earning anything on that task. If
`max-build` solves it in 2 turns and `lean-edit` takes 8, that's the
capability earning ~75% time savings.

`fixture/01..04` are simple bug-fix tasks. They don't exercise the
incremental surface — both ends of the spectrum pass identically.
`fixture/07-cross-file-grep` is the first capability fixture: it
forces a cross-file pattern lookup. See "Capability fixtures" below
for the empirical comparison.

## First-turn prompt cost (informational)

The byte-cost data below is the FLOOR price every variant pays per
turn whether it uses those tools or not. Combine with the capability
data to decide which profile fits your task mix.

## What `max-build` actually costs — first-turn ablation

Each setting in `max-build` was tested individually against `stock` using
`harness/probe_first_turn.py` — it spins up PasClaw, captures the very
first `/v1/chat/completions` request, measures size + tool count, kills
PasClaw. Cheap (~3 seconds per variant), runs without a real provider,
results in `results/ablation.md`.

Headline:

| variant | bytes/turn | tools | Δ vs stock |
|---|---|---|---|
| `baseline` / `security` | 9910 | 9 | −22.7% |
| `stock` | 12822 | 13 | — |
| `lean-stock` (proposed) | 12822 | 13 | 0% |
| `lean-build` (proposed) | 13374 | 14 | +4.3% |
| `low-token` | 14226 | 16 | +10.9% |
| `max-build` (as shipped) | 15717 | 17 | +22.6% |
| `all-on` | 15717 | 17 | +22.6% |

The 2895-byte gap between `stock` and `max-build` breaks down as:

| toggle | Δbytes | tools added | when it pays |
|---|---|---|---|
| `condense_reversible` OR `tool_output_cap > 0` | +552 | `tool_output_get` | tool outputs that cap |
| `self_improving_skills.progressive_disclosure` | +852 | `skills_list`, `skills_view` | skills installed |
| `self_improving_skills.self_manage` | +1491 | `skills_manage` | agent authors skills |
| `orient_task_aware`, `checkpoints`, `stats_collection`, `prompt_cache.ttl=1h`, `auto_router`, `distiller` | 0 | — | always free behavioral upgrade |

**The right way to read this**: `max-build` is not a "bloated" profile
that should be slimmed. Its purpose is to advertise PasClaw's *maximum
development capability* — every skill, every search surface, every
self-improvement loop. The 2895-byte delta is the cost of carrying that
capability to every turn, used or not.

The bench's job is to find tasks where those capabilities **earn** that
cost — tasks that lean-edit *fails* and max-build *passes*. The four
bundled fixtures don't differentiate: they're simple enough that the
core surface (fs_read / fs_write / shell_exec) handles them all. So
the cost-only ablation above is only half the story.

Fixtures that actually exercise max-build's incremental surface
(`fixture/05-*` and beyond) are a follow-up — see "Capability fixtures"
below.

### Recipe for the bench-proven minimum

`--profile lean-edit --no-hashline` produces a **7681 B / 7-tool**
prompt that solved every bench fixture (4/4 pass via subagent
drivers). That's **−51% from `max-build`**. The 7 surviving tools:
`fs_read`, `fs_write`, `fs_list`, `shell_exec`, `execute_code`,
`memory_search`, `session_search`. Drops `fs_edit_hashline` and
`fs_grep` (which are bundled together behind `--no-hashline`).

`--no-hashline` is currently a CLI flag without a corresponding
config field — exposing it as `hashline_enabled: false` in TConfig
+ FromJSON + the agent / build / serve commands would let a future
`lean-fs` profile inherit from `lean-edit` and set it declaratively.
Small Pascal change; worth doing in a follow-up.

### Three proposed composites — all shipped as built-in profiles

- **`lean-edit`** — `lean-stock` minus `web_fetch` + `vault_tools`. The
  smallest viable code-editing surface: still has `fs_*`, `shell_exec`,
  `execute_code`, `memory_search`, `session_search`. **22.7% smaller
  than `stock` (9910 B vs 12822 B), 37% smaller than `max-build`.** Use
  for focused local editing where you never need the web or the
  pasclaw.dev Code Vault.
- **`lean-stock`** — stock + all 6 zero-cost behavioral toggles
  (`orient_task_aware`, `checkpoints`, `stats`, `cache_ttl=1h`,
  `distiller`, `auto_router`). Same prompt size as stock (12822 bytes)
  with all the productive-coding behavior turned on.
- **`lean-build`** — `lean-stock` + `condense_reversible` +
  `tool_output_cap=16384`. Adds the `tool_output_get` tool (+552B / +1
  tool). The right default for sessions that may run long or hit big
  tool outputs.

Skip `progressive_disclosure` unless you've actually installed skills.
Skip `self_manage` unless the agent should be authoring skills
mid-session. Both pay for themselves only in narrow scenarios.

### Total cost over a multi-turn task

Per-turn growth turned out to be **invariant at +1203 B/turn across
every variant** (`harness/turn_growth.py`), because PasClaw's `condenser`
only fires on individual tool results above 4 KB and most code reads
are well under that. So the variant deltas at turn 1 persist linearly:

| variant | turn 1 | 3-turn total | Δ vs max-build |
|---|---|---|---|
| `lean-edit` / `baseline` | 9916 | 32913 | **−34.6%** |
| `stock` / `lean-stock` | 12828 | 41649 | −17.3% |
| `lean-build` | 13380 | 43305 | −14.0% |
| `low-token` | 14232 | 45861 | −8.9% |
| `max-build` / `all-on` | 15723 | 50334 | — |

On a 10-turn task, the gap widens to ~70 KB. With prompt-cache on, the
billing-side savings are smaller (cached prompt is half-price on most
providers) but the per-turn latency hit from a bigger payload still
stings.

### Are the tools we ship actually being used?

Sharper question than "which profile is cheapest" — which tools earn
their bytes on real tasks? `harness/tool_utilization.py` tallies
per-tool call counts across the bundled mock transcripts and any
live-driven runs left under `results/`.

On the four bundled fixtures, **the ideal trajectories use 3 tools out
of 17 (18%)** — `fs_read`, `fs_write`, `shell_exec`. The other 14 are
registered but never called. They cost **10,303 bytes (90.7% of the
total tool-registration budget) for zero use** on these tasks. Full
table in `results/tool_utilization.md`.

The big caveat is that these fixtures are small. Real coding tasks
would call `fs_grep` (find callers), `fs_edit_hashline` (surgical
patches), and `memory_search` (recall prior decisions) far more often.
The 18% number is a floor, not a ceiling. But it's also empirical
evidence that `max-build`'s 17 registrations are paid mostly out of
optimism, not measured benefit, for the simple-task end of the
distribution.

Empirical validation: running the most-stripped config (`lean-edit`
+ `--no-hashline`, **7681 B / 7 tools — half of `max-build`**) on
all four fixtures through subagent drivers, all four still pass. That
covers fs_read, fs_write, fs_list, shell_exec, execute_code,
memory_search, session_search — the irreducible minimum that handled
every bench task.

### How does this compare to openclaw?

[openclaw](https://github.com/openclaw/openclaw) is the upstream
PasClaw drew its memory architecture from. It's a TypeScript
implementation with a much broader scope: 75+ subdirectories under
`src/` including channels (Discord, Slack), media generation (image,
music, video), realtime transcription, talk (voice), trajectory
recording, plugin SDK. Architectural differences:

- **Prompt construction**: openclaw is data-driven — the LLM prompt
  is composed from workspace files (`~/.openclaw/workspace/AGENTS.md`,
  `SOUL.md`, `TOOLS.md`) that the operator owns and edits. PasClaw's
  is mostly compiled-in. Tradeoff: openclaw is more flexible per
  deployment, PasClaw is more predictable across deployments.
- **Tool surface**: openclaw exposes everything openclaw is, including
  the voice / channel / media-generation paths PasClaw doesn't have.
  Its default `tools[]` payload is therefore likely larger than
  `max-build`. For pure SWE-style coding tasks (what this bench
  measures), PasClaw's `lean-edit` is the smaller surface; for
  agent-as-OS workflows (multi-channel chat, scheduled cron, voice),
  openclaw's surface is the more capable one.
- **Effectiveness on the same tasks**: undetermined without running
  openclaw against these fixtures. The bench harness is provider-
  agnostic — a single `provider_stub.py --proxy <openclaw_endpoint>`
  cell would slot openclaw in. Left as a follow-up because openclaw
  needs its own onboard / config / channel auth that's out of scope
  here.

## Multi-iteration result: `09-bash-notes-cli`

Longer than the Centipede task. The agent has to design AND implement
a 6-subcommand bash CLI plus write its own end-to-end test suite, then
gate "done" on the tests actually passing. Expected to surface the
write→test→fix→retest cycle.

Subagent-driven runs of three profiles:

| profile | tools | pass | turns | tool calls | wall_s | notes script LOC | self-tests |
|---|---|---|---|---|---|---|---|
| `lean-edit` (retry) | 9 | **PASS** | 5 | 4 | 213 | 132 | OK |
| `stock` | 13 | **PASS** | 9 | 8 | 436 | 154 | OK |
| `max-build` | 17 | **PASS** | 12 | 10 | 433 | 154 | OK |

`max-build` took **3 more turns than stock and 7 more than lean-edit**,
for the **identical pass-rate**. Subagent transcripts show the extra
turns were dead-end exploration triggered by the larger tool surface
(distiller hook firing, extra denylist-recovery attempts).

The first lean-edit attempt (not shown) failed for a driver reason
unrelated to PasClaw: the subagent fs_write'd to an ABSOLUTE path into
`pasclaw-home/` instead of the workspace cwd. The retry above clarified
that PasClaw's `--cwd workspace` means relative paths land correctly.
Same fixture, same profile, just a clearer driver prompt.

### What this means

For a moderately long, multi-iteration task that DOESN'T need
max-build's incremental tools (skills, vault, web), max-build pays:

- 30% more prompt bytes per turn (15.7 KB vs lean-edit's 9.9 KB)
- ~2.4x more turns than lean-edit (12 vs 5)
- For the same outcome

That's a real cost. The extra capability tools weren't called once
across the 12 turns. They were registered, advertised in the system
prompt, and ignored.

Notable real find: **PasClaw's shell denylist blocks `chmod`, bare
`rm`, and `$(...)` substitution in tool-call command strings**, but
NOT inside scripts the shell invokes. All three subagents discovered
this independently and routed around it via `execute_code` (python
`os.chmod`) or by writing the command to a file then `bash file`.
That's friction on every bash-shaped task — worth investigating
whether the denylist is too aggressive for the threat model.

## Long-creative result: `08-cli-centipede`

A from-scratch build task: write a playable CLI Centipede game in
Python (curses TUI) with classes for Player/Centipede/Bullet/Game, a
`--self-test` mode that simulates 20 ticks without a TTY and prints
`SELF_TEST_OK`, 100-800 LOC. Designed to be the first fixture long
enough that condenser / tool_output_cap / prompt_cache could fire
meaningfully.

Subagent-driven runs of three profiles:

| profile | tools | pass | turns | tool calls | wall_s | game LOC | self-test |
|---|---|---|---|---|---|---|---|
| `lean-edit` | 9 | **PASS** | 3 | 2 | 247 | 392 | OK |
| `stock` | 13 | **PASS** | 3 | 2 | 249 | 360 | OK |
| `max-build` | 17 | **PASS** | 3 | 2 | 247 | 426 | OK |

**All three solved it in exactly 3 turns** (fs_write game.py →
shell_exec --self-test → done). Same pass-rate, same trajectory shape,
same wall-clock. The 30-LOC spread is subagent-to-subagent variation,
not profile-driven.

### What this means

Subagent-driven runs cost (per turn): `lean-edit` ≈ 9.9 KB system+tools,
`stock` ≈ 12.8 KB, `max-build` ≈ 15.7 KB. Over the 3 turns this task
took, `lean-edit` paid ~30% less per turn for the **identical
outcome**. The extra capabilities `max-build` carries — skill discovery,
skill authoring, condensable tool results, vault lookups — were
**registered but never invoked**, because the task is self-contained
and doesn't need any of them.

### Caveats

This doesn't mean `max-build` is wrong for everyone. It means **on a
one-shot creative task that fits in a small turn budget**, profile
choice doesn't change the outcome, so the cheapest variant wins on
cost. The bench HASN'T YET produced a long, capability-dependent task
where `max-build`'s extras would surface. That's a known gap (`08`
isn't long enough to trigger condenser; `07-cross-file-grep` was the
only capability-shaped fixture and shell-shaped substitutes beat
`fs_grep`).

The genuinely hard test — and the next priority — is a multi-hour
task where the conversation grows large enough that `condense_reversible`
fires on accumulated tool outputs. None of these short fixtures hit
that.

### Tooling note

This shootout initially failed because PasClaw's OpenAI provider
hardcoded a 120s HTTP read timeout, and Claude subagents authoring
multi-KB game files frequently took 130+ seconds to publish their
first reply. All three cells reported "FAIL: game.py missing" even
though each subagent had a working game in `/tmp/`. Bumped to 600s
in `src/pkg/providers/PasClaw.Providers.OpenAI.pas` (line 405). Worth
making configurable, but 600s covers slow-think for now.

## Capability-fixture result: `07-cross-file-grep`

The first capability test was designed to make `fs_grep` shine: 8
`.pas` files, 3 with real calls to `OldRoutine` and 5 with a comment
that just mentions it. The agent has to write the 3 calling files to
`result.txt`. Subagent-driven runs of three variants:

| variant | tools available | turns | tool calls | notes |
|---|---|---|---|---|
| `stock` | 13 (incl. fs_grep) | 3 | `fs_grep` → `fs_write` → done | clean baseline |
| `lean-edit` | 9 (incl. fs_grep) | 3* | `fs_grep` → `fs_write` → done | *first turn malformed by driver; would be 3 |
| `lean-edit + --no-hashline` | 7 (no fs_grep) | **2** | `shell_exec "grep -rln 'OldRoutine(' src/ > result.txt"` → done | one shell pipeline does find + filter + write |

**The stripped variant won.** `fs_grep` requires two steps (run the
search, parse the hashline output, write the result file). A single
`shell_exec` with `grep > result.txt` redirects in one shot. The 926
bytes `fs_grep` pays for didn't earn turns on this task.

That doesn't mean `fs_grep` is useless — it has built-in skip rules
(binary detection, vendored-dir exclusion) that `grep -r` doesn't, and
returns hashline-formatted output the agent can feed straight into
`fs_edit_hashline`. The win case for `fs_grep` is when you actually
WILL apply hashline patches downstream — at which point the shared
format is the value, not the search itself.

This is the right shape of finding for the bench: empirical, specific,
and surprising. A capability that *looked* like it should pay for
itself on a task built around it didn't, because there's a cheap
shell-shaped alternative.

### Implication for future capability fixtures

A clean "max-build wins" requires a task where the shell-shaped
alternative is **not** sufficient. That probably looks like:

- `08-vault-needs-library` — needs `vault_search/get` to find an
  example the model doesn't know from training data. No shell
  alternative (no `grep` over pasclaw.dev/vault). Pending.
- `09-skill-discovery` — agent must use `skills_list/view` because
  the skill body contains task-specific instructions that change the
  fix. No shell alternative (fs_list + fs_read works but is multi-step
  and the agent has to know where to look). Pending.
- `10-web-context` — task includes a URL whose contents are needed
  to solve it. Without `web_fetch`, the agent has no way to fetch it
  (shell `curl` may or may not be denied by the sandbox). Pending.
- `11-prior-session` — depends on a fact the agent decided in a
  previous session that's logged in `workspace/memory/`. Without
  `memory_search`, the agent has to grep / read manually. Pending.

Each of those would isolate a tool whose value is **uniqueness** (no
cheap substitute), not just convenience.

## Capability fixtures — does max-build's extra surface earn its weight?

The simple fixtures (01-04) can be solved with `fs_read` + `fs_write` +
`shell_exec`, so they don't distinguish max-build from a stripped
profile on capability. The capability fixtures (05+) are designed so
that each exercises a SPECIFIC tool max-build registers, and a
stripped profile is forced to fall back on a slower workaround.

| fixture | tests capability | task | expected lean-edit cost |
|---|---|---|---|
| `07-cross-file-grep` | `fs_grep` | Find every .pas file that calls `OldRoutine` across 8 files; one is in a subdirectory; 5 distractor files mention it in a comment but don't call it. | one `fs_grep` call vs multiple `fs_read`s or a `shell_exec grep` |
| `08-vault-needs-library` (planned) | `vault_search` + `vault_get` | "Implement X using the documented pattern from the pasclaw.dev Code Vault under <topic>." | without vault, model relies on training-data knowledge of the API |
| `09-skill-discovery` (planned) | `skills_list` + `skills_view` | Workspace pre-seeded with a relevant `~/.pasclaw/workspace/skills/<name>/SKILL.md`. Task says "use the installed skill that handles this kind of refactor." | without progressive_disclosure, agent has to fs_list the skills dir + fs_read the SKILL.md |
| `10-web-context` (planned) | `web_fetch` | Task with a URL: "Read the spec at <url> and implement what it describes." | without web_fetch, no way to fetch the URL (test fails) |
| `11-prior-session` (planned) | `memory_search` | Pre-seed workspace memory log with a decision; task asks the agent to recall it. | without memory_search, agent has to fs_read the memory log manually |

### Methodology

For each capability fixture, run three variants:

- `max-build` — has the capability tool registered. Expected: clean win.
- `stock` — has the same tool (the toggles are profile-side, but the tool registration is independent). Expected: matches max-build.
- `lean-edit + --no-hashline` (or another stripped variant relevant to the test) — falls back on workarounds. Expected: more turns and/or more tokens, possibly outright failure.

Tabulate `turns`, `total_bytes_across_all_turns`, and `passed`. The
fixture validates the capability when:

- All three variants pass, but stripped takes >2× the turns OR
- Stripped fails outright while max-build passes

If stripped matches max-build on both turns and pass-rate, the
capability isn't earning its bytes on THAT task shape (which doesn't
mean it never earns them — just not here).

### Where are the remaining improvements

The bench made three things clear that aren't currently fixable from
config alone:

1. **`condense_reversible` only fires on tool results > 4 KB**
   (`PasClaw.Condense.JSON.DefaultJSONCondenseOptions.MaxBytes`). For
   typical source files (~750 B), it never triggers. Exposing
   `condense_max_bytes` as a config field would let users tune this for
   their session shape; a lower threshold could clip moderate `fs_read`
   results too. Cost: condensed views may degrade for borderline-size
   bodies — needs a separate quality bench.
2. **No per-tool toggle.** Stock registers 13 tools whether or not
   you'll use them; `execute_code` alone is 1078 B, `web_fetch` 954 B,
   `fs_edit_hashline` 982 B. A `tools.exclude: [...]` config field
   would let an operator drop tools they know they won't need on this
   session, getting below `lean-edit`'s 9910 B floor.
3. **History is re-sent every turn.** The +1203 B per-turn growth is
   the conversation accumulating (prior assistant message + tool result
   + envelope). Provider-side prompt cache offsets this on real
   billing, but the raw payload still grows linearly. PasClaw's
   `condenser` is the right hook to address this; tuning thresholds (or
   adding a turn-count trigger) is a follow-up.

For 2 and 3, the bench harness can validate any future change with one
command (`probe_first_turn.py` for byte cost, `turn_growth.py` for
multi-turn shape, `run.py` / live-driving subagents for pass-rate).

### How to regenerate

```sh
# Probe every variant in ablation.json against fixture 01:
python3 -c "
import json, subprocess
rows = []
for v in json.load(open('bench/swe/ablation.json')):
    r = subprocess.run(['python3','bench/swe/harness/probe_first_turn.py',
        '--fixture','bench/swe/fixture/01-snippet-window-magic-number',
        '--variant',json.dumps(v)], capture_output=True, text=True)
    if r.returncode == 0:
        rows.append(json.loads(r.stdout.strip().splitlines()[-1]))
open('bench/swe/results/probe.json','w').write(json.dumps(rows, indent=2))
"
python3 bench/swe/harness/ablation_report.py
# wrote bench/swe/results/ablation.md
```

### What the probe doesn't measure

The first-turn probe only catches the **prompt-side** delta. It misses:

- `condense_reversible` — kicks in only after a long context, not on
  turn 1.
- `distiller` — passively monitors for repeated tool-call patterns; no
  effect on turn 1.
- `auto_router` — routes turns to a cheap model; only observable with
  a multi-tier provider config.
- `prompt_cache.ttl` — back-to-back runs benefit; single runs don't.

For these, run a pass-rate sweep with `score.py --proxy <real provider>`
or `--blocking` and a real long fixture (Phase B fixtures
`03-count-source-files`, `04-fix-yaml-syntax` already exercise some of
the operator-workflow surface).

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
