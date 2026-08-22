# Stats collection: measurement, verification, and a plan

Method: benchmark → profile → verify → research → improve. Every number
below came from a run in this repo; every behavioural claim was checked
against a running gateway rather than read off a comment. Where I could
not check something, it says so.

Harness: `make bench-stats` (`src/tests/stats_bench.pas`). It prints
timings and is deliberately **not** in the `test` aggregate — it is a
measuring tool, not a pass/fail suite.

---

## 1. Benchmark

`GET /v1/stats` aggregates across every session under
`workspace/sessions/`. Cost against session count, 20 turns each:

| sessions | on disk | `/v1/stats` walk | per session |
|---:|---:|---:|---:|
| 10 | 0.2 MB | 5.0 ms | 0.50 ms |
| 100 | 1.7 MB | 50.3 ms | 0.50 ms |
| 500 | 8.3 MB | 272.5 ms | 0.55 ms |
| 2000 | 33.1 MB | 1238.0 ms | 0.62 ms |

Linear in session count. The slight per-session drift (0.50 → 0.62 ms)
is the two O(N²) shapes in `ListSessions` — `SetLength` growing the
result one element at a time, and the insertion sort — but they are not
the dominant cost at these sizes.

## 2. Profile

Holding session count at 500 and varying transcript length separates
per-file cost from per-byte cost:

| turns/session | on disk | `/v1/stats` walk |
|---:|---:|---:|
| 1 | 0.6 MB | 38.6 ms |
| 20 | 8.3 MB | 273 ms |
| 100 | 40.6 MB | 1054 ms |
| 400 | 162 MB | 4318 ms |

**~26 ms per MB. Fixed per-file cost is 0.077 ms.** So at any realistic
transcript size, essentially all of the endpoint's cost is reading and
JSON-parsing message bodies.

`HandleStats` uses none of them. It sums seven `Int64`s out of
`Meta.Stats` and two string fields for the rollups. `ListSessions` loads
each full session to get them — as its own comment concedes:

> Load only the meta; this is wasteful but the sessions tree is
> typically small (10s to low 100s) … If it grows: write a "headers
> only" Load.

The measurement says the escape hatch is now needed. At 500 × 400 turns
the walk takes 4.3 s behind a 5-second cache, so a web UI that
auto-refreshes keeps the gateway recomputing ~86% of wall-clock.

End-to-end confirmation on a real gateway, 300 sessions × 40 turns:

```
cold  HTTP 200  total=0.253s     ← matches the 225 ms micro-benchmark
warm  HTTP 200  total=0.00098s   ← 5 s cache working as designed
```

## 3. Verify

### Works

- Counters are collected and persisted correctly. 300 seeded sessions
  summed to exactly the expected 4,515,000 input / 2,257,500 output.
- The 5-second cache works: 253 ms → 0.98 ms.
- `by_provider` / `by_model` rollups sum correctly.
- `StatsCollectionEnabled` gates all four write sites consistently
  (gateway, TUI, and two in `Cmd.Agent`).
- Gateway bucket sessions are transcript-free, so opting them in with
  `IncludeBuckets=True` costs almost nothing.

### Broken or wrong

**a. The collection-off comment is false.** `HandleStats` says:

> When `Cfg.StatsCollectionEnabled` is False the rollups will all read
> zero (the per-session counters were never incremented) … the web UI
> shows zeros with a "stats collection is off" hint.

Verified with the flag genuinely off (`config get` confirmed `false`)
against a corpus with history:

```json
{ "stats_collection_enabled": false, "sessions": 300,
  "input_tokens": 4515000, "output_tokens": 2257500, ... }
```

Full historical totals, not zeros. The premise only holds for a home
where collection was *never* on. An operator who turns it off for
privacy still has every number served, and a UI captioning that with
"collection is off" is actively misleading.

**b. Turning collection off does not make the endpoint cheap.** Same
run: 0.258 s. The full-corpus read is unconditional.

**c. `diagnostics.otel.metrics` and `.logs` are dead knobs.** Both are
defaulted, parsed, serialised and round-tripped in `PasClaw.Config`, and
**no code outside config ever reads them**. `PasClaw.Otel.pas` has 105
references to `Span` and zero to counter/histogram/gauge. Worse, their
only other reference in the tree is `otel_tests.pas:382-416`, which
asserts the flags *survive serialisation* — a test that makes a
non-functional switch look tested.

**d. No time dimension.** `TSessionStats` is seven cumulative `Int64`s
with no timestamps. "What did I spend today" is unanswerable: a
session's counters span its entire life, so even bucketing by
`UpdatedAt` attributes a month-old session's whole total to today.

**e. No cost model anywhere.** A repo-wide search for pricing turns up
nothing. Yet the rollup's stated purpose is:

> so the operator can see which provider is eating the budget

It reports `InputTokens + OutputTokens` as one number. Output typically
costs ~5× input and cache reads ~10× less, so summed tokens are not
budget, and the two providers this ranks may invert once priced.

**f. No latency, no error counters.** Nothing measures turn duration or
counts failures/retries, so stats cannot answer "is it slow" or "is it
failing" — only "how much".

