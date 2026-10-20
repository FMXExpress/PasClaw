#!/usr/bin/env python3
"""
LOCOMO memory-retrieval bench for PasClaw.

What this measures
------------------
Just the memory retrieval layer -- given a question, does
PasClaw's memory_search surface a snippet that contains the
gold answer? This is the upper bound on agent performance:
if the right facts don't make it into the model's context,
no amount of reasoning recovers them.

What this does NOT measure
--------------------------
Agent-loop reasoning, multi-hop synthesis across retrieved
snippets, hallucination on missing facts. Those are downstream
of retrieval and require a full LLM in the loop.

Pipeline
--------
1. Per persona, set up a fresh $PASCLAW_HOME tempdir.
2. Write each conversation session as one markdown file under
   workspace/memory/ (date-stamped naming so PasClaw's daily-
   note injection conventions apply).
3. Invoke bench/locomo/memory_recall (Pascal helper) per
   question. It calls Idx.SyncDir on first invocation, which
   builds the FTS5 + vec indexes; subsequent calls reuse them.
4. Dump top-K retrievals to results/<persona>.json.
5. Score: for each question, did the gold answer (or any
   alias) appear in the snippet text of the top-K hits?
6. Tally R@1 / R@5 / R@10 per category and overall.

Real LOCOMO
-----------
The bundled fixture is a hand-rolled LOCOMO-shaped persona for
smoke-testing without the dataset download. To run against the
real LOCOMO benchmark:

    git clone https://github.com/snap-stanford/locomo
    python bench/locomo/run.py --persona locomo/data/locomo10.json

The shape adapter is straightforward -- LOCOMO's session_summary
+ conversation field map onto the loader's "messages" array. See
load_persona() for the exact contract.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
RECALL_BINARY = HERE / "memory_recall"


def load_persona(path):
    """Load a LOCOMO-shaped persona JSON.

    Expected shape (matches the bundled fixture):
      { "persona_id": str,
        "sessions": [ { "session_id", "date", "messages": [
                         {"role", "content"} ] } ],
        "questions": [ { "id", "category", "question",
                         "answer", "answer_aliases"? } ] }

    For real-LOCOMO files, write a tiny shim that produces this
    shape -- LOCOMO's raw format has the same content, just
    different field names.
    """
    with open(path) as f:
        return json.load(f)


def write_sessions_to_memory(home, persona):
    """Convert persona sessions to PasClaw memory markdown files.

    Strategy: each session lands as a single .md under
    workspace/memory/ with the session date as the filename
    (so PasClaw's "yesterday's daily note" injection has a
    chance to surface it). The session content is rendered as
    a transcript with explicit speaker tags so FTS5 has clean
    token boundaries and vector embedding sees readable text.
    """
    mem_dir = home / "workspace" / "memory"
    mem_dir.mkdir(parents=True, exist_ok=True)
    pid = persona["persona_id"]
    for sess in persona["sessions"]:
        date = sess["date"]
        sid = sess["session_id"]
        path = mem_dir / f"{pid}_{date}_{sid}.md"
        with open(path, "w") as f:
            f.write(f"# {pid} session {sid} ({date})\n\n")
            for msg in sess["messages"]:
                speaker = "user" if msg["role"] == "user" else "assistant"
                f.write(f"**{speaker}**: {msg['content']}\n\n")
    return mem_dir


def write_config(home):
    """Seed a minimal config.json. memory_recall only reads
    Cfg.VectorSearchEnabled; everything else PasClaw defaults
    are fine for a bench run."""
    cfg_path = home / "config.json"
    # Vector backend is opt-in -- if the host hasn't run
    # `pasclaw memory provision`, the runtime artifacts aren't
    # on disk and Open will fail back to FTS-only. Leave the
    # flag on; the helper handles graceful fallback.
    cfg = {
        "default_provider": "bench",
        "default_model": "n/a",
        "providers": [],
        "vector_search_enabled": True,
        "render_markdown": False,
    }
    with open(cfg_path, "w") as f:
        json.dump(cfg, f, indent=2)
    return cfg_path


def recall(home, query, k):
    """Invoke the Pascal helper. Returns the parsed JSON.

    Each call shells out so we don't have to hand-import a
    Pascal-callable Python binding; the per-query overhead is
    fork/exec + one SQLite open which is fast enough at bench
    scale. SyncDir is run on every call but it's mtime-keyed
    so only the first call does real work."""
    cmd = [
        str(RECALL_BINARY),
        "--home", str(home),
        "--query", query,
        "--k", str(k),
    ]
    env = os.environ.copy()
    env["PASCLAW_HOME"] = str(home)
    res = subprocess.run(
        cmd, env=env, capture_output=True, text=True, check=False,
        timeout=60,
    )
    if res.returncode != 0:
        raise RuntimeError(
            f"memory_recall failed (exit={res.returncode}):\n"
            f"stderr: {res.stderr}\nstdout: {res.stdout}"
        )
    return json.loads(res.stdout)


def _read_doc(path):
    """Best-effort full-doc read for the document-level score. The
    memory_recall snippet column is FTS5's bounded window (~30 tokens
    of context); a real agent would see the snippet, decide a hit
    looks relevant, and call fs_read on the path to expand. We
    measure both layers so the bench distinguishes 'retrieval found
    the right doc but snippet missed the answer line' (fixable with
    a follow-up read) from 'retrieval missed entirely' (fatal)."""
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().lower()
    except (FileNotFoundError, PermissionError, UnicodeDecodeError):
        return ""


def score_question(q, hits):
    """For each k in {1, 5, 10}, two layers:

      snippet_r@k -- did any alias appear in the FTS5-bounded
                     snippet text of the top-k hits? This is what
                     the model sees in one memory_search call,
                     before any follow-up fs_read.
      doc_r@k     -- did any alias appear in the FULL document
                     body of the top-k hits' source files? An
                     agent following up with fs_read would
                     surface this content.

    Real LOCOMO scoring uses chunked retrieval where the chunk IS
    the model's window; PasClaw's tool surface has the cite-then-
    read split, so both numbers tell different parts of the story."""
    aliases = q.get("answer_aliases") or [q["answer"]]
    aliases = [a.lower() for a in aliases]
    out = {}
    docs_seen = {}  # cache: path -> lowered body
    for k in (1, 5, 10):
        snippet_hit = False
        doc_hit = False
        for entry in hits[:k]:
            snippet = entry["snippet"].lower()
            if any(alias in snippet for alias in aliases):
                snippet_hit = True
                doc_hit = True
                break
            # snippet missed; check the full doc as the
            # follow-up-fs_read upper bound.
            path = entry["path"]
            if path not in docs_seen:
                docs_seen[path] = _read_doc(path)
            if any(alias in docs_seen[path] for alias in aliases):
                doc_hit = True
        out[f"snippet_r@{k}"] = 1 if snippet_hit else 0
        out[f"doc_r@{k}"]     = 1 if doc_hit else 0
    return out


def run(persona_path, out_dir, k=10, keep_home=False):
    persona = load_persona(persona_path)
    pid = persona["persona_id"]

    home = Path(tempfile.mkdtemp(prefix=f"locomo_{pid}_"))
    try:
        write_config(home)
        write_sessions_to_memory(home, persona)
        print(f"[bench] persona={pid} home={home}", file=sys.stderr)
        print(f"[bench] {len(persona['sessions'])} sessions, "
              f"{len(persona['questions'])} questions", file=sys.stderr)

        results = []
        for q in persona["questions"]:
            try:
                r = recall(home, q["question"], k)
            except Exception as e:
                print(f"[bench] FAIL on {q['id']}: {e}", file=sys.stderr)
                r = {"hits": []}
            scored = score_question(q, r["hits"])
            results.append({
                "question": q,
                "hits": r["hits"],
                "score": scored,
            })
            print(f"[bench] {q['id']} ({q['category']}): "
                  f"snippet={scored['snippet_r@1']}/{scored['snippet_r@5']}/{scored['snippet_r@10']} "
                  f"doc={scored['doc_r@1']}/{scored['doc_r@5']}/{scored['doc_r@10']}",
                  file=sys.stderr)

        out_dir.mkdir(parents=True, exist_ok=True)
        out_path = out_dir / f"{pid}.json"
        with open(out_path, "w") as f:
            json.dump({
                "persona_id": pid,
                "results": results,
                "summary": summarize(results),
            }, f, indent=2)
        print(f"[bench] wrote {out_path}", file=sys.stderr)
        print(format_summary(summarize(results)))
        return out_path
    finally:
        if not keep_home:
            shutil.rmtree(home, ignore_errors=True)


def _mean(scores, key):
    return sum(s[key] for s in scores) / len(scores)


def summarize(results):
    by_cat = {}
    for r in results:
        cat = r["question"]["category"]
        by_cat.setdefault(cat, []).append(r["score"])
    keys = ["snippet_r@1", "snippet_r@5", "snippet_r@10",
            "doc_r@1",     "doc_r@5",     "doc_r@10"]
    summary = {"by_category": {}, "overall": {}}
    for cat, scores in by_cat.items():
        m = {"n": len(scores)}
        for k in keys:
            m[k] = _mean(scores, k)
        summary["by_category"][cat] = m
    all_scores = [r["score"] for r in results]
    o = {"n": len(all_scores)}
    for k in keys:
        o[k] = _mean(all_scores, k)
    summary["overall"] = o
    return summary


def format_summary(summary):
    lines = ["",
             "                       ----- snippet-level -----   ----- doc-level -------",
             "category         n    R@1    R@5    R@10           R@1    R@5    R@10",
             "--------------- ---   -----  -----  -----          -----  -----  -----"]
    def row(label, m):
        return (f"{label:<15} {m['n']:>3}   "
                f"{m['snippet_r@1']:>.3f}  {m['snippet_r@5']:>.3f}  {m['snippet_r@10']:>.3f}"
                f"          "
                f"{m['doc_r@1']:>.3f}  {m['doc_r@5']:>.3f}  {m['doc_r@10']:>.3f}")
    for cat, m in sorted(summary["by_category"].items()):
        lines.append(row(cat, m))
    lines.append("--------------- ---   -----  -----  -----          -----  -----  -----")
    lines.append(row("overall", summary["overall"]))
    return "\n".join(lines)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--persona", default=str(HERE / "fixture" / "alice_synthetic.json"),
                   help="path to a LOCOMO-shaped persona JSON")
    p.add_argument("--out", default=str(HERE / "results"),
                   help="output directory for per-persona results")
    p.add_argument("--k", type=int, default=10,
                   help="top-K snippets to retrieve (default 10)")
    p.add_argument("--keep-home", action="store_true",
                   help="don't clean up the temp PASCLAW_HOME (debug)")
    args = p.parse_args()

    if not RECALL_BINARY.exists():
        sys.exit(f"missing helper: {RECALL_BINARY}\n"
                 "Build it with:\n"
                 "  fpc <PasClaw FPCFLAGS> bench/locomo/memory_recall.pas")

    run(Path(args.persona), Path(args.out), k=args.k,
        keep_home=args.keep_home)


if __name__ == "__main__":
    main()
