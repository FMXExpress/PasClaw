#!/usr/bin/env python3
"""The MCP client's 2026-07-28 behaviour where people see it.

Against the real binary, a scripted fake MCP server (fake_mcp_server.py)
and a fake OpenAI-compatible provider:

  - `pasclaw mcp test` shows the negotiated revision: 2026-07-28 via
    server/discover for a modern server, the initialize answer for a legacy
    one;
  - the gateway's GET /v1/mcp (the web UI's MCP tab) reports each connected
    server's state and protocol_version;
  - interop: `pasclaw mcp test` against the gateway's own /mcp endpoint
    negotiates 2026-07-28;
  - the interactive `pasclaw agent` REPL answers a server's form
    elicitation at the keyboard, one prompt per field, typed per the schema
    (string, integer, enum default, boolean, multi-select), and declares the
    elicitation capability on its requests;
  - a one-shot `pasclaw agent -m` has nobody to ask: it declares no
    elicitation, does not retry, and the model is handed the URL to pass on.

usage: mcp_client_e2e.py <pasclaw-binary>
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

HERE = os.path.dirname(os.path.abspath(__file__))
FAKE = os.path.join(HERE, "fake_mcp_server.py")
URL = "https://auth.example.com/connect?flow=42"


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def text_of(content):
    if isinstance(content, list):
        content = " ".join(str(p.get("text", "")) for p in content if isinstance(p, dict))
    return content or ""


class Provider(http.server.BaseHTTPRequestHandler):
    """ASK_FORM / ASK_URL -> a call of that MCP tool; after the tool result,
    "done: <result>". The first tool call waits a little so the MCP server
    has connected before the call is dispatched."""
    bodies = []
    waited = False

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        Provider.bodies.append(body)
        msgs = body.get("messages") or []
        last = msgs[-1] if msgs else {}
        if last.get("role") == "tool":
            msg, fin = {"role": "assistant", "content": "done: " + text_of(last.get("content"))}, "stop"
        else:
            words = text_of(last.get("content")).split("\n")[0].strip()
            tool = {"ASK_FORM": "fakemcp__ask_form", "ASK_URL": "fakemcp__ask_url"}.get(words)
            if tool:
                if not Provider.waited:
                    Provider.waited = True
                    time.sleep(2.0)
                msg, fin = {"role": "assistant", "content": None, "tool_calls": [
                    {"id": "call_1", "type": "function", "function": {"name": tool, "arguments": "{}"}}]}, "tool_calls"
            else:
                msg, fin = {"role": "assistant", "content": "hello"}, "stop"
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


def tool_results():
    out = []
    for b in Provider.bodies:
        for m in b.get("messages") or []:
            if m.get("role") == "tool":
                out.append(text_of(m.get("content")))
    return out


def logged(path, method):
    msgs = []
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                m = json.loads(line)["msg"]
                if m.get("method") == method:
                    msgs.append(m)
    return msgs


def main():
    binary = os.path.abspath(sys.argv[1])
    home = tempfile.mkdtemp(prefix="pasclaw-mcp-client-e2e-")
    pport, gport = free_port(), free_port()
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", pport), Provider)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    stdio_log = os.path.join(home, "stdio.jsonl")
    http_log = os.path.join(home, "http.jsonl")
    port_file = os.path.join(home, "http.port")
    hsrv = subprocess.Popen([sys.executable, FAKE, "--era", "legacy", "--transport", "http",
                             "--log", http_log, "--port-file", port_file],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    gw = None
    try:
        for _ in range(100):
            if os.path.exists(port_file):
                break
            time.sleep(0.05)
        hport = int(open(port_file).read())
        cfg = {"providers": [{"name": "fake", "kind": "openai", "api_base": "http://127.0.0.1:%d/v1" % pport,
                              "api_key": "sk-test", "model": "m"}],
               "default_provider": "fake", "default_model": "m",
               "mcp_progressive_disclosure": False, "mcp_codemode_default": False,
               "gateway": {"port": gport, "bind_addr": "127.0.0.1"},
               "mcp_servers": [
                   {"name": "fakemcp", "cmd": sys.executable,
                    "args": '"%s" --era modern --log "%s"' % (FAKE, stdio_log), "enabled": True, "codemode": False},
                   {"name": "legacyhttp", "cmd": "http://127.0.0.1:%d/mcp" % hport, "args": "",
                    "enabled": True, "codemode": False},
                   {"name": "self", "cmd": "http://127.0.0.1:%d/mcp" % gport, "args": "",
                    "enabled": False, "codemode": False}]}
        with open(os.path.join(home, "config.json"), "w") as f:
            json.dump(cfg, f)
        env = dict(os.environ, PASCLAW_HOME=home, NO_COLOR="1")

        def run(args, stdin=None, timeout=60):
            r = subprocess.run([binary] + args, env=env, cwd=home, input=stdin,
                               capture_output=True, text=True, timeout=timeout)
            return r.returncode, r.stdout + r.stderr

        # 1. `mcp test` names the negotiated revision.
        code, out = run(["mcp", "test", "fakemcp"])
        if code != 0 or "protocol: 2026-07-28 (stateless, via server/discover)" not in out:
            fail("mcp test, modern stdio: exit %d\n%s" % (code, out))
        print("  ok: mcp test shows 2026-07-28 for a modern server")
        code, out = run(["mcp", "test", "legacyhttp"])
        if code != 0 or "protocol: 2025-11-25 (handshake, via initialize" not in out:
            fail("mcp test, legacy HTTP: exit %d\n%s" % (code, out))
        print("  ok: mcp test shows the initialize answer for a legacy server")

        # 2. The gateway's /v1/mcp reports what each server negotiated.
        glog = open(os.path.join(home, "gateway.log"), "w")
        gw = subprocess.Popen([binary, "gateway", "--port", str(gport), "--addr", "127.0.0.1"],
                              env=env, cwd=home, stdin=subprocess.DEVNULL, stdout=glog, stderr=subprocess.STDOUT)
        servers = {}
        for _ in range(120):
            try:
                j = json.loads(urllib.request.urlopen("http://127.0.0.1:%d/v1/mcp" % gport, timeout=2).read())
                servers = {s["name"]: s for s in j.get("servers", [])}
                if all(servers.get(n, {}).get("state") == "ready" for n in ("fakemcp", "legacyhttp")):
                    break
            except Exception:
                pass
            time.sleep(0.25)
        f, l = servers.get("fakemcp", {}), servers.get("legacyhttp", {})
        if f.get("protocol_version") != "2026-07-28" or f.get("negotiation") != "server/discover":
            fail("/v1/mcp fakemcp: %r" % f)
        if l.get("protocol_version") != "2025-11-25" or not l.get("negotiation", "").startswith("initialize"):
            fail("/v1/mcp legacyhttp: %r" % l)
        if "state" in servers.get("self", {}):
            fail("/v1/mcp: a disabled server has no live state: %r" % servers.get("self"))
        print("  ok: /v1/mcp reports state and protocol_version per server")

        # 3. Interop: our client against our own gateway's /mcp.
        code, out = run(["mcp", "test", "self"])
        if code != 0 or "protocol: 2026-07-28 (stateless, via server/discover)" not in out \
                or "memory_search" not in out:
            fail("mcp test against the gateway's /mcp: exit %d\n%s" % (code, out))
        print("  ok: interop with PasClaw's own /mcp over HTTP is 2026-07-28")
        gw.terminate()
        gw.wait(timeout=20)
        gw = None

        # 4. The REPL answers a form at the keyboard.
        Provider.bodies.clear()
        before = len(logged(stdio_log, "tools/call"))
        typed = "\n".join(["ASK_FORM", "Ada", "36", "", "y", "a,c", "y", "/exit"]) + "\n"
        code, out = run(["agent"], stdin=typed, timeout=90)
        want = 'ask_form:accept:{"age":36,"color":"green","name":"Ada","subscribe":true,"tags":["a","c"]}'
        if not any(want in t for t in tool_results()):
            fail("REPL form: the server did not get the typed answers; tool results %r\n%s"
                 % (tool_results(), out[-3000:]))
        if 'asks for input' not in out or 'fakemcp' not in out:
            fail("REPL form: no prompt naming the server\n%s" % out[-3000:])
        calls = logged(stdio_log, "tools/call")[before:]
        caps = calls[0]["params"]["_meta"]["io.modelcontextprotocol/clientCapabilities"]
        if caps.get("elicitation") != {"form": {}, "url": {}}:
            fail("REPL form: elicitation not declared: %r" % caps)
        print("  ok: the REPL asks each field and sends typed values")

        # 5. One-shot: no one to ask; the model gets the URL.
        Provider.bodies.clear()
        before = len(logged(stdio_log, "tools/call"))
        code, out = run(["agent", "-m", "ASK_URL"], stdin="", timeout=90)
        res = tool_results()
        if not res or URL not in res[0] or "declined" not in res[0]:
            fail("one-shot: the model was not handed the URL: %r\n%s" % (res, out[-2000:]))
        calls = logged(stdio_log, "tools/call")[before:]
        if len(calls) != 1:
            fail("one-shot: a declined request must not be retried (%d calls)" % len(calls))
        caps = calls[0]["params"]["_meta"]["io.modelcontextprotocol/clientCapabilities"]
        if "elicitation" in caps:
            fail("one-shot: declared elicitation with nobody to answer: %r" % caps)
        print("  ok: one-shot declines and hands the model the URL")
    finally:
        if gw is not None:
            gw.terminate()
            try:
                gw.wait(timeout=20)
            except Exception:
                gw.kill()
        hsrv.terminate()
        httpd.shutdown()
        shutil.rmtree(home, ignore_errors=True)
    print("mcp_client_e2e: OK")


if __name__ == "__main__":
    main()
