#!/usr/bin/env python3
"""Decision models end to end: the CLI, the bench, the gate, /v1/rerank.

Against the real binary, with three fake servers and no network:

  - a Google Decisions API (POST /v1beta/decisions, x-goog-api-key, `input`)
    that scores a passage high when it contains the word ANSWER -- or, in
    "worse" mode, low;
  - a systemone (Jev / OpenJev) API (POST /v1/systemone, Bearer, `state`);
  - an OpenAI-compatible chat provider, the llm reranker's model, which
    always ranks the passages in the order it got them.

Checked:

  - `decision-model test` reaches both wire formats with the right path,
    auth and body, and reports the answer;
  - `decision-model status` says the rerank point is off and why;
  - /v1/rerank uses the llm reranker while the gate is shut, even with a
    backend selected;
  - `decision-model bench rerank` on a small set: the decision model beats
    the llm baseline, exit 0, the run is recorded; status says ON;
  - /v1/rerank now answers from the decision model (its order, its model
    name) -- without a gateway restart;
  - the decision vendor failing (HTTP 500) falls back to the llm reranker
    and the request still succeeds;
  - a bench where the decision model does worse: exit 3, NOT PASSED, the
    record is replaced and the gate shuts again -- /v1/rerank is back on
    the llm reranker;
  - GET /v1/config masks decision_models.backends[].api_key.

usage: decision_models_e2e.py <pasclaw-binary>
"""
import http.server
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

LOG = None
STATE = {"mode": "good", "google_calls": [], "systemone_calls": [], "chat_calls": 0}
GKEY, JKEY = "g-key-123", "j-key-456"


def fail(msg):
    print("FAIL: " + msg)
    if LOG and os.path.exists(LOG):
        with open(LOG, errors="replace") as f:
            print("---- gateway log (tail) ----\n" + "".join(f.readlines()[-20:]))
    sys.exit(1)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def answers_for(questions, passage_of):
    out = {}
    for key, q in questions.items():
        if q["type"] == "noul":
            out[key] = {"type": "noul", "noul": 0.97, "confidence": 0.97}
            continue
        if q["type"] != "score":
            out[key] = {"type": q["type"]}
            continue
        hit = "ANSWER" in passage_of(q)
        if STATE["mode"] == "worse":
            hit = not hit
        n = len(q["criteria"])
        probs = [0.0] * n
        if hit:
            probs[n - 1] = 0.9
            probs[0] = 0.1
        else:
            probs[0] = 0.8
            probs[1] = 0.2
        out[key] = {"type": "score", "score": sum(i * p for i, p in enumerate(probs)),
                    "probabilities": {str(i): p for i, p in enumerate(probs)},
                    "confidence": max(probs)}
    return out


