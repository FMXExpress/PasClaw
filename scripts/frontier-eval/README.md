# Running PasClaw on the FrontierHarness Eval tasks

[FrontierHarness Eval](https://github.com/frontier-harness-eval/eval) holds the
model constant and varies the harness: one model (Kimi K3 via Fireworks), 30
software-engineering tasks, 12 harness configurations, 360 runs. The published
table shows harnesses within 17 points of each other on pass rate and a 17.5x
spread on cost.

This directory adds PasClaw as another harness on the same task definitions,
with PasClaw's `relay` provider standing in for the model endpoint so an
external operator answers each turn.

## What this reproduces, and what it does not

Read this before quoting any number from a run.

| | status |
|---|---|
| the instruction | **exact** -- `instruction.md` is sent verbatim as the user message |
| the environment | **exact** -- the container image named in the task's `task.toml`, pulled from the public registry the benchmark publishes |
| the repository state | **exact** -- whatever that image ships at `/app`, which is the upstream repo at the task's `base_commit_hash` |
| CPU and memory limits | **exact** -- read from `[environment]` in `task.toml` |
| network posture | **equivalent** -- the container joins an `--internal` Docker network, so the agent has no route off-box while the operator still reaches the gateway over the bridge. That is the same shape as the benchmark's no-network agent with a reachable model endpoint |
| the artifact | **exact** -- the `[[verifier.collect]]` commands from `task.toml` run in the container and their outputs are copied out |
| the verifier | **absent** -- withheld by the benchmark, by design |
| the model | **different** -- every published row is Kimi K3 |

The last two lines are why **a PasClaw run is not a row in the FrontierHarness
table**, and saying otherwise would be wrong twice over:

* **No score exists.** The eval repository ships results and task definitions
  only; solutions, verifiers and internal infrastructure are deliberately
  excluded. `fh_verify.py` runs build and regression checks so a run is not
  simply unmeasured, but those checks are ours. They answer "did the agent
  break the repository", not "did the agent solve the task". Report them as
  build and existing tests pass, never as a pass rate.
* **Two axes move at once.** The benchmark's entire design is one model across
  many harnesses. Swapping in a different model as the relay operator changes
  the axis being held fixed, so the result measures the pair, not the harness.
  To place PasClaw in that table you would have to point the gateway at
  Fireworks-served Kimi K3 and obtain the verifiers, which is a request to the
  benchmark authors rather than a code change here.

What a run *does* establish: that PasClaw drives a real agent loop to
completion inside the benchmark's own environment on the benchmark's own
instruction, and produces the artifact the benchmark scores. That is the part
a harness is responsible for.

## The relay, and why it needs a daemon

PasClaw's `relay` provider inverts the usual direction. Instead of PasClaw
calling a model API, the model connects inbound to the gateway, holds an SSE
stream open on `/v1/relay/poll`, and answers each queued request on
`/v1/relay/respond/<id>`. No API key, no outbound network.

Two properties of the gateway make the obvious approach -- one `curl` per turn
-- wrong, and `fh_relay.py` exists to handle both:

* **The poll stream is the worker's registration.** Closing it unregisters the
  worker, which requeues every job that worker had in flight. A per-turn curl
  therefore hands the same job out twice and the eventual respond arrives for
  an id the gateway no longer knows. The daemon holds one stream for the whole
  run and responds on a separate connection.
* **Each job repeats the entire transcript.** By turn 25 that is most of the
  context window, re-sent every turn. `next` prints only the messages added
  since the previous job.

## Usage

```bash
# 1. get the task set (30 tasks, data only)
python3 scripts/frontier-eval/fh_tasks.py --dest /tmp/fh fetch
python3 scripts/frontier-eval/fh_tasks.py --dest /tmp/fh list

# 2. bring up one task: pulls the image, starts the container on an
#    internal network, launches the gateway inside it, attaches the relay
python3 scripts/frontier-eval/fh_run.py up \
    --task anko-typed-variable-bindings \
    --tasks-dir /tmp/fh/tasks --run-dir /tmp/fh/runs/anko

# 3. send instruction.md as the user message (returns immediately)
python3 scripts/frontier-eval/fh_run.py ask --run-dir /tmp/fh/runs/anko

# 4. service turns as the model, until the loop finishes
S=/tmp/fh/runs/anko/spool
python3 scripts/frontier-eval/fh_relay.py --spool $S next
python3 scripts/frontier-eval/fh_relay.py --spool $S respond \
    --call shell_exec --args '{"command":"go test ./..."}'
python3 scripts/frontier-eval/fh_relay.py --spool $S respond --content "done: ..."

# 5. collect the benchmark's artifact, check the tree, summarise
python3 scripts/frontier-eval/fh_run.py collect  --run-dir /tmp/fh/runs/anko
python3 scripts/frontier-eval/fh_verify.py --run-dir /tmp/fh/runs/anko --tasks-dir /tmp/fh/tasks
python3 scripts/frontier-eval/fh_run.py report   --run-dir /tmp/fh/runs/anko
python3 scripts/frontier-eval/fh_run.py down     --run-dir /tmp/fh/runs/anko
```

`respond` takes a final answer (`--content`), one tool call (`--call` plus
`--args`), several (`--tool-calls` with a JSON array), or a whole response body
(`--file`). `show --field system_prompt` prints what PasClaw actually sent.

## Requirements

* a running Docker daemon, and roughly 1 GB of image download per task
* the `pasclaw` binary from `make` -- it is bind-mounted into the container, so
  the image needs no PasClaw install. The FPC build links only libc and libm,
  which is why a binary built on a newer glibc still runs on the Debian 12
  images the benchmark uses
* Python 3.11 or newer, for `tomllib`

## A completed run

`anko-typed-variable-bindings` (Go, difficulty medium; the benchmark's own
metadata records a median of 57.5 agent steps and 741 seconds for this task):

| | |
|---|---|
| turns | 26 |
| tool calls | 25 |
| wall time | 495 s |
| artifact | `model.patch`, 11 files |
| local checks | `go build ./...` and `go test ./...` both clean |
| benchmark score | none -- verifier withheld |

The agent added `var x: type = value` to Anko's grammar, an
`Options.TypedBindings` gate, per-scope type constraints in `env`, enforcement
on assignment, and 28 test cases, then committed on a feature branch as the
instruction required.

## The two task families differ

The 9 DeepSWE tasks and the 21 Terminal-Bench tasks do not have the same
shape, and the driver handles both:

| | DeepSWE (9) | Terminal-Bench (21) |
|---|---|---|
| image | `public.ecr.aws/d3j8x8q7/swe-bench-*` | `alexgshaw/<task>` on Docker Hub |
| `/app` | the upstream repo at `base_commit_hash` | often empty; the task seeds elsewhere or the agent creates it |
| git | present | not necessarily installed |
| `[[verifier.collect]]` | a `git diff` producing `model.patch` | **none** |
| `artifacts` | `/logs/artifacts/model.patch` | **none** |
| `[agent] network_mode` | `no-network` | unset |

Terminal-Bench tasks are scored entirely inside the withheld verifier, which
runs against the container's final state, so there is nothing to copy out. When
a task declares no collect step, `collect` records what changed instead: a git
diff of the workdir when it is a repository, plus the container's own
changed-path list with the harness's footprint filtered out. That is a record
of the run, not an artifact the benchmark consumes.

Because those tasks declare no network posture, `--network bridge` opens the
container's internet access for the ones that need it; the default stays the
stricter `internal`.

## Notes

* The gateway runs as `pasclaw serve`, not `pasclaw gateway`: the same server
  and the same routes, but it accepts `--max-iter`. The 25-iteration default is
  far below these tasks.
* `PASCLAW_WORKSPACE` names a directory under `PASCLAW_HOME` rather than an
  absolute path, so `up` makes that directory a symlink to the task checkout.
  Without it the agent works in an empty scratch directory and the collect
  command -- a git diff of `/app` -- comes back empty.
* PasClaw creates scratch directories inside its workspace. `up` adds them to
  the task repo's `.git/info/exclude` so an agent running `git add -A` does not
  commit harness state as part of its solution. `.git/info/exclude` rather than
  `.gitignore`, because `.gitignore` is tracked and editing it would itself
  land in the diff.
* Commits the agent makes inside the container carry no operator attribution.
  They are benchmark artifacts, and identifying the model in them would leak
  into the one thing the benchmark holds constant.
