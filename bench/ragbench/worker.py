#!/usr/bin/env python3
"""Relay worker that stands in for the model.

Pulls requests off a PasClaw gateway's /v1/relay/poll stream, records the
size of every request (system prompt / tools / history / tool results),
answers from a fixed playbook (the same decisions every run), and POSTs
the response. Exits after the playbook's final answer has been sent.

usage: worker.py <gateway-url> <relay-token> <outdir>
"""
import json, os, sys, time, urllib.request

BASE, TOKEN, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(OUT, exist_ok=True)

RAG_PY = r'''"""Minimal local RAG pipeline: ingest text files, chunk, TF-IDF index, query.
No network, no third-party packages."""
import json, math, os, re, sys
from collections import Counter

INDEX = "index.json"
TOKEN = re.compile(r"[a-z0-9]+")

def tokenize(text):
    return TOKEN.findall(text.lower())

def chunk(text, size=80, overlap=20):
    words = text.split()
    out, i = [], 0
    while i < len(words):
        out.append(" ".join(words[i:i + size]))
        if i + size >= len(words):
            break
        i += size - overlap
    return out

def ingest(docs_dir, index_path=INDEX):
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
    return f"Question: {q}\n\nRetrieved context:\n{ctx}\n\nAnswer: based on the context above, see the top passage from {hits[0][1]}."

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
        n = rag.ingest(docs, idx)
        assert n >= 2
        hits = rag.query("who designed pascal", k=1, index_path=idx)
        assert hits and hits[0][1].endswith("a.md")
        assert "Niklaus" in rag.answer("who designed pascal", index_path=idx)

def test_chunk_overlap():
    words = " ".join(str(i) for i in range(200))
    cs = rag.chunk(words, size=80, overlap=20)
    assert len(cs) == 3 and cs[1].split()[0] == "60"

if __name__ == "__main__":
    test_roundtrip(); test_chunk_overlap(); print("2 passed")
'''

SAMPLE_MD = "# Sample\n\nPasClaw is an AI agent framework written in Object Pascal. " \
            "It runs on Free Pascal and Delphi. The gateway serves a web UI and an OpenAI-compatible API.\n"

# The playbook: step N is the Nth model turn. Each entry is a tool call
# (name, args) or a final text (None).
PLAYBOOK = [
    ("fs_list",   {"path": "."}),
    ("fs_write",  {"path": "rag.py", "content": RAG_PY}),
    ("fs_write",  {"path": "tests/test_rag.py", "content": TEST_PY}),
    ("fs_write",  {"path": "docs/sample.md", "content": SAMPLE_MD}),
    ("shell_exec", {"command": "python3 tests/test_rag.py && python3 rag.py ingest docs && python3 rag.py query 'what is pasclaw'"}),
    (None, None),
]

def http(method, path, body=None, headers=None, stream=False):
    req = urllib.request.Request(BASE + path, data=body, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    return urllib.request.urlopen(req, timeout=None)

def measure(env):
    msgs = env.get("messages", [])
    sysb = sum(len(m.get("content") or "") for m in msgs if m.get("role") == "system")
    toolres = [m for m in msgs if m.get("role") == "tool"]
    toolres_b = sum(len(m.get("content") or "") for m in toolres)
    hist_b = sum(len(json.dumps(m)) for m in msgs if m.get("role") != "system")
    tools = env.get("tools", [])
    tools_b = len(json.dumps(tools))
    total = len(json.dumps(env))
    return {"total": total, "system": sysb, "tools": tools_b, "n_tools": len(tools),
            "history": hist_b, "tool_results": toolres_b, "n_tool_results": len(toolres)}

LAST_RESP = [0.0]

def main():
    step = 0
    log = []
    resp = http("GET", "/v1/relay/poll", headers={"Accept": "text/event-stream",
                "X-Relay-Worker-Id": "claude-router", "X-Relay-Capabilities": ""}, stream=True)
    while True:
        line = resp.readline()
        if not line:
            break
        line = line.decode("utf-8", "replace").rstrip("\n")
        if not line.startswith("data:"):
            continue
        env = json.loads(line[5:].strip())
        t_recv = time.time()
        rid = env["id"]
        with open(os.path.join(OUT, f"req-{step}.json"), "w") as f:
            json.dump(env, f, indent=1)
        m = measure(env); m["step"] = step
        m["t_recv"] = t_recv
        m["gap_ms"] = int((t_recv - LAST_RESP[0]) * 1000) if LAST_RESP[0] else 0
        log.append(m)
        # Decide from the playbook by how many tool results the history carries.
        n_results = m["n_tool_results"]
        name, args = PLAYBOOK[min(n_results, len(PLAYBOOK) - 1)]
        if name is None:
            last = [x for x in env["messages"] if x.get("role") == "tool"][-1]["content"]
            ok = "2 passed" in last and "indexed" in last
            content = ("Built a local RAG pipeline in rag.py (ingest -> chunk -> TF-IDF index -> query/answer), "
                       "with tests in tests/test_rag.py and a sample doc in docs/. "
                       + ("Tests pass and the ingest/query run succeeded." if ok else "The final run reported a problem: " + last[:300]))
            body = {"content": content, "finish_reason": "stop"}
        else:
            body = {"content": "", "finish_reason": "tool_calls",
                    "tool_calls": [{"id": f"call_{step}", "type": "function",
                                    "function": {"name": name, "arguments": json.dumps(args)}}]}
        http("POST", "/v1/relay/respond/" + rid, body=json.dumps(body).encode(),
             headers={"Content-Type": "application/json"}).read()
        LAST_RESP[0] = time.time()
        m["t_resp"] = LAST_RESP[0]
        step += 1
        if name is None:
            break
    with open(os.path.join(OUT, "log.json"), "w") as f:
        json.dump(log, f, indent=1)
    tot = sum(x["total"] for x in log)
    print(f"requests={len(log)} total_bytes={tot} approx_tokens={tot//4}")
    for x in log:
        print(f"  step {x['step']}: total={x['total']} system={x['system']} tools={x['tools']}({x['n_tools']}) history={x['history']} tool_results={x['tool_results']} gap_ms={x.get('gap_ms',0)}")

if __name__ == "__main__":
    main()
