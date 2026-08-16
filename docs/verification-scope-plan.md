# Verification scope reporting — plan

The survey's "gap nobody has" (docs/agent-features.md): **no surveyed system
reports what its verification did not cover.** Every tool answers *did this
succeed*; none answers *what did I not look at*. The field's literature blames
agents that "mark a task complete without verifying the outcome" and attributes
65% of enterprise failures to harness defects — and every proposed remedy is
*more* verification, never honest reporting of verification's *scope*.

This plan makes PasClaw the counterexample. Not more checking — checking that
says what it skipped.

## Evidence this matters (all from one review cycle, this repo)

1. **`make test-json-utf8-roundtrip` reported OK on five tests that never
   ran.** The procedures were defined but not called from the main block. The
   runner verified its own exit code, reported green, and had no concept of
   "cases defined vs cases executed." (Codex P2 on #558.)
2. **Four `[P]` survey rows were wrong in the same direction.** Each came from
   checking one call-site and generalising. The notation records *that* a check
   happened, never *how far it looked* — so a shallow check and a thorough one
   are indistinguishable on the page. (Codex on #559.)
3. **`execute_tool` spans emit only on the serial dispatch path.** A trace
   consumer sees a complete-looking trace with the parallel calls silently
   absent, and nothing in the trace says so. (docs/observability.md, known.)
4. **`grep_files` answers `(no matches)` identically** whether it scanned every
   file or skipped the decisive one via the size cap, binary detection, or the
   VCS/build dir skip list (Tools.FS.pas tiers). "Searched and absent" and
   "never looked" are the same string.

One partial precedent already in-tree: `pasclaw learn` prints "scanned N
session(s)". That is the shape — extend it everywhere.

## Principle

> A verification result is a triple: **verdict, scope, exclusions.**
> A verdict without scope is an anecdote, not evidence.

Reporting must be honest, cheap, and unskippable-by-default:

- **Honest**: exclusions state *why* (size cap, binary, permissions, timeout,
  parallel path, unparseable) — not just a count.
- **Cheap**: one trailing line or a couple of span attributes. The scope report
  must never cost more context than the result it qualifies.
- **Default-on**: a scope line that must be requested will not be requested.
  (Same argument that made promptware scanning default-on.)

## Tier 0 — the lint that would have caught #558 (smallest, do first)

`scripts/check-test-invocation.py`, precedent `check-pascal-shape.py`:

- For every `src/tests/*.pas`: parse `procedure Test*` definitions, parse the
  main `begin…end.` block, fail if any defined test is never invoked.
- Wire into `make test` ahead of the suites (and a standalone
  `make lint-tests`).
- Acceptance: re-introduce the #558 defect (comment out one call) → red.
  Current tree → green. This turns the motivating incident into a regression
  guard for the entire defect class.

Size: ~a day, no runtime code touched.

## Tier 1 — scope envelopes on tool results (the core, highest leverage)

The model reads tool results; that is where scope reporting changes agent
behaviour. Order by usage frequency:

1. **`grep_files`**: append one line —
   `scope: scanned=812 skipped=37(size:9,binary:21,dirs:7) truncated=no`.
   The skip counters already exist implicitly at each tier boundary in
   Tools.FS.pas; this surfaces them. `(no matches)` alone is no longer a
   possible output.
2. **`find_files`**: dirs pruned by the skip list / permissions, and whether
   the 400-dir visit cap fired.
3. **`read_file`**: when a range or cap truncates, state
   `scope: bytes 0-65536 of 1203441` so a partial read can never pass as the
   whole file.
4. **`memory_search` / `kb`**: corpus denominator — chunks searched, index
   age, files that failed indexing. "No relevant memory" must be
   distinguishable from "index is stale/empty."
5. **`web_fetch`**: content truncation and redirect hops taken.

Mechanics: a small shared helper (`FormatScopeLine`) so the format is uniform
and tested once; per-tool tests assert the line on fixtures that *contain*
exclusions (an oversized file, a binary, an unreadable dir). Token cost: one
line per result; measure before/after on a session transcript to confirm the
overhead stays under ~1%.

Size: one PR per tool, `grep_files` first; each independently shippable.

## Tier 2 — trace completeness (prerequisite for every eval idea)

1. Thread the W3C traceparent through parallel workers so `execute_tool`
   spans emit on both dispatch paths (the known limitation in
   docs/observability.md — flagged as a follow-up in Tools.ToolLoop.pas).
2. Until and after that lands: `agent.turn` span carries
   `tools_total` / `tools_traced`. A consumer can *detect* a partial trace
   instead of silently scoring it as whole — this is the scope-reporting
   version of the fix, and it stays useful even after coverage reaches 100%
   (it proves it).
3. Session stats surface trace coverage %, so the gap is visible in
   `pasclaw stats`, not only in an OTel backend.

Ordering note: survey gap 9 (trajectory evaluation) is blocked on this —
corrected in pass 17 to say so. Do not build trace-consuming evals first.

## Tier 3 — the loop reports its own scope

1. **Improve mode**: the pmImprove directive (Agent.Mode.pas) gains one
   required element: *"State explicitly what you did NOT check."* The mode
   that demands measurement now demands scope. Text-only change.
2. **`learn`**: alongside "scanned N sessions", report sessions skipped as
   unparseable and messages dropped. (It already drops defensively; count it.)
3. **bench/swe** (unmerged branch): before any number is published, every
   oracle reports what it verified and what it assumed — ties to the existing
   note that oracles "verify more than their own exit code."

## Tier 4 — notation for humans

The survey's `[P]` mark gets a scope suffix: `[P:ran]` (executed the code),
`[P:read]` (read the implementation), `[P:grep]` (searched for symbols).
Pass 17 showed all four wrong rows were shallow checks presenting as deep
ones; the notation now records depth. Applied to new/edited rows immediately,
back-filled opportunistically.

## Sequencing

| Step | Item | Size | Unblocks |
|---|---|---|---|
| 1 | Tier 0 lint | day | closes the #558 defect class |
| 2 | `grep_files` scope line | small PR | the pattern + helper everything else reuses |
| 3 | `find_files`, `read_file` lines | small PRs | — |
| 4 | `tools_total/tools_traced` attrs | small PR | partial-trace detection |
| 5 | traceparent through workers | medium PR | all trace-based evals (gap 9) |
| 6 | improve-mode "not checked" clause + learn counters | tiny | loop-level honesty |
| 7 | memory/kb denominators, web_fetch | small PRs | — |
| 8 | bench oracle scope | with bench merge | publishable numbers |

## Success criteria

- The #558 scenario cannot recur silently (Tier 0 red).
- A `grep_files` over a fixture with an oversized decisive file reports the
  skip, and the agent's next action visibly differs (raises the cap or reads
  the file directly) — the point is behaviour change, not decoration.
- A parallel-dispatch turn's trace declares `tools_traced < tools_total`
  today, and equality after step 5.
- Token overhead of scope lines measured at <1% on a real session.
- The survey's "gap nobody has" section gains: *"PasClaw ships it"* — with
  `[P:ran]` evidence.

## Why this fits PasClaw

The two features the survey found nowhere else — SCARS (mining failures back
into the prompt) and `--mode improve` (method as a mode) — are both *honesty
loops*: the harness telling itself the truth about what went wrong. Scope
reporting is the third member of that family: the harness telling itself the
truth about what it never looked at. It is cheap, it is differentiating, and
this repo has already paid — three times in one review cycle — for not having
it.
