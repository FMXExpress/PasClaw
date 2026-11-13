#!/usr/bin/env python3
"""A provider that refuses is an error, not the assistant's reply.

When the provider call failed, /v1/chat/completions used to hand the
provider's error text back as the answer -- HTTP 200, finish_reason
"stop", the text as content -- and saved it in the session as an
assistant message. The web UI kept it in its history, a session_context
client got it back from the store, and either way it went to the model on
the next turn as something the assistant had said.

Against the real binary, with a fake OpenAI-compatible provider this
script runs: it answers normally, or -- while a flag file exists -- refuses
with 401 "Incorrect API key provided". Checked:

  - non-streaming: 502 with the provider's message, type provider_error,
    the upstream status;
  - streaming: an OpenAI error frame then [DONE], and the error text in no
    content delta;
  - the saved session keeps the user's message and gains no assistant
    message carrying the error;
  - a session_context turn after a failed one sends the provider no
    assistant message with the error text;
  - a turn that works is still saved with its reply.

usage: provider_error_e2e.py <pasclaw-binary>
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

REFUSAL = "Incorrect API key provided"
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
    """OpenAI chat completions: 401 while the flag file exists, else a reply.
    Records every request body."""
    flag = None
    seen = []

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        Provider.seen.append(body)
        if os.path.exists(Provider.flag):
            out = json.dumps({"error": {"message": REFUSAL, "type": "invalid_request_error",
                                        "code": "invalid_api_key"}}).encode()
            self.send_response(401)
        else:
            out = json.dumps({"id": "c1", "object": "chat.completion", "model": "m",
                              "choices": [{"index": 0, "finish_reason": "stop",
                                           "message": {"role": "assistant", "content": REPLY}}],
                              "usage": {"prompt_tokens": 1, "completion_tokens": 1}}).encode()
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
        self.home = tempfile.mkdtemp(prefix="pasclaw-provider-error-e2e-")
        os.makedirs(os.path.join(self.home, "ws"))
        Provider.flag = os.path.join(self.home, "refuse")
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
            "sandbox": {"workspace": os.path.join(self.home, "ws")},
            "gateway": {"port": self.port, "bind_addr": "127.0.0.1"},
        }
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

    def refuse(self, on):
        if on:
            open(Provider.flag, "w").close()
        elif os.path.exists(Provider.flag):
            os.remove(Provider.flag)

    def post(self, body, session=None):
        """(status, text) -- a non-2xx is a result here, not an exception."""
        r = urllib.request.Request(self.base + "/v1/chat/completions",
                                   data=json.dumps(body).encode(), method="POST")
        r.add_header("Content-Type", "application/json")
        if session:
            r.add_header("X-PasClaw-Session", session)
        try:
            resp = urllib.request.urlopen(r, timeout=120)
            return resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")

    def session(self, sid):
        return json.loads(urllib.request.urlopen(
            self.base + "/v1/sessions/" + sid, timeout=10).read())

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


def contents(msgs):
    out = []
    for m in msgs:
        c = m.get("content")
        if isinstance(c, list):
            c = " ".join(str(p.get("text", "")) for p in c if isinstance(p, dict))
        out.append((m.get("role"), c or ""))
    return out


def main():
    if len(sys.argv) != 2 or not os.path.exists(sys.argv[1]):
        print("  skip: needs the pasclaw binary")
        return
    gw = Gateway(os.path.abspath(sys.argv[1]))
    try:
        gw.refuse(True)

        # ---- non-streaming: an error, not an answer ----
        status, text = gw.post({"messages": [{"role": "user", "content": "hello"}]},
                               session="perr-plain")
        if status != 502:
            fail("non-streaming refusal answered HTTP %d, want 502: %s" % (status, text[:300]))
        err = json.loads(text).get("error") or {}
        if REFUSAL not in err.get("message", "") or err.get("type") != "provider_error" \
                or err.get("upstream_status") != 401:
            fail("non-streaming error object: %s" % err)
        msgs = contents(gw.session("perr-plain").get("messages", []))
        if ("user", "hello") not in [(r, c.split("\n\n[current date/time")[0]) for r, c in msgs]:
            fail("the user's message was not saved: %s" % msgs)
        if any(r == "assistant" and REFUSAL in c for r, c in msgs):
            fail("the provider's error was saved as the assistant's reply: %s" % msgs)
        print("  ok: non-streaming refusal is a 502 with the provider's message, not saved as a reply")

        # ---- streaming: an error frame, no error text as content ----
        status, raw = gw.post({"stream": True, "messages": [{"role": "user", "content": "hi"}]},
                              session="perr-stream")
        frames, content = [], ""
        for line in raw.splitlines():
            if line.startswith("data:") and line[5:].strip() != "[DONE]":
                try:
                    ev = json.loads(line[5:].strip())
                except ValueError:
                    continue
                if "error" in ev:
                    frames.append(ev["error"])
                for ch in ev.get("choices", []):
                    content += (ch.get("delta") or {}).get("content") or ""
        if not frames or REFUSAL not in frames[-1].get("message", ""):
            fail("no error frame carrying the provider's message: %s" % raw[-600:])
        if REFUSAL in content:
            fail("the provider's error was streamed as the answer: %r" % content)
        if "data: [DONE]" not in raw:
            fail("the stream did not end with [DONE]")
        msgs = contents(gw.session("perr-stream").get("messages", []))
        if any(r == "assistant" and REFUSAL in c for r, c in msgs):
            fail("streaming: the error was saved as the assistant's reply: %s" % msgs)
        print("  ok: streaming refusal is an error frame, never content, never saved as a reply")

        # ---- session_context: the next turn does not hear the error ----
        sid = "perr-ctx"
        gw.post({"session_context": True, "messages": [{"role": "user", "content": "first try"}]},
                session=sid)
        gw.refuse(False)
        n = len(Provider.seen)
        status, text = gw.post({"session_context": True,
                                "messages": [{"role": "user", "content": "second try"}]},
                               session=sid)
        if status != 200 or REPLY not in text:
            fail("the working turn failed: %d %s" % (status, text[:300]))
        sent = contents(Provider.seen[n]["messages"]) if len(Provider.seen) > n else []
        if not sent:
            fail("the provider got no request for the working turn")
        if any(REFUSAL in c for r, c in sent):
            fail("the next turn sent the provider its own earlier error: %s" % sent)
        if not any(r == "user" and c.startswith("first try") for r, c in sent):
            fail("the failed turn's question was lost from the history: %s" % sent)
        msgs = contents(gw.session(sid).get("messages", []))
        if not msgs or msgs[-1][0] != "assistant" or REPLY not in msgs[-1][1]:
            fail("a working turn's reply was not saved: %s" % msgs)
        print("  ok: after a failed turn the next one keeps the question, not the error; "
              "a working reply is saved")
    finally:
        gw.stop()
    print("provider error e2e: all checks passed")


if __name__ == "__main__":
    main()
