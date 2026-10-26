#!/usr/bin/env python3
"""Relay worker for the VERIFY loop.

The model's first draft of rag.py has a bug the model's own test does not
catch (chunk() ignores the overlap), and the model reports "done" once
its own test passes. That is the false-success case held-out scenarios
exist for. If a later user turn is a [verification] feedback message, the
model fixes chunk() and reports again; it re-runs its own test only when
the feedback does not say the scenarios will be re-run automatically.

usage: worker_verify.py <gateway-url> <relay-token> <outdir>
"""
import json, os, sys, time, urllib.request

BASE, TOKEN, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(OUT, exist_ok=True)

RAG_HEAD = r'''"""Minimal local RAG pipeline: ingest text files, chunk, TF-IDF index, query."""
import json, math, os, re, sys
from collections import Counter

INDEX = "index.json"
TOKEN = re.compile(r"[a-z0-9]+")

def tokenize(text):
    return TOKEN.findall(text.lower())

'''
CHUNK_BUGGY = r'''def chunk(text, size=80, overlap=20):
    words = text.split()
    out, i = [], 0
    while i < len(words):
        out.append(" ".join(words[i:i + size]))
        i += size          # BUG: the overlap is never applied
    return out

'''
CHUNK_FIXED = r'''def chunk(text, size=80, overlap=20):
    words = text.split()
    out, i = [], 0
    while i < len(words):
        out.append(" ".join(words[i:i + size]))
        if i + size >= len(words):
            break
        i += size - overlap
    return out

'''
RAG_TAIL = r'''def ingest(docs_dir, index_path=INDEX):
    chunks = []
    for root, _, files in os.walk(docs_dir):
        for f in sorted(files):
            if f.endswith((".txt", ".md")):
                path = os.path.join(root, f)
                with open(path, encoding="utf-8") as fh:
                    for n, c in enumerate(chunk(fh.read())):
                        chunks.append({"source": path, "n": n, "text": c})
    df = Counter()
    for c in chunks:
        df.update(set(tokenize(c["text"])))
    N = max(len(chunks), 1)
    idf = {t: math.log((N + 1) / (d + 1)) + 1 for t, d in df.items()}
    for c in chunks:
        tf = Counter(tokenize(c["text"]))
        c["vec"] = {t: (1 + math.log(n)) * idf[t] for t, n in tf.items()}
    with open(index_path, "w", encoding="utf-8") as fh:
        json.dump({"idf": idf, "chunks": chunks}, fh)
    return len(chunks)

def query(q, k=3, index_path=INDEX):
    with open(index_path, encoding="utf-8") as fh:
        idx = json.load(fh)
    idf = idx["idf"]
    qtf = Counter(tokenize(q))
    qv = {t: (1 + math.log(n)) * idf.get(t, 1.0) for t, n in qtf.items()}
    qn = math.sqrt(sum(v * v for v in qv.values())) or 1.0
    scored = []
    for c in idx["chunks"]:
        cv = c["vec"]
        dot = sum(qv[t] * cv.get(t, 0.0) for t in qv)
        cn = math.sqrt(sum(v * v for v in cv.values())) or 1.0
        scored.append((dot / (qn * cn), c))
    scored.sort(key=lambda s: -s[0])
    return [(s, c["source"], c["text"]) for s, c in scored[:k] if s > 0]

def answer(q, k=3, index_path=INDEX):
    hits = query(q, k, index_path)
    if not hits:
        return "No relevant context found."
    ctx = "\n---\n".join(f"[{src}] {txt}" for _, src, txt in hits)
    return f"Question: {q}\n\nRetrieved context:\n{ctx}\n\nAnswer: see the top passage from {hits[0][1]}."

def main(argv):
    if len(argv) >= 2 and argv[0] == "ingest":
        print(f"indexed {ingest(argv[1])} chunks into {INDEX}")
    elif len(argv) >= 2 and argv[0] == "query":
        print(answer(" ".join(argv[1:])))
    else:
        print("usage: rag.py ingest <docs_dir> | query <question>")
        return 2
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
'''
# The model's own test: covers ingest/query, NOT the overlap arithmetic.
TEST_PY = r'''import os, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import rag

def test_roundtrip():
    with tempfile.TemporaryDirectory() as d:
        docs = os.path.join(d, "docs"); os.makedirs(docs)
        with open(os.path.join(docs, "a.md"), "w") as f:
            f.write("Pascal is a procedural language designed by Niklaus Wirth. " * 5)
        with open(os.path.join(docs, "b.txt"), "w") as f:
            f.write("Bananas are yellow fruit rich in potassium. " * 5)
        idx = os.path.join(d, "index.json")
        assert rag.ingest(docs, idx) >= 2
        hits = rag.query("who designed pascal", k=1, index_path=idx)
        assert hits and hits[0][1].endswith("a.md")

if __name__ == "__main__":
    test_roundtrip(); print("1 passed")
'''
SAMPLE_MD = "# Sample\n\nPasClaw is an AI agent framework written in Object Pascal.\n"

