# Benchmarking the agent in-repo: the plan

The ask: improve the agent's effectiveness by benchmarking it *inside the
sandbox it develops in* — no external services, results as CI gates, so
every future "this makes the agent better" claim arrives with a number.

The week's optimization work (parallel-batch rule #537, SerialOnly #538,
MCP compact results, progressive disclosure, the turn clock #543) shipped
on mechanistic arguments: *this should reduce round trips / tokens /
races*. None of it has a measured effect. That is the gap this plan
closes — almost entirely by **extending a harness that already exists**.

> **Revision note.** The first draft of this plan proposed a new
> `make bench-loop` target and an in-process scenario suite. That was
> written from an incomplete census: `bench/agentloop/` already exists and
> already implements most of it. Codex caught this on PR #544 along with
> three concrete design errors, all corrected below. The corrections are
> kept visible because "we already had one" is the single most useful
> thing this document can tell the next person.

## Census: what already exists (verified against the tree)

| asset | where | state |
|---|---|---|
| **`make bench-agentloop` — deterministic loop harness, 9 scenarios** | `bench/agentloop/` | **working today.** Spawns the built binary, plays a scripted model over the relay provider, asserts on what the loop did. Zero API cost, fully reproducible |
| Its scenarios | `build-site`, `malformed-recovery`, `fatread`, `resume-after-cap`, `repeatread`, `realtask`, `error-guidance`, `truncation-recovery`, `history-elision` | already cover ledger fold + iteration-1 pristine, output cap, C3 repeat-read dedup, compaction, resume ledger |
| Its metrics | `provider_calls`, `first_request_bytes`, `max_request_body_bytes`, `total_request_bytes`, `growth_bytes_over_2_rereads` | context growth is *already* measured |
| Scripted in-process provider (`TScripted: ILLMProvider`) | `src/tests/progress_ledger_tests.pas` | second, lighter substrate — in-process, no port/binary |
| Per-turn metric taps: `Iterations`, `TotalUsage` (incl. cache read/created), `Truncations`, `TruncatedBytesSaved`, `ToolCallsDispatched`, `HitMaxIterations` | `TToolLoopResult` | populated on every real turn; surfaced in TUI `/stats` + gateway |
| Context hygiene: `DedupRepeatRead` (C3, per-turn, hash-aware), `StubSupersededReads`, `OutputCache`, compaction | `PasClaw.Tools.ToolLoop` | shipped |
| Exported loop seam: `PartitionToolBatches` | `PasClaw.Tools.ToolLoop` | unit-benchable today |
| Exported loop seam: `HistWithTurnClock` | PR **#543**, *not yet on main* | **prerequisite, not an asset** — scenarios using it are blocked on that merge |
| SWE-shaped fixture bench: 13 fixtures, oracles, ablation grid | PR **#313** (`bench/swe/`) | **orphaned — no merge base with main.** `bench/agentloop/README.md` already links `../swe`, so that link dangles on main today |
| LOCOMO-shaped memory recall bench | PR **#308** (`bench/locomo/`) | same situation |
| `pasclaw membench` | `src/pkg/membench` | I/O throughput only |

**Two corrections to earlier claims of mine.** (1) The Bullet evaluation
said PasClaw has "no re-read guard" — wrong; `DedupRepeatRead` and
`StubSupersededReads` both exist, and `repeatread` already benches the
first. (2) `HistWithTurnClock` was listed as benchable today; it lives on
an open PR.

## What "inside yourself" can and cannot measure

- **Harness properties** (round trips, bytes, parallelism, prompt
  byte-stability, hygiene behaviours) are fully measurable in-sandbox —
  the model is held constant *by being a script*, so every delta is
  attributable to the harness. This is most of the plan and needs no key.
- **Model-dependent effects** (does rule 7 actually change how a model
  batches; does disclosure change tool choice) need a live provider. The
  sandbox reaches the network through the HTTPS proxy, so this runs here
  too — but it is a costed, opt-in tier, never a prerequisite.

## The plan

### P1 — extend `bench/agentloop` (no new target, no new harness)

The existing target stays the one entry point. What is missing are
scenarios for the things shipped this week, each with a committed budget
so the bench **fails** rather than prints:

| new scenario | what it pins | why it is new |
|---|---|---|
| `parallel-batch` | three sleeping read-only tools in one scripted response finish in ≈ max(tool), not sum | `PartitionToolBatches` is unit-tested; that it actually runs concurrently *end to end* is not |
| `serial-writer` | a `SerialOnly` writer between two reads yields three batches, writer alone | #538's property, currently only asserted at the unit seam |
| `superseded-read` | script **read → write** of one path, then assert the *earlier* read body was replaced by the stub | corrected: `StubSupersededReads` rewrites reads that came **before** a write. The first draft had this backwards (write → read), which would have tested nothing |
| `prefix-stability` | the folded system prompt is byte-identical **within a ledger-state-stable window**, and the one permitted transition happens exactly at `LedgerNudgeAfter` (8 calls) and nowhere else | corrected: a flat "iterations 2..50 identical" budget fails *by design* — `FormatLedgerBlock` adds sticky nudge text once `TotalCalls >= 8`. The budget must model the transition, not forbid it |
| `turn-clock` | every request in a tool-using turn carries the clock, and all carry the *same* reading | **blocked on #543 merging**; the seam does not exist on main |

### P0 — production bench record (distinct from bench metrics)

`bench/agentloop` emits `Metric(...)` lines *at bench time*. P0 is
different: an opt-in `PASCLAW_BENCH_JSONL=<path>` that appends one NDJSON
record per **real** turn from the taps already in `TToolLoopResult`, so
field behaviour can be compared against bench expectations. Small, and it
is what makes P3 measurable at all.

### P2 — mine the orphaned fixture benches

`bench/swe/` (13 fixtures, oracles, ablation grid) is real work on a
branch that can never merge — and `bench/agentloop/README.md` already
links to it, so main ships a dangling reference. Extract with
`git checkout origin/claude/swe-bench-harness-v2 -- bench/swe` onto a
fresh branch, re-verify the runner against today's CLI flags, land it,
close #313 pointing at the landed commit. Same treatment for #308.

### P3 — the live-model tier (opt-in, needs a key)

10–20 curated tasks *on this repo* with deterministic oracles (build
passes, grep asserts a symbol, test goes green). Sweep the shipped levers
A/B, reporting per variant: pass rate, `Iterations` (round trips — the
Bullet number), `TotalUsage`, cache-read ratio, wall time:

- rule 7 (batch prompt) on/off — *the* unmeasured claim from #537
- progressive disclosure on/off, MCP compact results on/off — token delta
- autorouter weight presets

Prints a cost estimate and refuses without an explicit `--spend`.

### P4 — the backlog the bench adjudicates

Each lands **only with its bench delta attached**: cross-turn read dedup
(C3 is per-turn), attachment/screenshot eviction (no `StubSupersededReads`
equivalent for binaries), condense trigger tuning, tool-description budget
(measure its share of request bytes from P0 data first).

## Sequencing

P1 first — it is additive to a working harness and needs nothing else.
P0 next (independent, small). P2 is parallel and independent. The
`turn-clock` scenario waits on #543. P3 waits on a key and on P0's record
format. P4 items are individual PRs, each blocked on showing a number.

## Non-goals

- Vendoring public SWE-bench/Terminal-Bench datasets (Docker + licensing;
  #313's README made this call and it stands).
- LLM-as-judge scoring — every oracle here is deterministic.
- A second loop-bench harness or target name. There is one:
  `make bench-agentloop`.
