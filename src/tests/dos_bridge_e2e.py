#!/usr/bin/env python3
"""The DOS client and `pasclaw bridge`, end to end, on this machine.

A scripted model behind a real gateway; `pasclaw bridge --listen` in front
of it; the client (PCLAW, built for this host by `make dos-host`, so its
link is TCP instead of COM1) runs the agent loop and the tools locally:

  - with no bridge the client says so and exits 2;
  - a plain request comes back as text; the model saw the client's system
    prompt and exactly the client's five tools (passthrough -- none of the
    gateway's own);
  - the model's tool calls run on the client: read_file, list_dir,
    write_file, run, and two calls in one step; each output goes back
    under its call_id;
  - without /YES the client asks; "n" refuses and the file is not written;
  - the bridge forwards only POST /v1/responses, GET /v1/health and
    GET /v1/models (403 otherwise), forces "stream": false, echoes the
    sequence number, answers a body with a bad CRC with 400 "crc", and
    finds the next request after line noise on the same connection;
  - over a serial line: `pasclaw bridge --serial` on one pseudo-terminal,
    the client on another, this test the null-modem cable between them.

usage: dos_bridge_e2e.py <pasclaw-binary> <pclaw-host-binary>
"""
import http.server
import json
import os
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import zlib

LOG = None
REQUESTS = []   # every chat-completions body the model saw


def fail(msg):
    print("FAIL: " + msg)
    for name in ("gateway.log", "bridge.log"):
        p = os.path.join(os.path.dirname(LOG or ""), name)
        if LOG and os.path.exists(p):
            with open(p, errors="replace") as f:
                print("---- %s (tail) ----\n" % name + "".join(f.readlines()[-25:]))
    sys.exit(1)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def text_of(m):
    c = m.get("content") or ""
    if isinstance(c, list):
        c = "".join(p.get("text", "") for p in c if isinstance(p, dict))
    return c