CHECK = "python3 tests/test_rag.py && python3 rag.py ingest docs && python3 rag.py query 'what is pasclaw'"

LAST_RESP = [0.0]

def http(method, path, body=None, headers=None):
    req = urllib.request.Request(BASE + path, data=body, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    return urllib.request.urlopen(req, timeout=None)

def measure(env):
    msgs = env.get("messages", [])
    return {"total": len(json.dumps(env)), "tools": len(json.dumps(env.get("tools", []))),
            "history": sum(len(json.dumps(m)) for m in msgs if m.get("role") != "system")}

def call(i, name, args):
    return {"id": f"call_{i}", "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}

def main():
    log = []
    turn = 0
    req = urllib.request.Request(BASE + "/v1/relay/poll")
    req.add_header("Authorization", "Bearer " + TOKEN)
    for k, v in {"Accept": "text/event-stream", "X-Relay-Worker-Id": "claude-router",
                 "X-Relay-Capabilities": ""}.items():
        req.add_header(k, v)
    # A read timeout is how the worker learns the gateway is done with it:
    # after a final answer, PasClaw either sends a verification feedback
    # request within a couple of seconds or nothing more arrives.
    resp = urllib.request.urlopen(req, timeout=8)
    import socket
    while True:
        try:
            line = resp.readline()
        except socket.timeout:
            break
        if not line:
            break
        line = line.decode("utf-8", "replace").rstrip("\n")
        if not line.startswith("data:"):
            continue
        env = json.loads(line[5:].strip())
        t_recv = time.time()
        with open(os.path.join(OUT, f"req-{turn}.json"), "w") as f:
            json.dump(env, f, indent=1)
        m = measure(env); m["step"] = turn
        m["gap_ms"] = int((t_recv - LAST_RESP[0]) * 1000) if LAST_RESP[0] else 0
        msgs = env["messages"]
        users = [x for x in msgs if x.get("role") == "user"]
        last_user = (users[-1].get("content") or "") if users else ""
        ran = [tc["function"]["name"] for x in msgs for tc in (x.get("tool_calls") or [])]
        tool_msgs = [x for x in msgs if x.get("role") == "tool"]
        feedback = last_user.startswith("[verification]")
        # "Did I already apply the fix?" must be judged from tool RESULTS after
        # the feedback turn, not from my own earlier call arguments: PasClaw
        # trims large write arguments in the history it replays, so the
        # content is not there to grep.
        fixed_already = False
        if feedback:
            seen_fb = False
            for x in msgs:
                if x.get("role") == "user" and (x.get("content") or "").startswith("[verification]"):
                    seen_fb = True
                elif seen_fb and x.get("role") == "tool" and "rag.py" in (x.get("content") or ""):
                    fixed_already = True
        m["kind"] = "feedback" if feedback else "task"
        log.append(m)

        if feedback and not fixed_already:
            calls = [call(f"{turn}_0", "fs_write", {"path": "rag.py", "content": RAG_HEAD + CHUNK_FIXED + RAG_TAIL})]
            if "re-run automatically" not in last_user:
                calls.append(call(f"{turn}_1", "shell_exec", {"command": CHECK}))
            body = {"content": "", "finish_reason": "tool_calls", "tool_calls": calls}
            final = False
        elif not ran:
            calls = [call(f"{turn}_0", "fs_write", {"path": "rag.py", "content": RAG_HEAD + CHUNK_BUGGY + RAG_TAIL}),
                     call(f"{turn}_1", "fs_write", {"path": "tests/test_rag.py", "content": TEST_PY}),
                     call(f"{turn}_2", "fs_write", {"path": "docs/sample.md", "content": SAMPLE_MD}),
                     call(f"{turn}_3", "shell_exec", {"command": CHECK})]
            body = {"content": "", "finish_reason": "tool_calls", "tool_calls": calls}
            final = False
        else:
            last = tool_msgs[-1]["content"] if tool_msgs else ""
            if fixed_already:
                content = "Fixed chunk() to apply the overlap (step = size - overlap). Reported done again."
            else:
                content = ("Built a local RAG pipeline in rag.py with tests in tests/test_rag.py and a sample doc. "
                           + ("Tests pass and the ingest/query run succeeded." if "1 passed" in last else "The run reported: " + last[:200]))
            body = {"content": content, "finish_reason": "stop"}
            final = True
        http("POST", "/v1/relay/respond/" + env["id"], body=json.dumps(body).encode(),
             headers={"Content-Type": "application/json"}).read()
        LAST_RESP[0] = time.time()
        turn += 1
        # After a final answer keep polling: PasClaw may come back with a
        # verification round. The read timeout above ends the wait.
    with open(os.path.join(OUT, "log.json"), "w") as f:
        json.dump(log, f, indent=1)
    tot = sum(x["total"] for x in log)
    print(f"turns={len(log)} total_bytes={tot} kinds={[x['kind'] for x in log]}")
    for x in log:
        print(f"  turn {x['step']}: {x['kind']} total={x['total']} history={x['history']} gap_ms={x['gap_ms']}")

if __name__ == "__main__":
    main()
