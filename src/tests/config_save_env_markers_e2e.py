#!/usr/bin/env python3
"""A Settings save keeps ${VAR} markers in config.json.

config.json names its provider's key and base URL as ${VAR} markers; the
gateway runs with those variables set. Through the same routes the web
UI's Settings tab uses:

  - GET /v1/config?source=file shows the key masked and the base URL as
    the marker it is in the file;
  - a PUT of that config with the default model changed writes
    config.json with both markers still there -- not the key or the URL
    they stand for (a save used to write the key in plain text);
  - the change is applied live with the markers resolved: the next chat
    reaches the provider with the real key, at the real URL, asking for
    the new model.

usage: config_save_env_markers_e2e.py <pasclaw-binary>
"""
import http.server
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

KEY_VAR, BASE_VAR = "PASCLAW_MARKER_TEST_KEY_X7", "PASCLAW_MARKER_TEST_BASE_X7"
REAL_KEY = "sk-real-marker-x7"
SEEN = []   # (authorization header, model) per chat request


class Provider(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        SEEN.append((self.headers.get("Authorization", ""), body.get("model", "")))
        out = json.dumps({"id": "c1", "object": "chat.completion", "model": body.get("model", ""),
                          "choices": [{"index": 0, "finish_reason": "stop",
                                       "message": {"role": "assistant", "content": "hello"}}],
                          "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def fail(msg, log=None):
    print("FAIL: " + msg)
    if log and os.path.exists(log):
        print("---- gateway log (tail) ----\n" + "".join(open(log, errors="replace").readlines()[-20:]))
    sys.exit(1)


def call(base, method, path, body=None):
    req = urllib.request.Request(base + path, method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or b"{}")


def main():
    binary = os.path.abspath(sys.argv[1])
    home = tempfile.mkdtemp(prefix="pasclaw-env-markers-e2e-")
    pport, gport = free_port(), free_port()
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", pport), Provider)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    real_base = "http://127.0.0.1:%d/v1" % pport
    cfg_path = os.path.join(home, "config.json")
    with open(cfg_path, "w") as f:
        json.dump({"providers": [{"name": "fake", "kind": "openai", "api_base": "${%s}" % BASE_VAR,
                                  "api_key": "${%s}" % KEY_VAR, "model": "m1"}],
                   "default_provider": "fake", "default_model": "m1",
                   "gateway": {"port": gport, "bind_addr": "127.0.0.1"}}, f)
    env = dict(os.environ, PASCLAW_HOME=home, NO_COLOR="1", **{KEY_VAR: REAL_KEY, BASE_VAR: real_base})
    log = os.path.join(home, "gateway.log")
    gw = None
    try:
        with open(log, "w") as lf:
            gw = subprocess.Popen([binary, "gateway", "--port", str(gport), "--addr", "127.0.0.1", "--no-tools"],
                                  env=env, cwd=home, stdin=subprocess.DEVNULL, stdout=lf, stderr=subprocess.STDOUT)
        base = "http://127.0.0.1:%d" % gport
        for _ in range(80):
            try:
                urllib.request.urlopen(base + "/v1/health", timeout=1).read()
                break
            except Exception:
                time.sleep(0.25)
        else:
            fail("the gateway never answered /v1/health", log)

        cfg = call(base, "GET", "/v1/config?source=file")
        p = cfg["providers"][0]
        if p.get("api_key") in ("", REAL_KEY, "${%s}" % KEY_VAR):
            fail("the key is not masked in GET /v1/config?source=file: %r" % p.get("api_key"), log)
        if p.get("api_base") != "${%s}" % BASE_VAR:
            fail("the saved file's base URL marker is not shown as written: %r" % p.get("api_base"), log)
        print("  ok: GET ?source=file masks the key and shows the marker as written")

        cfg["default_model"] = "m2"
        cfg["providers"][0]["model"] = "m2"
        res = call(base, "PUT", "/v1/config", cfg)
        if not res.get("saved"):
            fail("the save was refused: %r" % res, log)
        text = open(cfg_path).read()
        if REAL_KEY in text:
            fail("the save wrote the API key into config.json in plain text", log)
        if "${%s}" % KEY_VAR not in text or "${%s}" % BASE_VAR not in text:
            fail("the save dropped the ${VAR} markers: %s" % text[:400], log)
        if real_base in text:
            fail("the save wrote the resolved base URL over its marker", log)
        print("  ok: config.json keeps both markers; no key in plain text")

        SEEN.clear()
        call(base, "POST", "/v1/chat", {"message": "hi"})
        if not SEEN:
            fail("the chat after the save did not reach the provider at the resolved base URL", log)
        auth, model = SEEN[-1]
        if auth != "Bearer " + REAL_KEY:
            fail("the live provider did not get the resolved key: %r" % auth, log)
        if model != "m2":
            fail("the saved model was not applied live: %r" % model, log)
        print("  ok: applied live with the markers resolved (real key, real URL, new model)")
        print("config_save_env_markers_e2e: OK")
    finally:
        if gw and gw.poll() is None:
            gw.terminate()
            try:
                gw.wait(timeout=10)
            except subprocess.TimeoutExpired:
                gw.kill()
        httpd.shutdown()
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    main()
