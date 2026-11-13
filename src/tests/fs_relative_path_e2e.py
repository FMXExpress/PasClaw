#!/usr/bin/env python3
"""The /v1/fs routes read a relative path the way the file tools wrote it.

The web UI's chat Files list hands back each write_file call's own `path`
argument, which a model usually gives relative ("out.txt"). The tool
resolved that against the workspace; /v1/fs/read, /download and /peek took
it against the gateway process's working directory instead. With the
gateway launched anywhere but the workspace (any service, Docker, `serve`
from a home directory) every download from that list was a 403 for a file
that was right there -- or, launched in the workspace's parent, quietly a
different file of the same name.

Against the real binary, launched OUTSIDE its workspace -- from the parent
of its home, with PASCLAW_HOME given relative, as `make test` and a service
unit may -- with a fake OpenAI-compatible provider whose model writes
`notes/out.txt` and, as a decoy, a file of the same name in the launch
directory. Checked:

  - read, download and peek of the relative path return the file the tool
    wrote (and not the decoy);
  - the absolute path still works;
  - the listing reports its directory and roots absolute, and a client that
    builds its next request from them (the Files tab, the web desktop, the
    native client) gets the directory and the file: with a relative home
    they came out relative to the launch directory, which a relative path
    no longer means;
  - `../` and absolute paths outside the workspace are still refused, as
    is the gateway's own config.json.

usage: fs_relative_path_e2e.py <pasclaw-binary>
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
import urllib.parse
import urllib.request

CONTENT = "written by the agent\n"
DECOY = "the launch directory's file, not the workspace's\n"
LOG = None


def fail(msg):
    print("FAIL: " + msg)
    if LOG and os.path.exists(LOG):
        with open(LOG, errors="replace") as f:
            print("---- gateway log (tail) ----\n" + "".join(f.readlines()[-15:]))
    sys.exit(1)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Provider(http.server.BaseHTTPRequestHandler):
    """First call: the model writes notes/out.txt. After the tool result:
    a short answer."""

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        last = (body.get("messages") or [{}])[-1]
        if last.get("role") == "tool":
            msg, fin = {"role": "assistant", "content": "wrote it"}, "stop"
        else:
            msg = {"role": "assistant", "content": None, "tool_calls": [{
                "id": "c1", "type": "function",
                "function": {"name": "write_file",
                             "arguments": json.dumps({"path": "notes/out.txt", "content": CONTENT})}}]}
            fin = "tool_calls"
        if body.get("stream"):
            delta = dict(msg)
            if "tool_calls" in delta:
                delta["tool_calls"] = [dict(delta["tool_calls"][0], index=0)]
            frames = [{"choices": [{"index": 0, "delta": delta}]},
                      {"choices": [{"index": 0, "delta": {}, "finish_reason": fin}]},
                      {"choices": [], "usage": {"prompt_tokens": 1, "completion_tokens": 1}}]
            out = "".join("data: %s\n\n" % json.dumps(f) for f in frames) + "data: [DONE]\n\n"
            self.reply(out.encode(), "text/event-stream")
        else:
            self.reply(json.dumps({"id": "c", "object": "chat.completion", "model": "m",
                                   "choices": [{"index": 0, "finish_reason": fin, "message": msg}],
                                   "usage": {"prompt_tokens": 1, "completion_tokens": 1}}).encode(),
                       "application/json")

    def reply(self, out, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
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
    # launch/      the launch directory
    #   notes/out.txt   the decoy: the tool's relative name, not in the workspace
    #   h/         PASCLAW_HOME, given to the gateway as just "h"
    #     ws/      the sandbox workspace
    launch = os.path.realpath(tempfile.mkdtemp(prefix="pasclaw-fs-relative-e2e-"))
    home = os.path.join(launch, "h")
    ws = os.path.join(home, "ws")
    os.makedirs(ws)
    os.makedirs(os.path.join(home, "workspace", "projects"))
    os.makedirs(os.path.join(launch, "notes"))
    with open(os.path.join(launch, "notes", "out.txt"), "w") as f:
        f.write(DECOY)
    pport, gport = free_port(), free_port()
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", pport), Provider)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    with open(os.path.join(home, "config.json"), "w") as f:
        json.dump({"providers": [{"name": "fake", "kind": "openai",
                                  "api_base": "http://127.0.0.1:%d/v1" % pport,
                                  "api_key": "sk-test", "model": "m"}],
                   "default_provider": "fake", "default_model": "m",
                   "sandbox": {"workspace": ws},
                   "gateway": {"port": gport, "bind_addr": "127.0.0.1"}}, f)
    LOG = os.path.join(launch, "gateway.log")
    log = open(LOG, "w")
    proc = subprocess.Popen([binary, "gateway", "--port", str(gport), "--addr", "127.0.0.1"],
                            env=dict(os.environ, PASCLAW_HOME="h"), cwd=launch,
                            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
    base = "http://127.0.0.1:%d" % gport

    def get(path):
        try:
            r = urllib.request.urlopen(base + path, timeout=30)
            return r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")

    try:
        for _ in range(80):
            try:
                urllib.request.urlopen(base + "/v1/health", timeout=1).read()
                break
            except Exception:
                time.sleep(0.25)
        else:
            fail("gateway never answered /v1/health")
        req = urllib.request.Request(base + "/v1/chat/completions", method="POST",
                                     data=json.dumps({"messages": [{"role": "user", "content": "write it"}]}).encode())
        req.add_header("Content-Type", "application/json")
        urllib.request.urlopen(req, timeout=60).read()
        written = os.path.join(ws, "notes", "out.txt")
        if not os.path.exists(written):
            fail("premise: the tool did not write %s" % written)

        q = urllib.parse.quote
        for route in ("/v1/fs/read?path=", "/v1/fs/download?path=", "/v1/fs/peek?offset=0&len=4096&path="):
            st, text = get(route + q("notes/out.txt"))
            got = json.loads(text).get("content") if route.startswith("/v1/fs/read") and st == 200 else text
            if st != 200 or got != CONTENT:
                fail("%s with the tool's relative path answered %d %r, want 200 with the file the tool wrote"
                     % (route.split("?")[0], st, text[:200]))
        print("  ok: read, download and peek of `notes/out.txt` return the file the tool wrote, not the decoy")

        st, text = get("/v1/fs/download?path=" + q(written))
        if st != 200 or text != CONTENT:
            fail("the absolute path answered %d %r" % (st, text[:200]))
        print("  ok: the absolute path still works")

        st, text = get("/v1/fs")
        if st != 200:
            fail("the default listing answered %d %r" % (st, text[:200]))
        top = json.loads(text)
        for k in ("path", "workspace_root", "cwd_root"):
            if not os.path.isabs(top.get(k) or ""):
                fail("the listing's %s is %r, want an absolute path (a relative one now means the workspace)"
                     % (k, top.get(k)))
        if os.path.realpath(top["cwd_root"]) != ws:
            fail("cwd_root is %r, want the sandbox workspace %r" % (top["cwd_root"], ws))
        for root in (top["path"], top["cwd_root"]):
            st, text = get("/v1/fs?path=" + q(root))
            if st != 200:
                fail("listing the reported root %r answered %d %r" % (root, st, text[:200]))
        # What the native client's File Manager does: list the default
        # directory, then a subdirectory of the path it reported.
        st, text = get("/v1/fs?path=" + q(top["path"] + "/projects"))
        if st != 200:
            fail("listing the reported path + '/projects' answered %d %r" % (st, text[:200]))
        st, text = get("/v1/fs?path=" + q(top["cwd_root"] + "/notes"))
        names = [e["name"] for e in json.loads(text).get("entries", [])] if st == 200 else []
        if "out.txt" not in names:
            fail("listing cwd_root + '/notes' answered %d %r, want out.txt in it" % (st, text[:200]))
        st, text = get("/v1/fs/download?path=" + q(top["cwd_root"] + "/notes/out.txt"))
        if st != 200 or text != CONTENT:
            fail("downloading cwd_root + '/notes/out.txt' answered %d %r" % (st, text[:200]))
        print("  ok: the listing's path and roots are absolute; a path built from them lists and downloads")

        for bad in ("../notes/out.txt", "../../notes/out.txt", "../config.json", "../../../../etc/passwd",
                    os.path.join(home, "config.json"), os.path.join(launch, "notes", "out.txt")):
            for route in ("/v1/fs/read?path=", "/v1/fs/download?path=", "/v1/fs/peek?offset=0&len=64&path="):
                st, text = get(route + q(bad))
                if st != 403:
                    fail("%s%s answered %d, want 403: %r" % (route.split("?")[0], bad, st, text[:200]))
        print("  ok: `../` and paths outside the workspace are still refused, the config included")
    finally:
        if proc.poll() is None:
            proc.send_signal(signal.SIGINT)
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()
        log.close()
        httpd.shutdown()
        shutil.rmtree(launch, ignore_errors=True)
    print("fs relative path e2e: all checks passed")


if __name__ == "__main__":
    main()
