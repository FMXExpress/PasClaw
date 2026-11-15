# Decision models

A decision model reads input the way a language model does and answers the
way a classifier does: you ask it typed, closed questions and it returns a
probability for every possible answer — no generated text, no output tokens,
nothing to parse out of prose. Gemini Decision 1, TypeSafe's Jev and the
self-hosted OpenJev are all this kind of model.

PasClaw has places where it asks a chat model a closed question and then
parses its prose: which search results answer the query, whether a goal is
met, whether a turn is easy enough for the cheap model. Those are its
**decision points**. A decision model can take one over — but only where a
benchmark shows it does better there than what the point does today.

That last part is the rule this feature is built around. With
`decision_models.require_bench` on (the default), selecting a backend for a
point does nothing until `pasclaw decision-model bench <point>` has
recorded a run in which that backend, at that model, beat the exact
implementation the point would otherwise use.

Today one point consults the gate: **rerank** (`/v1/rerank`).

## Setting one up

```json
"decision_models": {
  "backends": [
    { "name": "gemini-decision", "kind": "google", "provider": "gemini" },
    { "name": "openjev", "kind": "systemone", "api_base": "http://gpu-box:8080",
      "api_key": "…", "model": "openjev-latest" }
  ],
  "points": { "rerank": "gemini-decision" }
}
```

| Field | Meaning |
|---|---|
| `backends[].name` | What `points` and the CLI call it. |
| `backends[].kind` | `google` (Gemini Decision 1: `POST <base>/v1beta/decisions`, key in `x-goog-api-key`) or `systemone` (Jev and OpenJev: `POST <base>/v1/systemone`, Bearer token). |
| `backends[].provider` | A `providers[]` entry to take the key from — and, for `google`, the base URL: point it at your Gemini provider and there is no second key to manage. |
| `backends[].api_base`, `api_key` | Override the provider's. Defaults: `https://generativelanguage.googleapis.com` / `https://api.typesafe.ai`. The key is masked by `GET /v1/config` and kept on a save from the settings form, like a provider's. |
| `backends[].model` | Default `gemini-decision-1` (google) or `jev-latest` (systemone). |
| `points` | Decision point → backend name. |
| `require_bench` | Default `true`. `false` uses a selected backend without a bench run — for experiments; the point is then on your word, not a measurement. |

Then:

```sh
pasclaw decision-model test gemini-decision     # one tiny live call: reachable? answers?
pasclaw decision-model bench rerank             # benchmark, record the verdict
pasclaw decision-model status                   # each point: on or off, and why
```

## The gate

`pasclaw decision-model bench rerank` runs a labeled set through the
reranker `/v1/rerank` uses today — the **baseline** — and through the
decision model, prints both, and records the run in
`$PASCLAW_HOME/decision-models/bench/rerank.json`.

- The baseline is named exactly: `llm:gemini/gemini-3.5-flash-lite`,
  `local:ms-marco-minilm`. A win over a small chat model says nothing
  about a large one and nothing at all about the local cross-encoder, so a
  record only counts against the reranker it was measured against. Change
  the default provider's model and the point goes back to it until you
  bench again.
- The verdict is on MRR (mean reciprocal rank of the first right answer),
  and takes two things: the decision model beats the baseline by
  `--margin` (default 0.02), **and** the gain is not noise — the 5th
  percentile of a paired bootstrap of the per-question gain is above zero.
  The second condition exists because the first can be carried by one or
  two questions: the first live run below cleared the margin while each
  reranker was better on 5 and 4 questions of 60. The bench prints the
  paired wins, losses and ties and the lower bound. Hit@1, Hit@3, latency
  and tokens are printed beside it, not voted on.
- A failed call counts with the first-stage order, as it would in
  production. An unreliable backend pays for it in the metric.
- A newer run of the same backend, model and baseline replaces the older
  one — including a losing run, which shuts the gate.
- Exit codes: 0 passed, 3 ran and did not pass, 1 could not run. `--limit`
  runs and `--no-save` runs are not recorded.

The gate is read on every request, so a bench takes effect without a
restart. When the gate is open, `/v1/rerank` answers with
`"model": "decision:<backend>:<model>"`; if the vendor fails, the request
falls back to the baseline reranker and still succeeds.

`status` prints the reason either way:

```
Decision points:
  rerank    off  rerank stays on llm:gemini/gemini-3.5-flash-lite: gemini-decision (gemini-decision-1) did not beat llm:gemini/gemini-3.5-flash-lite (mrr 0.992 vs 0.985, needs +0.020, …)
```