class Fake(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if self.path == "/v1beta/decisions":
            STATE["google_calls"].append({"key": self.headers.get("x-goog-api-key"), "body": body})
            if STATE["mode"] == "down":
                return self.reply(500, {"error": {"code": 500, "message": "fake outage"}})
            if self.headers.get("x-goog-api-key") != GKEY or "input" not in body or "state" in body:
                return self.reply(400, {"error": {"code": 400, "message": "bad google request"}})
            return self.reply(200, {"answers": answers_for(body["questions"], lambda q: q["instructions"]),
                                    "usage": {"total_input_tokens": 100, "total_output_tokens": 0}})
        if self.path == "/v1/systemone":
            STATE["systemone_calls"].append({"auth": self.headers.get("Authorization"), "body": body})
            if self.headers.get("Authorization") != "Bearer " + JKEY or "state" not in body or "input" in body:
                return self.reply(400, {"error": "bad systemone request"})
            return self.reply(200, {"model": body.get("model"),
                                    "answers": answers_for(body["questions"], lambda q: q["instructions"]),
                                    "usage": {"input_tokens": 42}})
        if self.path == "/v1/chat/completions":
            # The llm reranker: always the order it was given.
            STATE["chat_calls"] += 1
            text = body["messages"][-1]["content"]
            n = len(re.findall(r"^\[\d+\]", text, re.M))
            content = json.dumps(list(range(n)))
            return self.reply(200, {"id": "c", "object": "chat.completion", "model": "m",
                                    "choices": [{"index": 0, "finish_reason": "stop",
                                                 "message": {"role": "assistant", "content": content}}],
                                    "usage": {"prompt_tokens": 50, "completion_tokens": 5}})
        self.reply(404, {"error": "no route " + self.path})

    def reply(self, code, obj):
        out = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def main():
    global LOG
    if len(sys.argv) != 2 or not os.path.exists(sys.argv[1]):
        print("  skip: needs the pasclaw binary")
        return
    binary = os.path.abspath(sys.argv[1])
    home = tempfile.mkdtemp(prefix="pasclaw-decision-models-e2e-")
    fport, gport = free_port(), free_port()
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", fport), Fake)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    fake = "http://127.0.0.1:%d" % fport
    with open(os.path.join(home, "config.json"), "w") as f:
        json.dump({"providers": [{"name": "fake", "kind": "openai", "api_base": fake,
                                  "api_key": "sk-test", "model": "m"}],
                   "default_provider": "fake", "default_model": "m",
                   "rerank_backend": "llm",
                   "gateway": {"port": gport, "bind_addr": "127.0.0.1"},
                   "decision_models": {
                       "backends": [{"name": "gd", "kind": "google", "api_base": fake, "api_key": GKEY},
                                    {"name": "oj", "kind": "systemone", "api_base": fake,
                                     "api_key": JKEY, "model": "openjev-latest"}],
                       "points": {"rerank": "gd"}}}, f)
    # Four questions; the passage that answers each one comes LAST in the
    # first-stage order, so the llm reranker (order as given) misses every
    # one and a reranker that finds it moves it to the top.
    dataset = os.path.join(home, "set.jsonl")
    with open(dataset, "w") as f:
        for n in range(4):
            cands = [{"id": "d%d" % k, "text": "passage %d about something else" % k} for k in range(3)]
            cands.append({"id": "gold", "text": "the ANSWER to question %d" % n})
            f.write(json.dumps({"id": "q%d" % n, "query": "question %d?" % n,
                                "candidates": cands, "relevant": [3]}) + "\n")
    env = dict(os.environ, PASCLAW_HOME=home, NO_COLOR="1")

    def cli(*args):
        r = subprocess.run([binary, "decision-model"] + list(args), env=env, cwd=home,
                           capture_output=True, text=True, timeout=120)
        return r.returncode, r.stdout + r.stderr

    LOG = os.path.join(home, "gateway.log")
    log = open(LOG, "w")
    proc = None
    base = "http://127.0.0.1:%d" % gport

    def rerank():
        req = urllib.request.Request(base + "/v1/rerank", method="POST",
                                     data=json.dumps({"query": "question 0?", "documents": [
                                         "passage 0 about something else", "passage 1 about something else",
                                         "the ANSWER to question 0"]}).encode())
        req.add_header("Content-Type", "application/json")
        try:
            r = urllib.request.urlopen(req, timeout=60)
            return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")

    try:
        rc, out = cli("test", "gd")
        call = STATE["google_calls"][-1] if STATE["google_calls"] else None
        if rc != 0 or "P(yes) = 0.970" not in out or not call or call["body"].get("model") != "gemini-decision-1":
            fail("decision-model test gd: rc %d, %r, call %r" % (rc, out[-400:], call))
        rc, out = cli("test", "oj")
        call = STATE["systemone_calls"][-1] if STATE["systemone_calls"] else None
        if rc != 0 or "P(yes)" not in out or not call or call["body"].get("model") != "openjev-latest":
            fail("decision-model test oj: rc %d, %r, call %r" % (rc, out[-400:], call))
        print("  ok: `decision-model test` reaches both wire formats with the right path, auth and body")

        rc, out = cli("status")
        if rc != 0 or not re.search(r"rerank\s+off\s+.*has not been benchmarked", out):
            fail("status before a bench should say off / not benchmarked: %r" % out[-600:])
        print("  ok: status: rerank is off until a bench, and says so")

        proc = subprocess.Popen([binary, "gateway", "--port", str(gport), "--addr", "127.0.0.1"],
                                env=env, cwd=home, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        for _ in range(80):
            try:
                urllib.request.urlopen(base + "/v1/health", timeout=1).read()
                break
            except Exception:
                time.sleep(0.25)
        else:
            fail("gateway never answered /v1/health")

        n_google = len(STATE["google_calls"])
        st, j = rerank()
        if st != 200 or not str(j.get("model", "")).startswith("llm:") or len(STATE["google_calls"]) != n_google:
            fail("with the gate shut /v1/rerank should use the llm reranker and not call the vendor: %d %r" % (st, j))
        print("  ok: gate shut: /v1/rerank uses the llm reranker and never calls the decision vendor")

        rc, out = cli("bench", "rerank", "--dataset", dataset)
        rec_path = os.path.join(home, "decision-models", "bench", "rerank.json")
        if rc != 0 or "PASS" not in out or not os.path.exists(rec_path):
            fail("bench where the decision model wins should pass, exit 0 and record: rc %d %r" % (rc, out[-900:]))
        rec = json.load(open(rec_path))["runs"][0]
        if not (rec["pass"] and rec["baseline_kind"] == "llm" and rec["n"] == 4
                and abs(rec["candidate_value"] - 1.0) < 1e-6 and abs(rec["baseline_value"] - 0.25) < 1e-6):
            fail("recorded run is wrong: %r" % rec)
        rc, out = cli("status")
        if not re.search(r"rerank\s+ON\s+rerank uses gd", out):
            fail("status after a passing bench should say ON: %r" % out[-600:])
        print("  ok: bench: decision MRR 1.000 vs llm 0.250 -> PASS, exit 0, recorded; status ON")

        st, j = rerank()
        if st != 200 or j.get("model") != "decision:gd:gemini-decision-1" or j["results"][0]["index"] != 2:
            fail("with the gate open /v1/rerank should answer from the decision model: %d %r" % (st, j))
        print("  ok: gate open: /v1/rerank answers from the decision model, no restart needed")

        STATE["mode"] = "down"
        st, j = rerank()
        if st != 200 or not str(j.get("model", "")).startswith("llm:"):
            fail("a vendor outage should fall back to the llm reranker: %d %r" % (st, j))
        print("  ok: the decision vendor failing falls back to the llm reranker; the request succeeds")

        STATE["mode"] = "worse"
        rc, out = cli("bench", "rerank", "--dataset", dataset)
        if rc != 3 or "NOT PASSED" not in out:
            fail("bench where the decision model loses should exit 3, NOT PASSED: rc %d %r" % (rc, out[-900:]))
        runs = json.load(open(rec_path))["runs"]
        if len(runs) != 1 or runs[0]["pass"]:
            fail("the losing run should replace the passing one: %r" % runs)
        STATE["mode"] = "good"
        st, j = rerank()
        if st != 200 or not str(j.get("model", "")).startswith("llm:"):
            fail("after a losing bench the gate should be shut again: %d %r" % (st, j))
        print("  ok: a losing bench exits 3, replaces the record, and shuts the gate again")

        cfg = json.loads(urllib.request.urlopen(base + "/v1/config", timeout=10).read())
        txt = json.dumps(cfg)
        if GKEY in txt or JKEY in txt or "decision_models" not in txt:
            fail("GET /v1/config should mask the decision model keys: %r" % txt[:400])
        print("  ok: GET /v1/config masks decision_models api keys")
    finally:
        if proc and proc.poll() is None:
            proc.send_signal(signal.SIGINT)
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()
        log.close()
        httpd.shutdown()
        shutil.rmtree(home, ignore_errors=True)
    print("decision models e2e: all checks passed")


if __name__ == "__main__":
    main()
