# Upgrading the auto-router

What we can take from [experientiallabs/experiential](https://github.com/experientiallabs/experiential)
— an open-source gateway whose whole product is model routing — and what we
deliberately leave on their side of the fence.

Our router today (`PasClaw.Agent.AutoRouter`): cheap deterministic signals
(token count, tool mix, hard/easy keywords, a logistic structural score with
configurable weights), a binary decision — easy tier or primary — with an
abstain-to-primary bias, applied identically at every surface through
`ApplyAutoRoute`, and the primary prepended to the fallback chain whenever a
turn routes. That stance is sound, and it is *their* stance too. What we are
missing is everything around the decision: we cannot see it, we repeat routes
we already know fail, and nothing ever feeds back.

## How experiential routes

Frozen, offline-fitted, conservative. Per request the gateway reduces the
prompt to a canonical feature record (first user message + tools + context),
embeds it with a pinned embedding model — a real network call per request —
and runs a guarded k-NN against an immutable "evidence bank" whose cells hold
LLM-judge quality scores in [0,1] and measured costs for every candidate
model on similar past tasks. It selects the **cheapest candidate whose paired
quality difference versus the incumbent, minus an uncertainty margin, clears
a tolerance on at least eight agreeing neighbours** — and on any doubt falls
back to the incumbent with a **typed reason**: `novelty`,
`insufficient_pairs`, `neighbor_disagreement`, `uncertainty`,
`embedding_error`, `capability_eligibility`.

Around the decision:

- a **content-free ledger** — every attempt's route reason, fallback reason,
  terminal state, tokens, latency, cost; no prompt content, so it can be
  kept forever and studied freely;
- **stickiness** — a conversation keeps the model its first turn chose
  (24 h TTL, keyed per episode);
- **circuit breakers** per deployment — two failures opens the circuit, a
  429 throttles for 30 s, an auth error opens immediately, half-open probes
  recover;
- **capability vetoes** — a model that cannot do tools or the requested
  output ceiling is never selected, whatever the bank says;
- **hard budgets** — refuse at identity scope, sidestep at deployment scope;
  never silently downgrade the model to stay under budget.

The offline half — trace mining, world-model simulation of counterfactual
"how would model X have done", LLM judging under calibrated rubrics, sealed
held-out evaluation — is most of their codebase and all of their serving
cost.

## What we take, and what we refuse

We keep "heuristic, not a model". A per-request embedding call spends the
money the router exists to save; their economics are a platform's, ours are
a single binary's. We also do not take: world-model simulation, LLM-as-judge
quality labels, USD budget scopes, content guardrails.

We take the four things that cost little and fix observed pain:

1. **Typed reasons.** Every decision explains itself, and the explanations
   aggregate.
2. **Never route into known failure.** Circuits, capability vetoes, and
   per-session escalation memory.
3. **One cheap tier.** We currently have three overlapping mechanisms for
   "the small model".
4. **A content-free journal that can eventually tune the weights.** Their
   frozen-policy discipline — fit offline, apply explicitly, never learn
   online — at the scale of a logistic's weight vector instead of an
   embedding bank.

## Phase 1 — see the decision

*Observability. No behaviour change.*

- **`TRouteReason`** on every decision: `rrRouted`, `rrHardKeyword`,
  `rrOverLength`, `rrWriteToolAmbiguity`, `rrShortContinuation`,
  `rrBelowThreshold` (scored easy but vetoed), `rrDisabled`,
  `rrNoEasyProvider`. Returned by `RouteProvider`, surfaced in the CLI
  "(routed -> …)" line and the gateway response header next to the score.
  Today an abstention is silent, which makes the weights untunable: you
  cannot lower a threshold you cannot see the effect of.
- **Latency.** `DurationMs` on `TLLMResponse`, aggregated into
  `TToolLoopResult` alongside `TotalUsage`. The loop currently times
  nothing; every later phase wants this number.
- **Routing journal.** Append-only JSONL per workspace
  (`workspace/router/journal.jsonl`) — our house format, with the property
  that made their ledger safe: **no prompt content**. Per turn: timestamp,
  session id, score, reason, decided provider/model, outcome
  (`ok` / `fell_back` / `failed`), tokens, latency.
- **`/v1/stats` routing section**, riding on the per-(endpoint, provider,
  model) buckets from #586: route rate, fooled rate (routed turns that fell
  back to the primary), estimated tokens diverted, reason histogram.