That is the real line after the run in [Results](#results): the decision
model did not earn the point, so the point did not change.

## How rerank asks

One request per rerank. The query is the shared input; each candidate is
one `score` question — *how well does this passage answer the question?* —
on four levels (does not help / on the topic but does not answer / partly
answers / directly answers), with the passage in the question. Candidates
are ordered by the probability-weighted level. Two other shapes were
measured on the same set and did no better: all passages in the input with
one question per number (same MRR, twice the p95 latency), and a yes/no
"does this passage answer the question?" (lower MRR).

## Confidence is not portable

Every vendor returns a `confidence`, and they do not mean the same thing:
Google's is the probability the top answer is right; OpenJev's is one minus
the normalised entropy of the distribution; third-party Jev guides describe
it as how concentrated the distribution is. PasClaw ignores the field.
Each answer's `Top` is the probability of the most likely answer, computed
from the probabilities, so it means the same thing on every backend — and
what value of it is good enough is a question for the benchmark of a given
point, not a constant.

## Results

Measured live on 2026-11-15 with the free-tier Gemini API key this was
built with. See [bench/decision-models/README.md](../bench/decision-models/README.md)
for how the set was made and its caveats.

**Against the chat reranker `/v1/rerank` uses here** (`rerank_backend: llm`,
the default provider on `gemini-3.5-flash-lite`), through
`pasclaw decision-model bench rerank --pace 6000`:

| | Hit@1 | Hit@3 | MRR | p50 / p95 ms | input / output tokens | failed calls |
|---|---|---|---|---|---|---|
| first stage (BM25 order) | 50.0% | 76.7% | 0.651 | – | – | – |
| `llm:gemini/gemini-3.5-flash-lite` | 98.3% | 98.3% | 0.985 | 875 / 1225 | 93,351 / 1,127 | 0 |
| `gemini-decision-1` | 98.3% | 100.0% | 0.992 | 618 / 725 | 159,917 / 0 | 0 |

Paired: each ranked the answer higher on one question and they tied on
58. Gain 0.007 MRR, 95% lower bound −0.017. **Not passed** — rerank stays
on the chat model. Both are at the ceiling of this set: it separates them
from BM25 by a long way and cannot separate them from each other. The
decision model answered about 30% faster with nothing generated, and read
1.7× the input tokens (each question repeats the four level descriptions).

*The same bench against the local cross-encoder (`bge-reranker-base`) is in progress; its row goes here when it finishes.*

**How this run got here.** The first live run is the reason the verdict
has two halves and the set has its current labels:

- Two of its decision calls failed with HTTP 400 "Invalid JSON payload":
  passages were cut at 800 *bytes*, through a multi-byte character, and
  the vendor refuses a body that is not valid UTF-8. Fixed for both
  rerankers; the runs above have no failed calls.
- It "passed" by 0.021 MRR against the 0.02 margin while each side was
  better on 5 and 4 questions — the case the bootstrap bound now stops.
- Nine of its disagreements with the labels were passages that answer the
  question outright; they were added (see the
  [set's README](../bench/decision-models/README.md)). With them, both
  rerankers rose to the scores above.

**The question design** was chosen with a throwaway prototype on the same
set (BM25 first stage, then `gemini-decision-1`, original labels):

| design | Hit@1 | MRR | p50 / p95 ms |
|---|---|---|---|
| passage in each score question (used) | 91.7% | 0.953 | 507 / 1176 |
| all passages in the input, one question per number | 91.7% | 0.956 | 525 / 2284 |
| yes/no "does this passage answer the question?" | 85.0% | 0.919 | 499 / 744 |

**What this does and does not say.** On PasClaw's documentation, with
questions one person wrote, Gemini Decision 1 reranks about as well as a
small Gemini chat model — not measurably better — faster and with no
output, at more input. It says nothing about other data: that is what
`--dataset` is for, and the gate reads whatever set the run used.

## Privacy and limits

- Whatever a point sends goes to the backend's vendor. For rerank that is
  the query and the candidate passages — the same text the `llm` reranker
  already sends to the chat provider, now to the decision vendor instead.
  The local reranker sends nothing anywhere.
- Gemini Decision 1's free tier allows 200 requests and 50,000 input tokens
  a minute. A rerank of ten 800-character passages is about 2,700 tokens,
  so a busy gateway on a free key will be throttled; a throttled call falls
  back to the baseline.
- `systemone` is built from OpenJev's README and tested against a fake
  server. It has not been run against TypeSafe's hosted Jev or a live
  OpenJev; `decision-model test` is the first thing to run against one.
- Not here yet: other decision points (the goals judge, the auto-router's
  borderline turns, deferred tool selection), OpenAI-style `/v1/decisions`,
  and Vertex AI.
