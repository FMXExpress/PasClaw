# Benchmarking the agent in-repo: the plan

The ask: improve the agent's effectiveness by benchmarking it *inside the
sandbox it develops in* — no external services, results as CI gates, so
every future "this makes the agent better" claim arrives with a number.

The week's optimization work (parallel-batch rule #537, SerialOnly #538,
MCP compact results, progressive disclosure, the turn clock #543) shipped
on mechanistic arguments: *this should reduce round trips / tokens /
races*. None of it has a measured effect. That is the gap this plan
closes — not by building a benchmark from scratch, but by wiring together
the substantial pieces that already exist.

## Census: what already exists (measured, not assumed)

| asset | where | state |
|---|---|---|
| Scripted in-process provider (`TScripted: ILLMProvider`, AddToolRound / AddStop / AddTruncated) | `src/tests/progress_ledger_tests.pas` | working, test-local |
| Per-turn metric taps: `Iterations`, `TotalUsage` (incl. **CacheRead/CacheCreated tokens**), `Truncations`, `TruncatedBytesSaved`, `ToolCallsDispatched`, `HitMaxIterations` | `TToolLoopResult` | populated every turn; surfaced in TUI `/stats` + gateway usage |
| Context hygiene: per-turn hash-aware read dedup (`DedupRepeatRead`, C3), stale-read stubbing after writes (`StubSupersededReads`), output caps (`OutputCache`), compaction | `PasClaw.Tools.ToolLoop` | shipped, untested for *effect* |
| Loop seams exported for tests | `PartitionToolBatches`, `HistWithTurnClock` | unit-benchable today |
| `pasclaw membench` | `src/pkg/membench` | I/O throughput only |
| SWE-shaped fixture bench: 13 fixtures + oracle tests, ablation grid, stub provider over HTTP, Pareto report | PR **#313** (`bench/swe/`) | **orphaned history — no merge base with main.** Mine it, don't merge it |
| LOCOMO-shaped memory recall bench | PR **#308** (`bench/locomo/`) | same situation, same treatment |

**Correction to the earlier Bullet evaluation:** it claimed PasClaw has "no
re-read guard". Wrong — `DedupRepeatRead` (C3) dedupes repeat reads of
unchanged files within a turn, and `StubSupersededReads` retires stale
reads after writes. What is genuinely missing is *cross-turn* dedup, and —
everywhere — measurement.

## What "inside yourself" can and cannot measure

Two boundaries, stated up front rather than discovered later:

- **Harness-level properties** (round trips, bytes, parallelism, prompt
  byte-stability, hygiene behaviors, cost accounting) are fully measurable
  in-sandbox with a scripted provider. The model is held constant by
  *being a script*, so every delta is attributable to the harness. This is
  most of the plan.
- **Model-dependent effects** (does rule 7 actually change how a model
  batches; does disclosure change which tools it picks) need a live
  provider. The sandbox reaches the network through the HTTPS proxy, so
  this tier runs here too — but only once an API key is configured. It is
  a costed, opt-in tier, not a prerequisite: the harness tiers land first
  and stand alone.

## The plan

### P0 — the bench record (plumbing; taps exist)
One opt-in flag (`PASCLAW_BENCH_JSONL=<path>`): at end of each turn the
loop appends one NDJSON record — everything already in `TToolLoopResult`,
plus two new cheap counters:
- per-iteration request size in bytes, and
- **prefix stability**: was this iteration's system prompt byte-identical
  to the previous one's (the ledger's "NO counters, no timestamps" hard
  constraint, turned from a comment into a measured invariant).
No behavior change; a record per turn.

### P1 — in-process loop bench as a CI gate (`make bench-loop`)
Promote `TScripted` out of the ledger test into a shared unit and drive
`RunToolLoop` through scenario scripts, each with a committed budget the
run must meet — a benchmark that *fails*, not one that prints:

| scenario | budget it pins |
|---|---|
| 3 sleeping read-only tools in one scripted response | wall time ≈ max(tool), not sum — parallel dispatch works end-to-end, not just in `PartitionToolBatches` |
| 50-iteration scripted turn | system prompt byte-identical across iterations 2..50 (prefix-cache proxy) |
| repeat read of an unchanged file | second result is the C3 dedup stub |
| write then re-read of the same path | `StubSupersededReads` fired |
| oversized tool outputs | history growth ≤ cap-derived budget; `TruncatedBytesSaved` > 0 |
| SerialOnly writer between reads | three batches, writer alone (#538's property, end-to-end) |

Budgets live in a committed baseline JSON; a regression turns the target
red. This is where "the harness got slower/noisier" becomes visible at PR
time instead of at the operator's desk.

### P2 — mine the orphaned fixture bench (PR #313 → `bench/swe/` on main)
The 13 fixtures, oracle tests, ablation grid and Pareto report are real
work sitting on a branch that can never merge (no common ancestor).
Extract with `git checkout origin/claude/swe-bench-harness-v2 -- bench/swe`
onto a fresh branch, re-verify its runner against today's CLI flags, and
land it as the fixture tier: pass-rate × cost frontier across settings
(`ablation.json`), scripted provider, no network. Then close #313 with a
pointer to the landed commit, and give #308 (`bench/locomo/`) the same
mine-or-close treatment against `memory_search`.

### P3 — the live-model tier (opt-in, needs a key)
10–20 curated tasks *on this repo* with deterministic oracles (build
passes, grep asserts a symbol, test goes green) — the shape of work this
session actually did. Sweep the shipped levers A/B and report per variant:
pass rate, `Iterations` (round trips — the Bullet number), `TotalUsage`,
cache-read ratio, wall time:
- rule 7 (batch prompt) on/off — *the* unmeasured claim from #537
- progressive disclosure on/off — token delta
- MCP compact results on/off — token delta on tool-heavy tasks
- autorouter weight presets

Gated on an API key in config; the harness prints a cost estimate before
running and refuses without an explicit `--spend` acknowledgment.

### P4 — the backlog the bench adjudicates
Ranked hypotheses, each landing **only with its bench delta attached**:
1. Cross-turn read dedup (C3 is per-turn; `FinalMessages` already flows
   back, so the state could persist).
2. Attachment/screenshot eviction (stale binary blobs have no
   `StubSupersededReads` equivalent).
3. Condense trigger tuning (threshold vs. measured token headroom).
4. Tool-description budget (the catalog is part of every request; measure
   its share of request bytes in P0 data first).

## Sequencing

P0 → P1 land together (one PR: record + gate). P2 is independent and
parallel. P3 waits on a key and on P0's record format. P4 items are
individual PRs, each blocked on showing its number from P1/P2/P3.

## Non-goals

- Vendoring public SWE-bench/Terminal-Bench datasets (Docker + licensing;
  #313's README already made this call and it stands).
- LLM-as-judge scoring — every oracle here is deterministic.
- Benchmarking Studio/UI (different track entirely).