**g. No reset or prune.** Counters only grow.

**h. Two different session counts for one corpus.** `/v1/stats` opts
into bucket sessions and reported `"sessions": 300`. Every other surface
hides them — confirmed by running `pasclaw learn` against the same home:

```
pasclaw learn -- scanned 240 session(s)
```

300 vs 240 on identical data. The field is unqualified, so the same
corpus has two "session counts" depending on where you look.

### Doesn't make sense

`truncation_bytes_saved` is a top-level headline field alongside token
counts. It is a niche internal diagnostic about tool-output trimming,
promoted to the same rank as spend — while spend itself is absent.

## 4. Research

What comparable harnesses do, and what transfers:

- **Cost computed locally from token counts at list rates**, stated as
  an estimate that may not match the bill. Claude Code's `/usage` prints
  `$0.55` beside `1.2k input, 5.3k output, 940.0k cache read, 50.0k
  cache write`. This is the single largest gap here.
- **Per-model breakdown keeps the four token classes separate** rather
  than summing them — which is exactly what makes local pricing possible.
- **Time windows**: a 24-hour / 7-day toggle, with a defined reset
  boundary (a new session resets the session total).
- **Attribution beyond provider/model**: usage attributed to skills,
  subagents, and individual MCP servers.
- **OTel metrics are the interop standard.** GenAI semantic conventions
  define `gen_ai.client.token.usage` with a `gen_ai.token.type` attribute
  of `input`/`output`, as a histogram with powers-of-four bucket
  boundaries. Three signals is the normal shape: traces for the loop,
  metrics for tokens and cost, logs for audit. PasClaw has the first and
  neither of the others.

## 5. Plan

Ranked by evidence strength and payoff.

### P1 — Headers-only session load

Add a meta-only read path and use it from `ListSessions`. Parsing stops
after the metadata object instead of materialising every message.

Expected: the 26 ms/MB term collapses toward the 0.077 ms/file floor —
roughly 4318 ms → tens of ms at 500 × 400 turns. `make bench-stats`
already measures exactly this, so the claim is falsifiable before and
after. Fixing the two O(N²) shapes in the same pass is cheap: presize
the result array and use a real sort.

*Risk:* `ListSessions` feeds the TUI pane and `pasclaw session list`
too. Both use only `Meta`, but that must be confirmed per caller rather
than assumed.

### P2 — Split the token classes in the rollups

Emit `input`, `output`, `cache_read`, `cache_created` per provider and
per model instead of one summed `tokens`. Pure addition to the JSON;
nothing needs removing. This is the prerequisite for cost.

### P3 — Local cost estimation

A price table keyed by provider+model, four rates per entry, and a
`cost_usd` beside each rollup. Must be labelled an estimate at list
rates. Without P2 this cannot be done correctly at all.

*Open question for the operator:* ship a built-in price table (accurate
today, stale later) or require operator-supplied rates in config
(always right, nobody fills it in)? A built-in table with a config
override is the obvious default, but it is a maintenance commitment.

### P4 — Fix the collection-off path

Two small corrections: make `HandleStats` return zeros (or omit the
rollups) when collection is off, so the response matches its own
caption; and skip the walk entirely in that case, which also makes
"off" genuinely cheap. Then correct the comment.

### P5 — Honest session count

Report `sessions` and `bucket_sessions` separately, so `/v1/stats` and
`pasclaw session list` stop disagreeing.

### P6 — Wire the OTel metrics flag, or delete it

Either implement `gen_ai.client.token.usage` behind
`diagnostics.otel.metrics` following the GenAI conventions, or remove
the flag and its round-trip test. Shipping a config switch that does
nothing, with a test that makes it look covered, is worse than not
having it.

### P7 — A time dimension

The structural one, and the one I'd think hardest about before
building. Per-day rollup rows written on each turn would answer "today"
and "this week" and make P1 nearly moot for the common query, since the
scan becomes O(days) not O(corpus). It is also the largest change — a
new on-disk structure with its own migration and pruning story.

*Recommendation:* do P1–P5 first. They are small, measurable, and make
the existing feature honest. Revisit P7 once there is a reason beyond
symmetry with other tools.

---

## What this did not cover

- **Only the FPC/Linux build was exercised.** The Delphi build was not
  run; no Delphi toolchain in this container.
- **The web UI and TUI stats surfaces were read, not driven.** Claim (a)
  about a misleading caption is inferred from the code comment's own
  description of the UI, not from watching the UI render.
- **Synthetic corpus.** Sessions were generated with uniform 800-byte
  turns. Real transcripts have tool results, images and wide size
  variance, so absolute milliseconds will differ; the *shape*
  (cost ∝ bytes) is what the profile establishes.
- **No concurrency testing.** `HandleStats` notes two threads can enter
  at once; the cache lock was read but never raced.
- **Cost estimates in P3 are unpriced.** No provider price list was
  gathered or validated — that is part of the work, not an input to it.
- **P1's projected speedup is a prediction, not a measurement.** It
  follows from the profile, but nothing has been implemented or
  re-benchmarked.
