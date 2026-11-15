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
passages from 32 pages, read from the docs at commit `c85592f` (`DOCS_REF`
in `build_rerank.py`), so the corpus does not move when the docs do. Plan documents, the changelog and the README are
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
takes a slot at the end. Passages are cut to 800 characters. BM25 puts a
correct passage first for 30 of the 60, in its top ten for 52, and misses
8.

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
margin (default 0.02) and the 5th percentile of a paired bootstrap of the
per-question gain is above zero — so a gain one or two questions carry
does not pass.

**Caveats.**

- The questions were written by the same author who chose the passages,
  against PasClaw's own documentation. That is one domain and one writer.
  A team's own data is the better test: export a set in the format above.
- Labels started as the passage each question was written for. Another
  passage can answer it too, so after the first live run every passage a
  system ranked first that was not labelled was read, and added to the
  question's labels only when it answers the question outright. Nine
  were (q12, q14, q22, q23, q24, q28, q43, q44, q50 — five first picked by
  the chat reranker, two by the decision model, two by both); a partial
  answer (q12's desktop passage) and an unrelated one (q53's) were not.
  The audit looks only where a system disagreed with the labels, so a
  passage neither system picked is never reviewed.
- Sixty questions separate large differences, not small ones: one
  question is worth up to 0.017 MRR.

## Results

See [docs/decision-models.md](../../docs/decision-models.md#results).