## Phase 2 — stop repeating known failure

*The highest payoff per line.*

- **Circuit breaker on the easy tier.** Today, when the cheap provider is
  down, every easy turn pays a failed call plus fallback latency — and the
  next turn does it again, indefinitely. In-memory circuit per provider:
  two consecutive routed-turn failures open it for 30 s (config), one
  half-open probe recovers it; an auth failure opens it until the provider's
  config fingerprint changes (the fingerprint cache in
  `PasClaw.Agent.AutoRouter.Apply` already exists for hot-swap detection).
  The loop's retryable classification (0 / -1 / 408 / 429 / 5xx) is the
  failure signal.
- **Capability veto.** Their `capability_eligibility`, scaled down: do not
  route a turn to a tier that cannot do what the turn needs. First case:
  a web-bound turn on a tier whose provider lacks native grounding and has
  no `web_search` tool — the class of failure the grounding work on #588
  spent a week on. Checked via `SupportsNativeSearch`, the same signal the
  page path now uses.
- **Escalation memory.** Their per-episode stickiness, inverted to the cheap
  direction: a session whose routed turn was fooled (fell back mid-turn) is
  not routed cheap again for that session (bounded TTL / turn count).
  Sessions already have ids everywhere; this is a small map, not a cache of
  embeddings.

## Phase 3 — one cheap tier

We have three overlapping answers to "which small model":

| mechanism | consulted by |
|---|---|
| `fast_model` (config) | page turns, via `ResolveFastModel` |
| `AutoRouter.EasyProvider/EasyModel` | the router |
| `FastModelFor(kind)` literals | `ResolveFastModel` step 3 |

Unify into one **cheap-tier resolution** — config `fast_model` → auto-router
easy tier → catalog default — consulted by both the page path and the
router, so an operator sets the small model once and both consumers agree.

The final step stops being a frozen literal: consult the **model-discovery
cache** (`PasClaw.Providers.Models`, already fetching `/v1beta/models` and
caching per provider) and pick the newest id matching the family pattern
(flash-lite, then flash, for Gemini), falling back to the `FastModelFor`
literal only when there is no cache. The discovery data exists today and is
read by nothing at runtime; this is the standing complaint that the model
list is live but the fallbacks are compiled in.

## Phase 4 — close the loop

*Offline, explicit, their spirit at our scale.*

- **`pasclaw route report`** — summarize the journal: route rate, fooled
  rate, tokens and latency diverted, per-reason counts, per-session
  escalations.
- **`pasclaw route tune`** — fit the *existing* `TRouterWeights` logistic
  offline from journal outcomes and **print suggested weights** plus their
  expected effect on the journal replayed; the operator applies them to
  config by hand. Frozen-policy discipline, kept deliberately: no online
  learning, no network calls, an explicit apply step, and the artifact is a
  weight vector in config — inspectable, revertable, diffable.

Stated limit, up front: without an LLM judge our only labels are hard
outcomes — a routed turn that failed or fell back. A cheap model that
*answered badly but successfully* is invisible to us. That is precisely
where experiential spends its judging budget, and where we choose not to.
If that ever changes, the journal is the corpus it would start from.

## Sizing

Phases 1 and 2 are a PR each and independent of everything else. Phase 3 is
a medium PR with a real bug fix inside (the stale literals). Phase 4 is
CLI-side and waits for a few weeks of journal.