def call(cid, name, args):
    return {"id": cid, "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}


class Provider(http.server.BaseHTTPRequestHandler):
    """The model, scripted on the user's words:
       LIST <dir> / READ <path> / WRITE <path> / RUN <cmd> / TWO <path> <dir>
       -> that tool call; after the tool results, "done:" + each result.
       Anything else -> a text answer."""

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        REQUESTS.append(body)
        msgs = body.get("messages") or []
        last = msgs[-1] if msgs else {}
        if last.get("role") == "tool":
            outs = []
            for m in reversed(msgs):
                if m.get("role") != "tool":
                    break
                outs.insert(0, "[%s] %s" % (m.get("tool_call_id"), text_of(m)))
            msg, fin = {"role": "assistant", "content": "done: " + " | ".join(outs)}, "stop"
        else:
            words = text_of(last).split("\n")[0].strip()
            verb, _, rest = words.partition(" ")
            calls = []
            if verb == "LIST":
                calls = [call("c1", "list_dir", {"path": rest})]
            elif verb == "READ":
                calls = [call("c1", "read_file", {"path": rest})]
            elif verb == "WRITE":
                calls = [call("c1", "write_file", {"path": rest, "content": "made by the model\nline 2 — café\n"})]
            elif verb == "RUN":
                calls = [call("c1", "run", {"command": rest})]
            elif verb == "TWO":
                p, d = rest.split(" ", 1)
                calls = [call("ca", "read_file", {"path": p}), call("cb", "list_dir", {"path": d})]
            if calls:
                msg, fin = {"role": "assistant", "content": None, "tool_calls": calls}, "tool_calls"
            else:
                msg, fin = {"role": "assistant", "content": "Hello from the model — naïve café."}, "stop"
        out = json.dumps({"id": "c", "object": "chat.completion", "model": "m",
                          "choices": [{"index": 0, "finish_reason": fin, "message": msg}],
                          "usage": {"prompt_tokens": 1, "completion_tokens": 1}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def wire_request(method, path, body=b"", seq=None, crc=None):
    head = "%s %s HTTP/1.1\r\nHost: bridge\r\n" % (method, path)
    if seq is not None:
        head += "X-PasClaw-Seq: %s\r\n" % seq
    if body:
        head += "Content-Type: application/json\r\n"
    c = "%08x" % (zlib.crc32(body) & 0xffffffff) if crc is None else crc
    head += "Content-Length: %d\r\nX-PasClaw-CRC32: %s\r\n\r\n" % (len(body), c)
    return head.encode() + body


def read_response(sock):
    f = sock.makefile("rb")
    status = f.readline().decode()
    if not status.startswith("HTTP/"):
        fail("bridge: not a response: %r" % status)
    headers = {}
    while True:
        line = f.readline().decode().strip()
        if not line:
            break
        k, _, v = line.partition(":")
        headers[k.strip().lower()] = v.strip()
    body = f.read(int(headers.get("content-length", "0")))
    if "x-pasclaw-crc32" in headers and headers["x-pasclaw-crc32"] != "%08x" % (zlib.crc32(body) & 0xffffffff):
        fail("bridge: the answer's CRC header does not match its body")
    return int(status.split()[1]), headers, body


def main():
    global LOG
    if len(sys.argv) < 3 or not os.path.exists(sys.argv[1]) or not os.path.exists(sys.argv[2]):
        print("  skip: needs the pasclaw binary and the host-built DOS client")
        return
    binary, pclaw = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    home = tempfile.mkdtemp(prefix="pasclaw-dos-e2e-")
    gport, pport, bport = free_port(), free_port(), free_port()
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", pport), Provider)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    with open(os.path.join(home, "config.json"), "w") as f:
        json.dump({"providers": [{"name": "fake", "kind": "openai", "api_base": "http://127.0.0.1:%d" % pport,
                                  "api_key": "sk-test", "model": "m"}],
                   "default_provider": "fake", "default_model": "m",
                   "gateway": {"port": gport, "bind_addr": "127.0.0.1"}}, f)
    pc = os.path.join(home, "pc")          # the "DOS PC"'s current directory
    os.makedirs(os.path.join(pc, "sub"))
    with open(os.path.join(pc, "notes.txt"), "w") as f:
        f.write("first line\nsecond line\n")
    env = dict(os.environ, PASCLAW_HOME=home, NO_COLOR="1")
    LOG = os.path.join(home, "gateway.log")
    glog, blog = open(LOG, "w"), open(os.path.join(home, "bridge.log"), "w")
    gw = br = None

    def client(*args, stdin=None, port=None):
        r = subprocess.run([pclaw, "/PORT:" + (port or "127.0.0.1:%d" % bport)] + list(args), cwd=pc,
                           input=stdin, capture_output=True, text=True, timeout=120)
        return r.returncode, r.stdout + r.stderr

    try:
        # 0. No bridge yet.
        code, out = client("/P:hello")
        if code != 2 or "pasclaw bridge" not in out:
            fail("with no bridge: exit %d, %r" % (code, out))

        gw = subprocess.Popen([binary, "gateway", "--port", str(gport), "--addr", "127.0.0.1"],
                              env=env, cwd=home, stdin=subprocess.DEVNULL, stdout=glog, stderr=subprocess.STDOUT)
        for _ in range(80):
            try:
                urllib.request.urlopen("http://127.0.0.1:%d/v1/health" % gport, timeout=1).read()
                break
            except Exception:
                time.sleep(0.25)
        else:
            fail("gateway never answered /v1/health")
        br = subprocess.Popen([binary, "bridge", "--listen", "127.0.0.1:%d" % bport],
                              env=env, cwd=home, stdin=subprocess.DEVNULL, stdout=blog, stderr=subprocess.STDOUT)
        for _ in range(80):
            try:
                socket.create_connection(("127.0.0.1", bport), timeout=1).close()
                break
            except OSError:
                time.sleep(0.25)
        else:
            fail("bridge never listened")

        # 1. Text.
        REQUESTS.clear()
        code, out = client("/P:hello there")
        if code != 0 or "Hello from the model — naïve café." not in out:
            fail("text answer: exit %d, %r" % (code, out))
        req = REQUESTS[-1]
        names = sorted(t["function"]["name"] for t in req.get("tools", []))
        if names != ["edit_file", "list_dir", "read_file", "run", "write_file"]:
            fail("the model saw tools %r, want exactly the client's five" % names)
        sysmsg = [m for m in req["messages"] if m.get("role") == "system"]
        if not sysmsg or "PasClaw" not in text_of(sysmsg[0]) or pc not in text_of(sysmsg[0]):
            fail("the client's system prompt (with its directory) did not reach the model: %r" % sysmsg)

        # 2. read_file runs on the client.
        code, out = client("/YES", "/P:READ notes.txt")
        if code != 0 or "done: [c1] first line" not in out or "> read_file notes.txt" not in out:
            fail("read_file: exit %d, %r" % (code, out))

        # 3. list_dir.
        code, out = client("/YES", "/P:LIST .")
        if code != 0 or "notes.txt" not in out or "<DIR>" not in out:
            fail("list_dir: exit %d, %r" % (code, out))

        # 4. write_file with /YES writes; the text arrives intact.
        code, out = client("/YES", "/P:WRITE made.txt")
        target = os.path.join(pc, "made.txt")
        if code != 0 or not os.path.exists(target):
            fail("write_file /YES: exit %d, %r" % (code, out))
        with open(target, encoding="utf-8") as f:
            if f.read() != "made by the model\nline 2 — café\n":
                fail("write_file wrote the wrong text")

        # 5. Without /YES the client asks; "n" refuses.
        code, out = client("/P:WRITE refused.txt", stdin="n\n")
        if os.path.exists(os.path.join(pc, "refused.txt")):
            fail("the client wrote a file the user refused")
        if "[y/N/a=all]" not in out or "the user said no" not in out:
            fail("no question, or the refusal did not reach the model: %r" % out)

        # 6. run captures output.
        code, out = client("/YES", "/P:RUN echo ran-on-the-client")
        if code != 0 or "done: [c1] ran-on-the-client" not in out:
            fail("run: exit %d, %r" % (code, out))

        # 7. Two calls in one step: both outputs, each under its own id.
        code, out = client("/YES", "/P:TWO notes.txt sub")
        if code != 0 or "[ca] first line" not in out or "[cb] (nothing matches" not in out:
            fail("two calls: exit %d, %r" % (code, out))
        tools_back = [m for m in REQUESTS[-1]["messages"] if m.get("role") == "tool"]
        if sorted(m.get("tool_call_id") for m in tools_back) != ["ca", "cb"]:
            fail("tool outputs came back under %r" % [m.get("tool_call_id") for m in tools_back])

        # 8. The bridge itself, on the wire.
        s = socket.create_connection(("127.0.0.1", bport), timeout=30)
        s.sendall(wire_request("GET", "/v1/config", seq=5))
        st, h, body = read_response(s)
        if st != 403 or h.get("x-pasclaw-seq") != "5":
            fail("GET /v1/config through the bridge: %d %r" % (st, body))
        s.sendall(wire_request("POST", "/v1/responses", b'{"input":"x"}', seq=6, crc="00000000"))
        st, h, body = read_response(s)
        if st != 400 or json.loads(body)["error"]["message"] != "crc" or h.get("x-pasclaw-seq") != "6":
            fail("a bad CRC: %d %r" % (st, body))
        # Noise, then a streaming request: found, and answered as one JSON body.
        s.sendall(b"\x00\xff garbage\r\nmore garbage\r\n" + wire_request(
            "POST", "/v1/responses", json.dumps({"input": "hi", "stream": True}).encode(), seq=7))
        st, h, body = read_response(s)
        if st != 200 or h.get("x-pasclaw-seq") != "7" or "output" not in json.loads(body):
            fail("after noise, a stream:true request: %d %r" % (st, body[:200]))
        s.sendall(wire_request("GET", "/v1/health", seq=8))
        st, h, body = read_response(s)
        if st != 200 or json.loads(body).get("status") != "ok":
            fail("health through the bridge: %d %r" % (st, body))
        s.close()

        # 9. A serial line. Two pseudo-terminals; the bytes one end writes
        #    are copied to the other -- a null-modem cable in software.
        m1, s1 = os.openpty()
        m2, s2 = os.openpty()
        cable_up = threading.Event()

        def cable():
            while cable_up.is_set():
                r, _, _ = select.select([m1, m2], [], [], 0.2)
                for fd in r:
                    try:
                        data = os.read(fd, 4096)
                    except OSError:
                        continue
                    os.write(m2 if fd == m1 else m1, data)

        cable_up.set()
        threading.Thread(target=cable, daemon=True).start()
        slog = open(os.path.join(home, "bridge-serial.log"), "w")
        sbr = subprocess.Popen([binary, "bridge", "--serial", os.ttyname(s1), "--baud", "38400"],
                               env=env, cwd=home, stdin=subprocess.DEVNULL, stdout=slog, stderr=subprocess.STDOUT)
        try:
            for _ in range(40):
                with open(os.path.join(home, "bridge-serial.log"), errors="replace") as f:
                    if "38400 8N1" in f.read():
                        break
                time.sleep(0.25)
            else:
                fail("bridge --serial never opened " + os.ttyname(s1))
            code, out = client("/YES", "/BAUD:38400", "/TIMEOUT:20", "/P:READ notes.txt", port=os.ttyname(s2))
            if code != 0 or "done: [c1] first line" not in out:
                fail("over the serial line: exit %d, %r" % (code, out))
        finally:
            cable_up.clear()
            sbr.terminate()
            try:
                sbr.wait(timeout=10)
            except subprocess.TimeoutExpired:
                sbr.kill()
            slog.close()
            for fd in (m1, s1, m2, s2):
                os.close(fd)

        print("dos_bridge_e2e: OK")
    finally:
        for p in (br, gw):
            if p and p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill()
        glog.close()
        blog.close()
        httpd.shutdown()
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    main()
