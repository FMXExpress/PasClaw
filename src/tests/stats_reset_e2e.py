#!/usr/bin/env python3
"""POST /v1/stats/reset puts the saved totals back to zero and keeps the
conversations.

The Stats tab's Reset button. Totals only ever grow, so wrong ones --
builds before the provider usage fix added leftover memory to them --
stay wrong for good without it.

Against the real binary, with a fake OpenAI-compatible provider this
script runs (11 input and 7 output tokens a reply). Seeded: turns through
/v1/chat/completions (the gateway's stats bucket), a conversation the
gateway saved (web1: a transcript, no counters) and two the CLI saved
(cli1, cli2: transcripts with counters). Checked:

  - a GET, and a POST from another site's page, reset nothing;
  - the reset empties every counter, /v1/stats says so at once (its
    five-second cache is dropped) and the bucket files are gone;
  - cli1 keeps its transcript, title and dates, and web1, which had
    nothing to clear, is not rewritten at all;
  - cli2 has a turn running on the gateway during the first reset: it is
    skipped and reported, its counters untouched, and the reset does not
    wait for it; once the turn is done a second reset clears it, and its
    transcript -- the turn that ran meanwhile included -- and transcript
    log are as they were;
  - counting starts again from zero with the next turn.

usage: stats_reset_e2e.py <pasclaw-binary>
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

IN, OUT = 11, 7
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
    """OpenAI chat completions. While the hold file exists a request waits
    before it is answered -- a turn that is still running."""
    hold_file = None
    holding = threading.Event()

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if os.path.exists(Provider.hold_file):
            Provider.holding.set()
            while os.path.exists(Provider.hold_file):
                time.sleep(0.05)
        out = json.dumps({"id": "c1", "object": "chat.completion", "model": "m",
                          "choices": [{"index": 0, "finish_reason": "stop",
                                       "message": {"role": "assistant", "content": REPLY}}],
                          "usage": {"prompt_tokens": IN, "completion_tokens": OUT}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


class Gateway:
    def __init__(self, binary):
        global LOG
        self.binary = binary
        self.home = tempfile.mkdtemp(prefix="pasclaw-stats-reset-e2e-")
        os.makedirs(os.path.join(self.home, "ws"))
        self.sessions = os.path.join(self.home, "workspace", "sessions")
        Provider.hold_file = os.path.join(self.home, "hold")
        pport = free_port()
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", pport), Provider)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.port = free_port()
        self.base = "http://127.0.0.1:%d" % self.port
        cfg = {
            "providers": [{"name": "fake", "kind": "openai",
                           "api_base": "http://127.0.0.1:%d/v1" % pport,
                           "api_key": "sk-test", "model": "m"}],
            "default_provider": "fake", "default_model": "m",
            "stats_collection_enabled": True,
            "sandbox": {"workspace": os.path.join(self.home, "ws")},
            "gateway": {"port": self.port, "bind_addr": "127.0.0.1"},
        }
        with open(os.path.join(self.home, "config.json"), "w") as f:
            json.dump(cfg, f)
        self.env = dict(os.environ, PASCLAW_HOME=self.home)
        LOG = os.path.join(self.home, "gateway.log")
        self.log = open(LOG, "w")
        self.proc = subprocess.Popen([binary, "gateway", "--port", str(self.port),
                                      "--addr", "127.0.0.1"],
                                     env=self.env, cwd=self.home, stdin=subprocess.DEVNULL,
                                     stdout=self.log, stderr=subprocess.STDOUT)
        for _ in range(80):
            try:
                urllib.request.urlopen(self.base + "/v1/health", timeout=1).read()
                return
            except Exception:
                time.sleep(0.25)
        self.stop()
        fail("gateway never answered /v1/health")

    def call(self, method, path, body=None, headers=None, timeout=120):
        """(status, parsed JSON or text) -- a non-2xx is a result, not an
        exception, and no answer in time is status 0."""
        data = json.dumps(body).encode() if body is not None else (b"" if method == "POST" else None)
        r = urllib.request.Request(self.base + path, data=data, method=method)
        r.add_header("Content-Type", "application/json")
        for k, v in (headers or {}).items():
            r.add_header(k, v)
        try:
            resp = urllib.request.urlopen(r, timeout=timeout)
            status, text = resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            status, text = e.code, e.read().decode("utf-8", "replace")
        except (socket.timeout, TimeoutError, urllib.error.URLError) as e:
            return 0, "no answer: %s" % e
        try:
            return status, json.loads(text)
        except ValueError:
            return status, text

    def turn(self, text, session=None, context=False):
        body = {"messages": [{"role": "user", "content": text}]}
        if context:
            body["session_context"] = True
        status, out = self.call("POST", "/v1/chat/completions", body,
                                {"X-PasClaw-Session": session} if session else None)
        if status != 200 or REPLY not in json.dumps(out):
            fail("a turn did not answer: %d %s" % (status, str(out)[:300]))

    def cli_turn(self, text, session):
        """A conversation the command line saves, with its own counters."""
        subprocess.run([self.binary, "agent", "-m", text, "--session", session, "--quiet"],
                       env=self.env, cwd=self.home, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)

    def path(self, sid, suffix=".json"):
        return os.path.join(self.sessions, sid + suffix)

    def raw(self, sid, suffix=".json"):
        with open(self.path(sid, suffix), "rb") as f:
            return f.read()

    def doc(self, sid):
        return json.loads(self.raw(sid))

    def counters(self, sid):
        st = (self.doc(sid).get("meta") or {}).get("stats") or {}
        return (st.get("input_tokens", 0), st.get("output_tokens", 0), st.get("turns", 0))

    def buckets(self):
        return sorted(n for n in os.listdir(self.sessions)
                      if n.startswith("_gateway_") and n.endswith(".json"))

    def stats(self):
        status, s = self.call("GET", "/v1/stats")
        if status != 200:
            fail("/v1/stats answered %d" % status)
        return {k: s.get(k) for k in ("input_tokens", "output_tokens", "cache_read_tokens",
                                      "cache_created_tokens", "turns", "tool_calls",
                                      "truncation_bytes_saved", "sessions")}

    def stop(self):
        if os.path.exists(Provider.hold_file):
            os.remove(Provider.hold_file)
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.log.close()
        self.httpd.shutdown()
        shutil.rmtree(self.home, ignore_errors=True)


def totals(inp, out, turns, sessions):
    return {"input_tokens": inp, "output_tokens": out, "cache_read_tokens": 0,
            "cache_created_tokens": 0, "turns": turns, "tool_calls": 0,
            "truncation_bytes_saved": 0, "sessions": sessions}


def main():
    if len(sys.argv) != 2 or not os.path.exists(sys.argv[1]):
        print("  skip: needs the pasclaw binary")
        return
    gw = Gateway(os.path.abspath(sys.argv[1]))
    try:
        # ---- seed ----
        gw.turn("one")
        gw.turn("two")
        gw.turn("a saved conversation", session="web1")
        gw.cli_turn("hello from the command line", "cli1")
        gw.cli_turn("another from the command line", "cli2")
        for sid in ("web1", "cli1", "cli2"):
            if not os.path.exists(gw.path(sid)):
                fail("seeding: the session %s was not saved" % sid)
        if gw.counters("web1") != (0, 0, 0):
            fail("seeding: web1 was expected to carry no counters: %s" % (gw.counters("web1"),))
        for sid in ("cli1", "cli2"):
            if gw.counters(sid) != (IN, OUT, 1):
                fail("seeding: %s counters are %s, want %s" % (sid, gw.counters(sid), (IN, OUT, 1)))
        if len(gw.buckets()) != 1:
            fail("seeding: want one stats bucket, got %s" % gw.buckets())
        seeded = totals(5 * IN, 5 * OUT, 5, 4)
        if gw.stats() != seeded:
            fail("seeding: /v1/stats shows %s, want %s" % (gw.stats(), seeded))
        before = {sid: gw.doc(sid) for sid in ("web1", "cli1", "cli2")}
        web1_bytes = gw.raw("web1")
        print("  ok: seeded -- one bucket, a gateway conversation, two CLI conversations: %d tokens in"
              % seeded["input_tokens"])

        # ---- what must not reset anything ----
        status, _ = gw.call("GET", "/v1/stats/reset")
        if status == 200:
            fail("GET /v1/stats/reset answered 200: a reset must be a POST")
        status, out = gw.call("POST", "/v1/stats/reset", headers={"Origin": "http://evil.example"})
        if status != 403:
            fail("a POST from another site's page answered %d, want 403: %s" % (status, out))
        if gw.stats() != seeded or len(gw.buckets()) != 1 or gw.counters("cli1") != (IN, OUT, 1):
            fail("a refused request changed the totals: %s" % gw.stats())
        print("  ok: a GET and a cross-site POST reset nothing")

        # ---- reset while cli2 has a turn running ----
        open(Provider.hold_file, "w").close()
        Provider.holding.clear()
        held = threading.Thread(target=gw.turn, args=("while the reset happens",),
                                kwargs={"session": "cli2", "context": True})
        held.start()
        if not Provider.holding.wait(30):
            fail("the held turn never reached the provider")
        if gw.stats() != seeded:          # and /v1/stats now holds this for five seconds
            fail("totals moved before the reset: %s" % gw.stats())
        status, out = gw.call("POST", "/v1/stats/reset", timeout=10)
        if status == 0:
            fail("the reset waited for the running turn instead of skipping it (%s)" % out)
        if status != 200 or not isinstance(out, dict) or not out.get("ok"):
            fail("POST /v1/stats/reset answered %d %s" % (status, out))
        want = {"ok": True, "sessions_reset": 1, "buckets_removed": 1, "sessions_skipped": 1}
        if out != want:
            fail("the reset reported %s, want %s" % (out, want))
        after = gw.stats()                 # inside the five seconds: the cache must be gone
        if after != totals(IN, OUT, 1, 3):
            fail("right after the reset /v1/stats shows %s, want only cli2's counters %s"
                 % (after, totals(IN, OUT, 1, 3)))
        if gw.buckets():
            fail("the stats buckets were not removed: %s" % gw.buckets())
        if gw.counters("cli1") != (0, 0, 0):
            fail("cli1 still has counters: %s" % (gw.counters("cli1"),))
        if gw.counters("cli2") != (IN, OUT, 1):
            fail("cli2 has a turn running and was touched anyway: %s" % (gw.counters("cli2"),))
        print("  ok: reset -- totals gone at once, bucket removed, the session in use skipped and reported")

        # ---- the conversations are as they were ----
        now = gw.doc("cli1")
        if now.get("messages") != before["cli1"].get("messages") or not now.get("messages"):
            fail("cli1's transcript changed:\n  %s\n  %s" % (now.get("messages"), before["cli1"].get("messages")))
        for key in ("id", "title", "updated_at", "created_at", "model", "provider", "location"):
            if now["meta"].get(key) != before["cli1"]["meta"].get(key):
                fail("cli1's %s changed: %r -> %r" % (key, before["cli1"]["meta"].get(key), now["meta"].get(key)))
        if "stats" in now["meta"]:
            fail("cli1 still has a stats block: %s" % now["meta"]["stats"])
        if gw.raw("web1") != web1_bytes:
            fail("web1 had nothing to clear and was rewritten anyway")
        status, got = gw.call("GET", "/v1/sessions/cli1")
        if status != 200 or len(got.get("messages", [])) != len(before["cli1"]["messages"]):
            fail("/v1/sessions/cli1 no longer returns the transcript: %d %s" % (status, str(got)[:200]))
        leftovers = [n for n in os.listdir(gw.sessions) if n.endswith(".tmp")]
        if leftovers:
            fail("temporary files left behind: %s" % leftovers)
        print("  ok: cli1 keeps its transcript, title and dates; web1 was not rewritten")

        # ---- the held turn finishes; a second reset clears what was skipped ----
        os.remove(Provider.hold_file)
        held.join(60)
        if held.is_alive():
            fail("the held turn never finished")
        for _ in range(100):               # its bucket is written after the reply is sent
            if gw.buckets():
                break
            time.sleep(0.05)
        msgs = gw.doc("cli2").get("messages", [])
        if not any("while the reset happens" in str(m.get("content")) for m in msgs) or \
                not any(m.get("role") == "assistant" and REPLY in str(m.get("content")) for m in msgs[-1:]):
            fail("the turn that ran during the reset was not saved whole: %s" % msgs[-3:])
        if not os.path.exists(gw.path("cli2", ".log.jsonl")):
            fail("premise: the gateway turn on cli2 wrote no transcript log")
        cli2_log, cli2_meta = gw.raw("cli2", ".log.jsonl"), gw.doc("cli2")["meta"]
        if gw.counters("cli2") != (IN, OUT, 1):
            fail("premise: cli2's own counters after its gateway turn are %s" % (gw.counters("cli2"),))
        status, out = gw.call("POST", "/v1/stats/reset")
        want = {"ok": True, "sessions_reset": 1, "buckets_removed": 1, "sessions_skipped": 0}
        if status != 200 or out != want:
            fail("the second reset reported %d %s, want %s" % (status, out, want))
        if gw.stats() != totals(0, 0, 0, 3):
            fail("after the second reset /v1/stats shows %s, want all zero" % gw.stats())
        now = gw.doc("cli2")
        if now.get("messages") != msgs:
            fail("cli2's transcript changed in the second reset")
        if gw.raw("cli2", ".log.jsonl") != cli2_log:
            fail("cli2's transcript log changed in the second reset")
        if dict(cli2_meta, stats=None) != dict(now["meta"], stats=None) or "stats" in now["meta"]:
            fail("cli2's record changed beyond its counters:\n  %s\n  %s" % (cli2_meta, now["meta"]))
        print("  ok: once its turn was done, a second reset cleared the skipped session too")

        # ---- nothing to do is fine, and counting starts again from zero ----
        status, out = gw.call("POST", "/v1/stats/reset")
        if status != 200 or out != {"ok": True, "sessions_reset": 0, "buckets_removed": 0, "sessions_skipped": 0}:
            fail("a reset with nothing to clear reported %d %s" % (status, out))
        gw.turn("after the reset")
        for _ in range(100):
            if gw.buckets():
                break
            time.sleep(0.05)
        if len(gw.buckets()) != 1 or gw.counters(gw.buckets()[0][:-5]) != (IN, OUT, 1):
            fail("after the reset the next turn was counted as %s in %s, want %s"
                 % (gw.counters(gw.buckets()[0][:-5]) if gw.buckets() else None, gw.buckets(), (IN, OUT, 1)))
        print("  ok: the next turn is counted from zero")
    finally:
        gw.stop()
    print("stats reset e2e: all checks passed")


if __name__ == "__main__":
    main()
