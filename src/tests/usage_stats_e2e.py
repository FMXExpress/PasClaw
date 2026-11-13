#!/usr/bin/env python3
"""/v1/stats must add up to what the provider reported, and nothing else.

A provider's Chat returned a response record whose token counters it never
cleared. Whatever the reply left unset -- the cache counters when the
provider reported none, every counter when the call failed -- was whatever
the memory held before, and the gateway added that to the stored totals:
one good turn against an OpenAI-compatible provider showed 1.6 billion
cache-read tokens the provider never reported, and one refused turn (401)
put a billion on the input count.

Against the real binary, once per provider kind (openai, anthropic,
gemini), with a fake provider this script runs -- and once more for openai
with the stream idle watcher off (stream_idle_timeout_ms 0), where a
provider call that raises reaches the gateway's own handler instead of the
watcher's. The fake speaks all three wire formats and answers by a mode
file:

  ok       a reply with input/output counts and no cache counts
  cached   a reply that also reports cache counts (the same as ok for
           gemini, whose cache figure PasClaw does not read)
  nousage  a reply with no usage object at all
  refuse   401
  garbled  200 with a body cut off mid-JSON, which the provider code raises on

After every turn the stored totals must equal exactly the sum of what the
fake reported so far: a refused or garbled turn and a reply without usage
add no tokens, and a cache count appears only when the provider sent one.
Each mode is driven plain and streamed, and through /v1/responses. A
failed /v1/responses reply must not carry made-up counts either.

/v1/stats keeps its answer for five seconds, so the per-turn check reads
the stats buckets the gateway saves (workspace/sessions/*.json, what
/v1/stats sums)
and /v1/stats itself is asked once, at the end, when nothing is cached.

usage: usage_stats_e2e.py <pasclaw-binary>
"""
import http.server
import json
import os
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

IN, OUT, CACHE_READ, CACHE_NEW = 11, 7, 5, 3
REPLY = "all good here"
LOG = None


def fail(msg):
    print("FAIL: " + msg)
    if LOG and os.path.exists(LOG):
        with open(LOG, errors="replace") as f:
            print("---- gateway log (tail) ----\n" + "".join(f.readlines()[-20:]))
    sys.exit(1)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Provider(http.server.BaseHTTPRequestHandler):
    """One fake for the three wire formats. `reported` is the running sum of
    the usage it has sent: what /v1/stats is held to."""
    mode_file = None
    reported = {"input": 0, "output": 0, "cache_read": 0, "cache_created": 0}
    calls = 0
    lock = threading.Lock()

    def mode(self):
        with open(Provider.mode_file) as f:
            return f.read().strip()

    def count(self, cached, kind):
        with Provider.lock:
            Provider.reported["input"] += IN
            Provider.reported["output"] += OUT
            if cached and kind != "gemini":
                Provider.reported["cache_read"] += CACHE_READ
                # Only Anthropic's wire reports cache writes.
                if kind == "anthropic":
                    Provider.reported["cache_created"] += CACHE_NEW

    def send(self, status, body, ctype="application/json"):
        out = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def sse(self, events):
        out = "".join(("event: %s\n" % ev if ev else "") + "data: %s\n\n" %
                      (d if isinstance(d, str) else json.dumps(d)) for ev, d in events)
        self.send(200, out.encode(), "text/event-stream")

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        with Provider.lock:
            Provider.calls += 1
        mode = self.mode()
        if mode == "refuse":
            self.send(401, {"error": {"message": "Incorrect API key provided",
                                      "type": "invalid_request_error"}})
            return
        if mode == "garbled":
            self.send(200, b'{"id": "c1", "choices": [{"index": 0, "mess')
            return
        usage, cached = mode != "nousage", mode == "cached"
        if "/messages" in self.path:
            kind = "anthropic"
        elif "generateContent" in self.path:
            kind = "gemini"
        else:
            kind = "openai"
        if usage:
            self.count(cached, kind)
        getattr(self, kind)(body, usage, cached)

    def openai(self, body, usage, cached):
        u = {"prompt_tokens": IN, "completion_tokens": OUT, "total_tokens": IN + OUT}
        if cached:
            u["prompt_tokens_details"] = {"cached_tokens": CACHE_READ}
        if body.get("stream"):
            ev = [(None, {"id": "c1", "model": "m", "choices": [
                {"index": 0, "delta": {"role": "assistant", "content": REPLY}}]}),
                  (None, {"id": "c1", "model": "m", "choices": [
                      {"index": 0, "delta": {}, "finish_reason": "stop"}]})]
            if usage:
                ev.append((None, {"id": "c1", "model": "m", "choices": [], "usage": u}))
            ev.append((None, "[DONE]"))
            self.sse(ev)
            return
        out = {"id": "c1", "object": "chat.completion", "model": "m",
               "choices": [{"index": 0, "finish_reason": "stop",
                            "message": {"role": "assistant", "content": REPLY}}]}
        if usage:
            out["usage"] = u
        self.send(200, out)

    def anthropic(self, body, usage, cached):
        u = {"input_tokens": IN, "output_tokens": OUT}
        if cached:
            u["cache_read_input_tokens"] = CACHE_READ
            u["cache_creation_input_tokens"] = CACHE_NEW
        if body.get("stream"):
            start = {"id": "m1", "type": "message", "role": "assistant", "model": "m",
                     "content": []}
            delta = {"type": "message_delta", "delta": {"stop_reason": "end_turn"}}
            if usage:
                start["usage"] = dict(u, output_tokens=0)
                delta["usage"] = {"output_tokens": OUT}
            self.sse([
                ("message_start", {"type": "message_start", "message": start}),
                ("content_block_start", {"type": "content_block_start", "index": 0,
                                         "content_block": {"type": "text", "text": ""}}),
                ("content_block_delta", {"type": "content_block_delta", "index": 0,
                                         "delta": {"type": "text_delta", "text": REPLY}}),
                ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                ("message_delta", delta),
                ("message_stop", {"type": "message_stop"})])
            return
        out = {"id": "m1", "type": "message", "role": "assistant", "model": "m",
               "stop_reason": "end_turn", "content": [{"type": "text", "text": REPLY}]}
        if usage:
            out["usage"] = u
        self.send(200, out)

    def gemini(self, body, usage, cached):
        out = {"modelVersion": "m", "candidates": [
            {"finishReason": "STOP", "content": {"role": "model", "parts": [{"text": REPLY}]}}]}
        if usage:
            out["usageMetadata"] = {"promptTokenCount": IN, "candidatesTokenCount": OUT}
        self.send(200, out)

    def log_message(self, *a):
        pass


