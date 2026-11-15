# Decision model benchmarks

What `pasclaw decision-model bench` runs, and how the sets here were made.
A decision model is only used at a decision point after a recorded run
shows it beats what that point does without it; these are the runs. See
[docs/decision-models.md](../../docs/decision-models.md).

## `rerank-docs.jsonl` — 60 questions over PasClaw's own docs

The reranking set: for each question, ten candidate passages in a first
stage's order, and which of them answer it.

```sh
pasclaw decision-model bench rerank                      # this set, default baseline
pasclaw decision-model bench rerank --dataset my.jsonl   # your own
```

**Corpus.** `passages.py` splits the user-facing pages under `docs/` into
passages of 250–1200 characters, one heading's paragraphs at a time — 697
passages from 32 pages. Plan documents, the changelog and the README are
left out: they restate other pages, so a question would have several right
answers.

**Questions.** `rerank-queries.json` holds 60 questions, each naming the
passage (or, once, the two passages) that answers it. The passages were
drawn at random with a fixed seed, spread across the pages, and skipped
when they were mostly code, a bare list of links, or answered elsewhere
too. Each question was then written for its passage the way a user would
ask it — in the asker's words, not the passage's — so word overlap does
not give the answer away.

**Pools.** `build_rerank.py` ranks all 697 passages for each question with
BM25 and keeps the top ten, in BM25's order: the cheap first stage a
reranker runs behind. When BM25 did not rank the answer that high, it
takes the last slot. Passages are cut to 800 characters. BM25 puts the
answer first for 29 of the 60, in its top ten for 49, and misses 11.

The set is self-contained — the passage text is in it — so its SHA-256
(recorded with every bench run) does not move when the docs change.
Rebuild it on purpose:

```sh
python3 bench/decision-models/build_rerank.py .
```

**Format** (one JSON object per line; bring your own in this shape):

```json
{"id": "q00", "query": "...",
 "candidates": [{"id": "docs/x.md#section/0", "text": "..."}, ...],
 "relevant": [3], "bm25_rank": 4}
```

`candidates` are in first-stage order; `relevant` are indices into them.
`bm25_rank` is informational.

**What a run reports.** Hit@1, Hit@3 and MRR (mean reciprocal rank of the
first relevant candidate) for the first stage, the baseline reranker and
the decision model, with p50/p95 latency and tokens. A call that fails
counts with the first-stage order, as it would in production. The verdict
is on MRR: the decision model passes when it beats the baseline by the
margin (default 0.02).

**Caveats.**

- The questions were written by the same author who chose the passages,
  against PasClaw's own documentation. That is one domain and one writer.
  A team's own data is the better test: export a set in the format above.
- Labels mark the passage the question was written for. Another passage
  in the pool can answer it too; where a system's top answer was not the
  labelled one, that passage was read, and the label extended only when
  it answers the question (see Results).
- Sixty questions separate large differences, not small ones: one
  question is worth up to 0.017 MRR.

## Results

See [docs/decision-models.md](../../docs/decision-models.md#results).
