#!/usr/bin/env python3
"""Build bench/decision-models/rerank-docs.jsonl from the docs and the questions.

Each question in rerank-queries.json names the passage(s) that answer it.
Its candidate pool is the top POOL passages for the question by BM25 over
every passage (passages.py) -- the cheap first stage a reranker runs
behind -- in BM25 order. A correct passage BM25 did not rank that high
takes the last slot, and the line records where BM25 put it, so the set
says how much reordering a reranker has to do.

The output is self-contained (the passage text is in it), so the set and
its hash stay the same when the docs change; rebuild on purpose.

usage: build_rerank.py [repo-root]   (writes next to this script)
"""
import json
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from passages import passages  # noqa: E402

POOL = 10
CAP = 800
STOP = set("a an and are as at be by can do does for from how i if in is it its of on or "
           "the this to what when where which why with my me you your that so not".split())


def toks(s):
    return [t for t in re.findall(r"[a-z0-9_]+", s.lower()) if t not in STOP]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    here = os.path.dirname(os.path.abspath(__file__))
    ps = passages(root)
    byid = {p["id"]: p for p in ps}
    qs = json.load(open(os.path.join(here, "rerank-queries.json"), encoding="utf-8"))
    for q in qs:
        for r in q["relevant"]:
            if r not in byid:
                sys.exit("unknown passage id in rerank-queries.json: " + r)

    docs = [toks(p["heading"] + " " + p["text"]) for p in ps]
    N = len(docs)
    avg = sum(len(d) for d in docs) / N
    df = {}
    for d in docs:
        for t in set(d):
            df[t] = df.get(t, 0) + 1
    tf = []
    for d in docs:
        c = {}
        for t in d:
            c[t] = c.get(t, 0) + 1
        tf.append(c)

    def bm25(qt, i, k1=1.2, b=0.75):
        s, L = 0.0, len(docs[i])
        for t in qt:
            f = tf[i].get(t, 0)
            if f:
                idf = math.log(1 + (N - df[t] + 0.5) / (df[t] + 0.5))
                s += idf * f * (k1 + 1) / (f + k1 * (1 - b + b * L / avg))
        return s

    out, ranks = [], []
    for n, q in enumerate(qs):
        qt = toks(q["q"])
        order = sorted(range(N), key=lambda i: (-bm25(qt, i), ps[i]["id"]))
        rank_of = {ps[i]["id"]: r for r, i in enumerate(order)}
        pool = [ps[i]["id"] for i in order[:POOL]]
        for r in q["relevant"]:
            if r not in pool:
                pool[-1] = r  # the first stage missed it: it takes the last slot
        bm25_rank = min(rank_of[r] for r in q["relevant"]) + 1
        ranks.append(bm25_rank)
        out.append({
            "id": "q%02d" % n,
            "query": q["q"],
            "candidates": [{"id": pid, "text": byid[pid]["text"][:CAP]} for pid in pool],
            "relevant": [k for k, pid in enumerate(pool) if pid in q["relevant"]],
            "bm25_rank": bm25_rank,
        })

    path = os.path.join(here, "rerank-docs.jsonl")
    with open(path, "w", encoding="utf-8") as f:
        for line in out:
            f.write(json.dumps(line, ensure_ascii=False, sort_keys=True) + "\n")
    top1 = sum(1 for r in ranks if r == 1)
    inpool = sum(1 for r in ranks if r <= POOL)
    print("%d questions over %d passages -> %s" % (len(out), N, os.path.relpath(path, root)))
    print("BM25 puts a correct passage first for %d, in the top %d for %d, misses %d"
          % (top1, POOL, inpool, len(out) - inpool))


if __name__ == "__main__":
    main()