class Gateway:
    def __init__(self, binary, kind, extra=None):
        global LOG
        self.home = tempfile.mkdtemp(prefix="pasclaw-usage-stats-e2e-")
        os.makedirs(os.path.join(self.home, "ws"))
        Provider.mode_file = os.path.join(self.home, "mode")
        Provider.reported = {k: 0 for k in Provider.reported}
        Provider.calls = 0
        self.mode("ok")
        pport = free_port()
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", pport), Provider)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.port = free_port()
        self.base = "http://127.0.0.1:%d" % self.port
        api_base = "http://127.0.0.1:%d" % pport + ("/v1" if kind == "openai" else "")
        cfg = {
            "providers": [{"name": "fake", "kind": kind, "api_base": api_base,
                           "api_key": "sk-test", "model": "m"}],
            "default_provider": "fake", "default_model": "m",
            "stats_collection_enabled": True,
            "sandbox": {"workspace": os.path.join(self.home, "ws")},
            "gateway": {"port": self.port, "bind_addr": "127.0.0.1"},
        }
        cfg.update(extra or {})
        with open(os.path.join(self.home, "config.json"), "w") as f:
            json.dump(cfg, f)
        LOG = os.path.join(self.home, "gateway.log")
        self.log = open(LOG, "w")
        self.proc = subprocess.Popen([binary, "gateway", "--port", str(self.port),
                                      "--addr", "127.0.0.1"],
                                     env=dict(os.environ, PASCLAW_HOME=self.home),
                                     cwd=self.home, stdin=subprocess.DEVNULL,
                                     stdout=self.log, stderr=subprocess.STDOUT)
        for _ in range(80):
            try:
                urllib.request.urlopen(self.base + "/v1/health", timeout=1).read()
                return
            except Exception:
                time.sleep(0.25)
        self.stop()
        fail("gateway never answered /v1/health")

    def mode(self, name):
        with open(Provider.mode_file, "w") as f:
            f.write(name)

    def post(self, path, body):
        """(status, text) -- a non-2xx is a result here, not an exception."""
        r = urllib.request.Request(self.base + path, data=json.dumps(body).encode(),
                                   method="POST")
        r.add_header("Content-Type", "application/json")
        try:
            resp = urllib.request.urlopen(r, timeout=120)
            return resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")

    @staticmethod
    def totals(s):
        return {"input": s.get("input_tokens", 0), "output": s.get("output_tokens", 0),
                "cache_read": s.get("cache_read_tokens", 0),
                "cache_created": s.get("cache_created_tokens", 0)}, s.get("turns", 0)

    def saved(self):
        """(totals, turns) summed over the saved stats buckets."""
        total, turns = {k: 0 for k in Provider.reported}, 0
        d = os.path.join(self.home, "workspace", "sessions")
        for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if not name.endswith(".json") or name.endswith(".orig.json"):
                continue
            with open(os.path.join(d, name)) as f:
                doc = json.load(f)
            one, n = self.totals((doc.get("meta") or {}).get("stats") or {})
            for k in total:
                total[k] += one[k]
            turns += n
        return total, turns

    def stats(self):
        return self.totals(json.loads(
            urllib.request.urlopen(self.base + "/v1/stats", timeout=10).read()))

    def stop(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.log.close()
        self.httpd.shutdown()
        shutil.rmtree(self.home, ignore_errors=True)


# A function tool on a /v1/responses request sends it down the passthrough
# path, which counts the provider's usage itself instead of the tool loop's.
FN_TOOL = [{"type": "function", "name": "noop", "description": "does nothing",
            "parameters": {"type": "object", "properties": {}}}]

REQUESTS = [
    ("chat",                  "/v1/chat/completions", {"messages": [{"role": "user", "content": "hi"}]}),
    ("chat, streamed",        "/v1/chat/completions", {"stream": True, "messages": [{"role": "user", "content": "hi"}]}),
    ("responses",             "/v1/responses", {"input": "hi"}),
    ("responses, tools",      "/v1/responses", {"input": "hi", "tools": FN_TOOL}),
    ("responses, tools, streamed", "/v1/responses", {"input": "hi", "tools": FN_TOOL, "stream": True}),
]


def usages(text):
    """Every usage object in a /v1/responses reply: the JSON body, or the
    response objects its stream events carry."""
    docs = []
    try:
        docs.append(json.loads(text))
    except ValueError:
        for line in text.splitlines():
            if line.startswith("data:"):
                try:
                    docs.append(json.loads(line[5:]))
                except ValueError:
                    pass
    out = []
    for d in docs:
        if not isinstance(d, dict):
            continue
        for holder in (d, d.get("response") or {}):
            if isinstance(holder.get("usage"), dict):
                out.append(holder["usage"])
    return out


def run_kind(binary, kind, extra=None, label=None):
    gw = Gateway(binary, kind, extra)
    label = label or kind
    try:
        turns = 0
        # garbled straight after a turn that reported counts: a reply built
        # from memory nobody cleared then shows that turn's leftovers.
        for mode in ("ok", "garbled", "refuse", "nousage", "cached", "garbled", "refuse", "ok"):
            gw.mode(mode)
            failing = mode in ("refuse", "garbled")
            requests = list(REQUESTS)
            if mode == "garbled":
                # The plain passthrough again, a few times over: its failed
                # reply is built from a record the raised call never filled,
                # and what that memory holds varies from one request to the
                # next.
                requests += [r for r in REQUESTS if r[0] == "responses, tools"] * 3
            for name, path, body in requests:
                before = Provider.calls
                status, text = gw.post(path, body)
                if Provider.calls == before:
                    fail("%s: %s (%s) never reached the provider: %d %s"
                         % (label, name, mode, status, text[:300]))
                if not failing and (status != 200 or REPLY not in text):
                    fail("%s: %s (%s) did not answer: %d %s" % (label, name, mode, status, text[:300]))
                if failing:
                    # What a failed /v1/responses reply says about usage is
                    # part of the answer the client gets.
                    for u in usages(text):
                        if any(u.get(k) for k in ("input_tokens", "output_tokens", "total_tokens")):
                            fail("%s: %s (%s) failed and still reported usage %s"
                                 % (label, name, mode, u))
                # A streamed turn is counted after its last byte is sent, and
                # a call that raised may not be counted as a turn at all.
                for _ in range(100 if not failing else 10):
                    got, got_turns = gw.saved()
                    if got_turns > turns:
                        break
                    time.sleep(0.05)
                if got != Provider.reported:
                    fail("%s: after %s (%s) the saved totals are %s, the provider reported %s"
                         % (label, name, mode, got, Provider.reported))
                if got_turns != turns + 1 and not (mode == "garbled" and got_turns == turns):
                    fail("%s: after %s (%s) %s turns are saved, want %d"
                         % (label, name, mode, got_turns, turns + 1))
                turns = got_turns
        got, got_turns = gw.stats()
        if got != Provider.reported or got_turns != turns:
            fail("%s: /v1/stats shows %s over %s turns, the provider reported %s over %d"
                 % (label, got, got_turns, Provider.reported, turns))
        want_cache = CACHE_READ * len(REQUESTS) if kind != "gemini" else None
        if want_cache is not None and Provider.reported["cache_read"] != want_cache:
            fail("%s: the fake reported %d cache reads, want %d"
                 % (label, Provider.reported["cache_read"], want_cache))
        print("  ok: %s -- %d turns, totals equal the provider's own figures %s"
              % (label, turns, Provider.reported))
    finally:
        gw.stop()


def main():
    if len(sys.argv) != 2 or not os.path.exists(sys.argv[1]):
        print("  skip: needs the pasclaw binary")
        return
    binary = os.path.abspath(sys.argv[1])
    for kind in ("openai", "anthropic", "gemini"):
        run_kind(binary, kind)
    run_kind(binary, "openai", {"stream_reliability": {"stream_idle_timeout_ms": 0}},
             "openai, stream watcher off")
    print("usage stats e2e: all checks passed")


if __name__ == "__main__":
    main()
