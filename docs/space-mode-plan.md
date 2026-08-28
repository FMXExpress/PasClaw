# SPACE mode: a plan

**Search → Plan → Assert → Code → Evaluate**, as a fourth agent mode
beside build, plan, and improve.

The acronym is not public canon; it is the shared skeleton of three
skillsets that arrived at the same shape independently — Obra's
superpowers (brainstorm → worktree → micro-task plan with verification
steps → execute via subagents, mandatory TDD), Matt Pocock's skills
(grilling before code, red-green-refactor without prompting, dual-axis
review against standards and spec), and the high-autonomy skill packs
built on the same bones. What they share:

| phase | the discipline |
|---|---|
| **S**earch | find what already exists before designing — codebase, memory, KB, prior sessions, the web. Do not design what can be found. |
| **P**lan | write the plan down, in steps small enough that each has a check. |
| **A**ssert | define success *before* implementation: the failing test, the executable acceptance criterion, shown failing. |
| **C**ode | the minimum that makes the assertion pass. |
| **E**valuate | run the assertion, review against the plan, state what was not covered, loop or finish. |

## How SPACE differs from Improve

Improve already exists (`pmImprove`, `PasClaw.Agent.Mode.pas:92`,
prompt at `PasClaw.Agent.Prompt.pas:1018`) and is deliberately
prompt-only: full tool access, with a method imposed —
benchmark → profile → change one thing → re-measure.

They are not the same loop wearing two names:

|  | Improve | SPACE |
|---|---|---|
| for | making existing behaviour measurably better | building new behaviour correctly |
| ground truth | a **measurement of what exists**, taken before touching anything | an **assertion written before the code exists** |
| shape | symmetric: before → after of the *same* number | asymmetric: red → green of a check that was not there before |
| cardinal sin | changing more than one thing per measurement | writing code before its assertion exists |
| terminal state | the number moved (or the change is reverted) | the assertion passes and the plan is accounted for |
| shared | both end with Evaluate's honesty rules: report regressions plainly, state what the check did **not** cover | |

The failure Improve prevents: changing code that looks slow, declaring
it faster, never measuring either end. The failure SPACE prevents:
building the wrong thing confidently — code first, tests written after
to match what the code happens to do, "works" asserted against nothing.

They also start from opposite ends: Improve begins from a number the
world already produces; SPACE begins from a check the world cannot yet
pass.

## Why a mode and not a skill

Same argument the Mode unit already makes for Improve
(`PasClaw.Agent.Mode.pas:31-38`): a discipline that must survive the
whole session belongs in the mode, not in a skill that colours one
turn. And SPACE has something Improve does not: **one of its rules is
mechanically enforceable with primitives that already exist** — which
is the strongest reason to put it in the dispatch path rather than
purely in prose.

## Design

### 1. `pmSpace` — enum, parse, cycle, all surfaces

Append `pmSpace` to `TPasClawMode` (append, never insert — the enum
comment documents why ordinals must not shift). `ModeName`/`ParseMode`
accept `'space'`; `CycleMode` grows the TUI Tab cycle to
build → plan → improve → space. Because the gateway parses the mode
from the request body (`ParseModeFromBody`) and the CLI from `--mode`,
every surface — `pasclaw agent`, TUI, `/v1/chat`,
`/v1/chat/completions`, `/v1/responses`, and the relay riding those
endpoints — gets the mode for free once the enum parses.

### 2. The plan gate — the mechanical rule

In `pmSpace`, **mutating tools are refused until `plan_write` has been
called in this session**. This is the one SPACE rule that is cheap and
robust to enforce, and every primitive already exists:

- the dispatch gate pattern: `ToolLoop.pas:724` already refuses
  `tcMutating` tools under `pmPlan` via `PlanModeRefusal`;
- the gate key: `plan_write` is deliberately `tcReadOnly`
  (`Tools.PlanWrite.pas:212`) precisely so it passes the plan gate —
  so "read-only until the plan is written" needs one boolean on the
  loop state (`PlanWritten`), set where `plan_write` dispatches,
  checked where the pmPlan gate already checks;
- the payoff loop: `PLAN.md` written by `plan_write` is the same file
  the Active Plan pickup injects (`Agent.Prompt.pas:94-96`), so the
  plan the gate demanded is the plan the rest of the session is held
  to.

Effect: Search and Plan phases are naturally read-only (all search
tools — `grep_files`, `memory_search`, `kb_search`, `session_search`,
`web_search` — are `tcReadOnly` and flow freely); the first mutation
the mode permits is writing the plan; everything after is unlocked by
having done so. A `SpaceModeRefusal` mirrors `PlanModeRefusal`:
*"space mode: write the plan first (plan_write), then X unlocks."*

