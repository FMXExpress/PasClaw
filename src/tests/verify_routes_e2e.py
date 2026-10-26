#!/usr/bin/env python3
"""Held-out verification reaches every gateway route that answers with text.

RunCheckpointedLoop turns verification on for all gateway chat paths, but
only /v1/chat used to read the result: /v1/chat/completions and
/v1/responses returned the model's answer with an ordinary completed status
even when the operator's scenarios still failed (Codex P1 on #618).

Against the real binary: a scratch gateway with the relay provider (this
script answers as the model, "all done" every time) and one held-out
scenario, max_rounds 1. With the scenario failing, every route's answer
text ends with the NOT-verified notice, and the non-streaming JSON carries
verification.ok = false. With it passing, no notice and ok = true.

usage: verify_routes_e2e.py <pasclaw-binary>
"""
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
import urllib.request

NOTICE = "this answer is NOT verified"


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Gateway:
    def __init__(self, binary):
        self.home = tempfile.mkdtemp(prefix="pasclaw-verify-e2e-")
        self.ws = os.path.join(self.home, "ws")
        self.scen = os.path.join(self.home, "scenarios")
        os.makedirs(self.ws)
        os.makedirs(self.scen)
        self.port = free_port()
        self.base = "http://127.0.0.1:%d" % self.port
        cfg = {
            "providers": [{"name": "relay", "kind": "relay", "api_base": "", "api_key": "",
                           "model": "claude-router"}],
            "default_provider": "relay", "default_model": "claude-router",
            "relay_wait_timeout_ms": 60000,
            "sandbox": {"workspace": self.ws},
            "gateway": {"port": self.port, "bind_addr": "127.0.0.1"},
            "verification": {"scenarios": self.scen, "max_rounds": 1},
        }
        with open(os.path.join(self.home, "config.json"), "w") as f:
            json.dump(cfg, f)
        env = dict(os.environ, PASCLAW_HOME=self.home)
        self.log = open(os.path.join(self.home, "gateway.log"), "w")
        self.proc = subprocess.Popen([binary, "gateway", "--port", str(self.port),
                                      "--addr", "127.0.0.1"],
                                     env=env, stdin=subprocess.DEVNULL,
                                     stdout=self.log, stderr=subprocess.STDOUT)
        for _ in range(80):
            try:
                urllib.request.urlopen(self.base + "/v1/health", timeout=1).read()
                break
            except Exception:
                time.sleep(0.25)
        else:
            self.stop()
            fail("gateway never answered /v1/health")
        tok = json.loads(urllib.request.urlopen(self.base + "/v1/relay/worker-token").read())
        self.relay_token = tok.get("token") or tok.get("worker_token") or list(tok.values())[0]
        threading.Thread(target=self.model, daemon=True).start()
        time.sleep(0.5)

    def model(self):
        """The relay worker: every request gets the same final answer."""
        req = urllib.request.Request(self.base + "/v1/relay/poll")
        req.add_header("Authorization", "Bearer " + self.relay_token)
        req.add_header("Accept", "text/event-stream")
        req.add_header("X-Relay-Worker-Id", "claude-router")
        req.add_header("X-Relay-Capabilities", "")
        resp = urllib.request.urlopen(req, timeout=None)
        while True:
            line = resp.readline()
            if not line:
                return
            line = line.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            env = json.loads(line[5:].strip())
            body = json.dumps({"content": "all done", "finish_reason": "stop"}).encode()
            r = urllib.request.Request(self.base + "/v1/relay/respond/" + env["id"],
                                       data=body, method="POST")
            r.add_header("Authorization", "Bearer " + self.relay_token)
            r.add_header("Content-Type", "application/json")
            urllib.request.urlopen(r).read()

    def post(self, path, body):
        r = urllib.request.Request(self.base + path, data=json.dumps(body).encode(),
                                   method="POST")
        r.add_header("Content-Type", "application/json")
        return urllib.request.urlopen(r, timeout=60).read().decode("utf-8", "replace")

    def scenario(self, passing):
        with open(os.path.join(self.scen, "check.sh"), "w") as f:
            f.write("exit 0\n" if passing else "echo 'held-out check failed'; exit 1\n")

    def stop(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.log.close()
        shutil.rmtree(self.home, ignore_errors=True)


def sse_text(raw):
    """Everything a streaming client would display: the content deltas
    (chat/completions) or the text deltas (responses)."""
    out = []
    for line in raw.splitlines():
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            continue
        try:
            ev = json.loads(data)
        except ValueError:
            continue
        for ch in ev.get("choices", []):
            out.append((ch.get("delta") or {}).get("content") or "")
        if ev.get("type") == "response.output_text.delta":
            out.append(ev.get("delta") or "")
    return "".join(out)


def main():
    if len(sys.argv) != 2 or not os.path.exists(sys.argv[1]):
        print("  skip: needs the pasclaw binary")
        return
    gw = Gateway(os.path.abspath(sys.argv[1]))
    try:
        chat = {"model": "claude-router", "messages": [{"role": "user", "content": "build it"}]}
        resp = {"model": "claude-router", "input": "build it"}

        gw.scenario(passing=False)
        j = json.loads(gw.post("/v1/chat/completions", chat))
        text = j["choices"][0]["message"]["content"]
        if NOTICE not in text:
            fail("chat/completions: a failed check is not in the answer: " + text[:300])
        if (j.get("verification") or {}).get("ok") is not False:
            fail("chat/completions: no verification.ok=false in %s" % j.get("verification"))
        text = sse_text(gw.post("/v1/chat/completions", dict(chat, stream=True)))
        if NOTICE not in text:
            fail("chat/completions stream: a failed check is not in the answer: " + text[:300])
        raw = gw.post("/v1/responses", resp)
        j = json.loads(raw)
        if NOTICE not in raw:
            fail("responses: a failed check is not in the answer: " + raw[:300])
        if (j.get("verification") or {}).get("ok") is not False:
            fail("responses: no verification.ok=false in %s" % j.get("verification"))
        text = sse_text(gw.post("/v1/responses", dict(resp, stream=True)))
        if NOTICE not in text:
            fail("responses stream: a failed check is not in the answer: " + text[:300])
        print("  ok: a failed held-out check reaches chat/completions and responses, streamed or not")

        gw.scenario(passing=True)
        j = json.loads(gw.post("/v1/chat/completions", chat))
        if NOTICE in j["choices"][0]["message"]["content"]:
            fail("chat/completions: notice on a verified answer")
        if (j.get("verification") or {}).get("ok") is not True:
            fail("chat/completions: no verification.ok=true in %s" % j.get("verification"))
        raw = gw.post("/v1/responses", resp)
        if NOTICE in raw or (json.loads(raw).get("verification") or {}).get("ok") is not True:
            fail("responses: a verified answer is not reported as verified: " + raw[:300])
        print("  ok: a verified answer is left alone and reported ok")
    finally:
        gw.stop()
    print("PASS")


if __name__ == "__main__":
    main()
