# `pasclaw plan` and the plan/build/improve modes

`pasclaw plan` is a sibling command to `pasclaw build`. It produces a
structured markdown plan as `workspace/PLAN.md` instead of executing
the work. The plan becomes input for a subsequent `pasclaw build` —
either as system-prompt context (plain build) or as the objective for
the Ralph judge loop (`build --goal`).

## Quick start

Local:

```
pasclaw plan -d "Add a --version flag to the CLI"
# review workspace/PLAN.md, edit if you want
pasclaw build -d "Add a --version flag to the CLI"
```

On the Replicate cog (`cog-build`), the same flow is selected via the
`mode` Input — see [the cog matrix](#cog-build-mode-input-matrix) below.

## The two commands

### `pasclaw plan -d "<task>"`

Generates `workspace/PLAN.md`. Runs the agent in `pmPlan` mode
(read-only tool surface — `fs_read`, `fs_grep`, `memory_search`,
`shell_exec` reads, etc. all work; `fs_write`, `fs_edit_hashline`,
`shell_exec` mutations, etc. are refused at the dispatch layer).

A dedicated `plan_write` tool is auto-registered when `--mode plan` is
set; the model calls it once with the finalized markdown body, and the
tool writes to `<home>/workspace/PLAN.md` (the path is hard-coded so
`plan_write` can't be turned into a general write primitive by clever
arguments).

The planner directive in the system prompt requires this structure:

```
## Goal
<one-sentence verb-prefixed objective>

## Files
- src/...
- src/...

## Steps
1. ...
2. ...

## Open questions
- ...

## Risks
- ...
```

The Goal section's opening line is constrained to a single sentence
starting with a verb so a subsequent `pasclaw build --goal` can parse
it as the Ralph objective.

#### Incremental updates

If `workspace/PLAN.md` already exists when `pasclaw plan` runs, the
existing body is injected into the planner's system prompt with a
**"revise / extend, don't replace"** directive. The model writes the
revised plan back (full markdown — not a diff). Operators wanting
per-revision history can `git log workspace/PLAN.md`.

#### Flags

```
pasclaw plan -d "<task>"
             [--max-iters N]                 # default 12 (plan is short)
             [--workspace-in <zip>]          # optional
             [--workspace-out <zip>]         # optional; carries PLAN.md
             [--cwd <dir>]
             [--home <dir>]
             [--keep-home]
             ... agent flags forwarded (--provider, --model, ...)
```

`--mode` is NOT forwarded — plan mode is forced. Use `pasclaw agent
--mode plan` for an interactive plan session.

### `pasclaw build -d "<task>"`

The existing one-shot multi-iteration agent command, with two new
behaviors added by the plan pairing:

**Phase 2 — PLAN.md auto-pickup.** If `workspace/PLAN.md` exists at
the start of the run, its body is injected into the system prompt as
`## Active Plan` and treated as authoritative guidance. A stale plan
(mtime > 24h) appends a `(stale: N hours)` note to the header so the
model treats it skeptically. After a successful build, PLAN.md is
archived to `workspace/memory/plans/<timestamp>.md` so the next build
doesn't re-consume the same plan.

Opt out with `--no-plan` — the file stays in place and is ignored for
the run. The archival is also skipped (opt-out of pickup means
opt-out of archival).

**Phase 3 — `--goal`.** When set, `pasclaw build` reads PLAN.md's
`## Goal` line and uses it as the objective for the Ralph judge loop
(`PasClaw.Agent.Goals.TGoalRunner`). Iterations pump until the judge
model returns MET / FAILED, or the `--goal-max-iters` budget runs out
(default 5).

`--goal` requires a parseable Goal section in PLAN.md. Missing
PLAN.md or a missing/empty Goal section produces a clean error:

```
$ pasclaw build -d "task" --goal
build: --goal was set but workspace/PLAN.md has no parseable "## Goal"
section (run `pasclaw plan -d ...` first to produce one)
```

Exit code:

| Verdict           | Exit |
|-------------------|-----:|
| MET               | 0    |
| BUDGET-EXHAUSTED  | 0    |
| FAILED            | 1    |
| ABORTED           | 1    |

`BUDGET-EXHAUSTED` is treated as a successful best-effort run — the
agent kept making progress but ran out of turns. Operators wanting a
strict "did it finish" gate should check the verbose-mode `— verdict —`
banner instead of just `$?`.

#### New flags on `pasclaw build`

```
--goal                    Drive the run via the Ralph judge loop
                          against workspace/PLAN.md's "## Goal" line.
--goal-max-iters N        Override the Ralph budget (default 5).
                          Ignored when --goal is absent.
--no-plan                 Ignore workspace/PLAN.md for this run
                          (skip both pickup and archival).
```

## cog-build `mode` Input matrix

The `cog-build` Replicate cog exposes a `mode` Input with four choices:

| `mode` value         | Commands run                                                  |
|----------------------|---------------------------------------------------------------|
| `build` (default)    | `pasclaw build`                                               |
| `plan`               | `pasclaw plan`                                                |
| `plan build`         | `pasclaw plan` → `pasclaw build` (intermediate workspace zip) |
| `plan build goal`    | `pasclaw plan` → `pasclaw build --goal` (Ralph judge loop)    |

For `plan build` and `plan build goal`, the cog chains the two
subprocesses through an intermediate workspace zip in its scratch
directory — `pasclaw plan`'s `--workspace-out` becomes
`pasclaw build`'s `--workspace-in`. The final `workspace_out.zip` ships
PLAN.md (archived if the build succeeded) alongside the rest of
`$PASCLAW_HOME`.

The `max_iters` Input applies to the build step; plan uses its own
Pascal-side default (12). Both subprocesses share `timeout_seconds`.

### When to use which mode

- **`build`** — no plan needed. Same behavior as before this pairing.
- **`plan`** — produce a plan to review or share. Common in a CI step
  before approval workflows.
- **`plan build`** — autonomous pipeline. The plan is system-prompt
  guidance for the build, but the build doesn't strictly verify
  against it.
- **`plan build goal`** — autonomous pipeline with judge-driven
  verification. The plan's Goal line is the success criterion; the
  Ralph loop keeps iterating until the judge says MET. Best for
  tasks where "done" is checkable from a model's reply alone.

## File layout

```
$PASCLAW_HOME/
├── workspace/
│   ├── PLAN.md                                  ← active plan
│   └── memory/
│       └── plans/
│           ├── 2026-06-21-101502.md             ← archived plans
│           └── 2026-06-21-143007.md
├── sessions/
├── checkpoints/
└── ...
```

PLAN.md lives at the workspace root for visibility (easy to find,
easy to `cat`, easy to edit by hand). Archives go under `workspace/
memory/plans/` so they become part of the workspace.zip round-trip
and the operator gets browsable history.

## How `/goal` ties in

The interactive `/goal` slash command (`pasclaw agent` REPL) and
`pasclaw build --goal` both drive `PasClaw.Agent.Goals.TGoalRunner` —
the same Ralph judge-loop machinery. The difference is purely
where the objective comes from:

- **Interactive**: operator types `/goal "<text>"` in the REPL.
- **Build**: objective is parsed from `workspace/PLAN.md`'s `## Goal`
  section.

Same dispatch, same judge prompt, same verdict tokens, same exit
semantics. The Ralph loop pumps:

1. Agent runs one tool-loop iteration.
2. Judge model evaluates the latest assistant reply against the
   objective.
3. On `MET` or `FAILED`, stop. On `CONTINUE`, the judge's suggested
   next action becomes the next user message and we loop back.
4. Capped at `--goal-max-iters` iterations.

## Implementation notes

- `plan_write` is the only tool in the codebase labelled `tcReadOnly`
  while writing to disk. It passes the `pmPlan` dispatch gate because
  the gate only refuses `tcMutating`; the safety argument is that
  `plan_write` writes to a single hard-coded file (`workspace/PLAN.md`)
  and cannot be turned into a general primitive by a model crafting
  clever arguments.
- `ExtractGoalFromPlanFile` accepts an explicit `HomeOverride` because
  `libc_setenv`'s `PASCLAW_HOME` isn't always visible to a same-process
  `GetEnvironmentVariable` read on FPC. `Cmd.Build` passes its own
  `Home` local var rather than round-tripping through the env table.
- The goal-driven one-shot path (`RunSingleTurnGoalDriven`) deliberately
  skips per-iteration session persistence and the post-turn skill
  distiller. Future work can re-add per-iteration `workspace/sessions/`
  writes; the distiller is a harder fit (it assumes one coherent task
  per turn, and goal loops produce N iterations).
- `pasclaw build` archives PLAN.md to `workspace/memory/plans/` BEFORE
  packing `workspace-out.zip`, so cog callers get the plan history in
  their output artifact.

## Related commands

- `pasclaw agent` — interactive REPL. Supports `/goal "<text>"` for
  the same Ralph loop driven from the chat surface.
- `pasclaw runbook` — tool-driven AGENTS.md bootstrap (companion to
  `pasclaw init`'s Pascal-driven variant). Different concept: AGENTS.md
  is persistent project guidance; PLAN.md is per-task.
- `pasclaw learn --write-scars` — emits/refreshes `workspace/memory/
  SCARS.md` with anchor IDs per recurring failure. Plans and scars
  compose: scars surface recurring traps; plans propose work.

## Improve mode

A third mode, alongside plan and build:

```sh
pasclaw agent --mode improve -m "make the tokenizer faster"
```

Plan and build differ in what the agent may **do** — the dispatch gate refuses mutating tools under plan. Improve differs in **how it goes about it**: every tool works exactly as in build, and what changes is the system prompt, which asks for the loop the mode is named after.

| Step | |
|---|---|
| **Benchmark** | Get a number *before* changing anything, and record the command that produced it. If nothing measures it yet, building that is the first task. |
| **Profile** | Find where the cost actually is. The slow thing is regularly not the thing that looks slow. |
| **Change one thing** | Several changes and one measurement tells you the total and nothing about which change earned it. |
| **Verify** | Re-run the *same* measurement, same conditions, and report before → after with both numbers. |
| **Research** | When the profile suggests no fix — the algorithm, the API's documented cost, what upstream did. |

Two rules matter more than the loop: a change that didn't move the number **gets reverted**, and is reported as not having worked; and regressions are **reported plainly with the numbers**. A wrong result reported honestly is useful, a wrong result reported as a win costs somebody a day.

Because it refuses nothing, there is no dispatch gate to write — the prompt *is* the mode. That is also why it is a mode rather than a skill: the discipline has to survive the whole session, not one turn.

`improve` is the canonical name; `research`, `auto`, `optimize`/`optimise` and `i` are accepted as aliases, since those are the words people reach for when describing the loop. The [auto-router](./configuration.md) never downgrades an improve turn to the cheap model — its turns are judgement, and a short "re-run the benchmark" scores as easy precisely when the answer matters most.

### Where you can switch

| Surface | How |
|---|---|
| CLI | `--mode improve` (or `plan` / `build`) |
| TUI | `Tab` cycles build → plan → improve; `/mode improve` |
| Agent Console (`/`) | the mode button cycles the three |
| Gateway API | `"mode": "improve"` in the chat request body |

The FireMonkey desktop client has no mode toggle and does not send `mode`, so its turns run in build mode as before.