Loop-scoped, not process-global, for the same reason the mode itself
is (`Agent.Mode.pas:50-53`): two concurrent gateway requests may be in
different modes, or at different points in the same mode.

### 3. Assert and Evaluate — prompt discipline, stated honestly

"Test ran red before the code existed" is **not** robustly detectable
across languages and test runners from inside the tool loop, and a
brittle heuristic (guessing which `shell_exec` was a test, which files
are tests) would refuse legitimate work. So Assert stays at prompt
level, the way Improve's "change one thing" does — but the prompt
demands evidence, not intent:

`BuildSpaceModeSection` (mirroring `BuildImproveModeSection`'s shape
and register):

1. **Search first.** Name what you looked for and where — the
   codebase, memory, KB, past sessions, the web. What you found
   constrains the plan; "nothing found" is a finding to state.
2. **Plan in checkable steps** via `plan_write`. Until the plan is
   written, mutating tools are refused — that is the mode, not a
   suggestion.
3. **Assert before code.** For each step, write the check first and
   **show it failing** — quote the command and the red output. A check
   that was never seen red proves only that it passes, not that it
   tests anything.
4. **Code to the assertion.** The minimum that turns it green. Scope
   creep goes back through the plan, not around it.
5. **Evaluate with the same command.** Same check, re-run, quoted
   green. Then the two honesty rules shared with Improve: report
   regressions plainly with output, and state what the checks did
   **not** cover — the case the test does not reach is the first thing
   the next person needs to know.

Never claim red or green output that was not produced in this session.

### 4. Tests

`space_mode_tests.pas`, following the existing suites' shape:

- parse/name/cycle round-trip for `'space'`; `ParseModeFromBody`
  accepts it; unknown strings still default `pmBuild`.
- **the gate**: under `pmSpace`, a `tcMutating` tool is refused before
  `plan_write` and dispatches after it; `tcReadOnly` tools flow freely
  throughout; `pmBuild`/`pmImprove` behaviour unchanged.
- refusal text names `plan_write` (the message is the UX).
- prompt section: present under `pmSpace`, absent under `pmBuild`.
- **negative-tested**: each gate assertion verified to fail against a
  build with the gate disabled, before it is trusted — twice this
  session a test passed for the wrong reason; the method is now
  standing procedure.

Wired into `.PHONY` **and** the `test:` aggregate, verified against
the aggregate line itself and `make -n test` (the loose-grep false
green is a documented scar).

### 5. Docs

`docs/commands.md` mode table; `AGENTS.md`/README mode list if they
enumerate modes; the TUI status-bar width check for `[mode: space]`.

## Open questions (decide at build time, flagged now)

- **Subagent propagation.** `pmPlan` is contagious downward. A SPACE
  child spawned during Code is doing a subtask of an already-planned
  step — inheriting the full ritual (search, plan, assert) per child
  is probably ceremony without value. Proposal: children inherit
  `pmBuild`, parent stays `pmSpace`; the parent's Evaluate covers the
  child's output. Needs a decision, not an accident.
- **Gate escape hatch.** A `--no-gate` variant (prompt-only SPACE)
  costs one flag and may matter for tiny tasks; but an opt-in mode
  arguably *is* the opt-in, and Build remains the default. Lean: no
  escape hatch in v1; revisit on friction.
- **Session resume.** `PlanWritten` is loop state. On `pasclaw resume`
  of a SPACE session whose PLAN.md exists, the gate should honour the
  existing plan (PLAN.md presence ⇒ gate open) rather than demand a
  second ritual. Cheap: seed the boolean from `FileExists(PLAN.md)`.

## What this plan does not claim

- No mechanical Assert enforcement — stated above, with the reason.
  Anyone who wants it later should start from "detect a failing test
  run" as its own researched problem, not bolt a heuristic onto this.
- Nothing here is built or measured yet. The gate's cost (annoyance on
  small tasks) and benefit (fewer wrong-thing-built sessions) are both
  predictions; the mode is opt-in precisely so its value can be judged
  from use rather than argued in advance.
- The three skillsets were surveyed from their public descriptions,
  not run head-to-head; the table of phases is a synthesis, not a
  quotation.

## Build order

| step | size | depends on |
|---|---|---|
| 1. enum + parse + cycle + prompt section | small | — |
| 2. plan gate in the dispatch path | small | 1 |
| 3. tests incl. negative pass | medium | 1, 2 |
| 4. resume seeding from PLAN.md | small | 2 |
| 5. docs + TUI status width | small | 1 |

One PR; steps are commits.
