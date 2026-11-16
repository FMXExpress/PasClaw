#!/usr/bin/env python3
"""Workflows end to end: tools over /mcp, the gates, approval.

Against the real binary and a running gateway (no network, no model):

  - a workflow the operator saves (POST /v1/workflows) is served at once as
    the MCP tool wf_<id>, with its inputs as the schema; tools/call runs it;
  - an agent's workflow_save (here: an MCP client's) is staged, not saved:
    not a tool, listed by GET /v1/workflows/pending with its spec and sha256,
    and by `pasclaw workflow pending` / `show`;
  - approving with a stale sha256 is refused; with the right one the
    workflow is a tool on the next tools/list -- no gateway restart;
  - `pasclaw workflow approve` from another process, while the gateway
    runs, is picked up the same way; reject discards;
  - a deny rule stops a workflow step, through /mcp and through
    POST /v1/workflows/<id>/run, and the file's text never comes back;
  - write_file cannot write a workflow spec around the approval;
  - in a chat the agent's workflow_save ASKS: a web UI stream (the
    X-PasClaw-Asks: inline header) gets a `: pasclaw-ask` card with every
    step, answered through POST /v1/permissions/<id> -- allow saves it as a
    tool at once, deny drops it; a stream without the header and a plain
    API call are not asked and stage it, without waiting for a timeout;
  - an ordinary `ask` permission rule reaches the web UI chat the same way.

usage: workflows_e2e.py <pasclaw-binary>
"""
import http.client
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
import urllib.error
import urllib.request

LOG = None


def fail(msg):
    print("FAIL: " + msg)
    if LOG and os.path.exists(LOG):
        with open(LOG, errors="replace") as f:
            print("---- gateway log (tail) ----\n" + "".join(f.readlines()[-25:]))
    sys.exit(1)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def workflow_spec(name):
    return {"name": name, "description": "made in a chat",
            "inputs": [{"name": "path", "type": "string", "required": True}],
            "nodes": [{"id": "r", "tool": "read_file", "args": {"path": "{{inputs.path}}"}}]}


class Provider(http.server.BaseHTTPRequestHandler):
    """The model. "SAVE:<name>" -> workflow_save of a one-step workflow;
    "READ:<path>" -> read_file. After the tool result: "done: <result>"."""

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        last = (body.get("messages") or [{}])[-1]
        if last.get("role") == "tool":
            msg, fin = {"role": "assistant", "content": "done: " + str(last.get("content"))[:600]}, "stop"
        else:
            text = last.get("content") or ""
            if isinstance(text, list):
                text = "".join(p.get("text", "") for p in text if isinstance(p, dict))
            text = text.split("\n")[0].strip()   # the gateway appends a date/time line
            if text.startswith("SAVE:"):
                name, args = "workflow_save", workflow_spec(text[5:].strip())
            else:
                name, args = "read_file", {"path": text[5:].strip()}
            msg = {"role": "assistant", "content": None, "tool_calls": [{
                "id": "c1", "type": "function",
                "function": {"name": name, "arguments": json.dumps(args)}}]}
            fin = "tool_calls"
        if body.get("stream"):
            delta = dict(msg)
            if "tool_calls" in delta:
                delta["tool_calls"] = [dict(delta["tool_calls"][0], index=0)]
            frames = [{"choices": [{"index": 0, "delta": delta}]},
                      {"choices": [{"index": 0, "delta": {}, "finish_reason": fin}]},
                      {"choices": [], "usage": {"prompt_tokens": 1, "completion_tokens": 1}}]
            out = ("".join("data: %s\n\n" % json.dumps(f) for f in frames) + "data: [DONE]\n\n").encode()
            ctype = "text/event-stream"
        else:
            out = json.dumps({"id": "c", "object": "chat.completion", "model": "m",
                              "choices": [{"index": 0, "finish_reason": fin, "message": msg}],
                              "usage": {"prompt_tokens": 1, "completion_tokens": 1}}).encode()
            ctype = "application/json"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def main():
    global LOG
    if len(sys.argv) < 2 or not os.path.exists(sys.argv[1]):
        print("  skip: needs the pasclaw binary")
        return
    binary = os.path.abspath(sys.argv[1])
    home = tempfile.mkdtemp(prefix="pasclaw-workflows-e2e-")
    gport, pport = free_port(), free_port()
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", pport), Provider)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    ws = os.path.join(home, "workspace")
    os.makedirs(ws)
    hello = os.path.join(ws, "hello.txt")
    secret = os.path.join(ws, "secret.txt")
    with open(hello, "w") as f:
        f.write("hello from the workspace\n")
    with open(secret, "w") as f:
        f.write("TOP-SECRET-VALUE\n")
    with open(os.path.join(home, "config.json"), "w") as f:
        json.dump({"providers": [{"name": "fake", "kind": "openai", "api_base": "http://127.0.0.1:%d" % pport,
                                  "api_key": "sk-test", "model": "m"}],
                   "default_provider": "fake", "default_model": "m",
                   "gateway": {"port": gport, "bind_addr": "127.0.0.1"},
                   "workflows_enabled": True,
                   "permissions": [{"tool": "read_file", "effect": "deny", "resource": "*secret*"},
                                   {"tool": "read_file", "effect": "ask", "resource": "*ask-me*"}]}, f)
    with open(os.path.join(ws, "ask-me.txt"), "w") as f:
        f.write("ASKED-FOR-CONTENT\n")
    env = dict(os.environ, PASCLAW_HOME=home, NO_COLOR="1")
    base = "http://127.0.0.1:%d" % gport
    LOG = os.path.join(home, "gateway.log")
    log = open(LOG, "w")
    proc = None

    def api(method, path, body=None):
        data = None if body is None else (body if isinstance(body, str) else json.dumps(body)).encode()
        req = urllib.request.Request(base + path, method=method, data=data)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            r = urllib.request.urlopen(req, timeout=60)
            raw = r.read().decode("utf-8", "replace")
            return r.status, (json.loads(raw) if raw.strip() else {})
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", "replace")
            try:
                return e.code, json.loads(raw)
            except ValueError:
                return e.code, raw

    rpc_id = [0]

    def mcp(method, params=None):
        rpc_id[0] += 1
        body = {"jsonrpc": "2.0", "id": rpc_id[0], "method": method}
        if params is not None:
            body["params"] = params
        st, j = api("POST", "/mcp", body)
        if st != 200 or not isinstance(j, dict) or "result" not in j:
            fail("mcp %s: %d %r" % (method, st, j))
        return j["result"]

    def tools():
        return {t["name"]: t for t in mcp("tools/list")["tools"]}

    def call(name, args):
        r = mcp("tools/call", {"name": name, "arguments": args})
        text = "".join(c.get("text", "") for c in r.get("content", []))
        return bool(r.get("isError")), text

    def chat(prompt, stream=True, inline=True, answer=None):
        """One chat turn. With a stream, reads it line by line and answers
        each `: pasclaw-ask` card with `answer`. Returns (content, asks)."""
        body = {"model": "m", "stream": stream, "messages": [{"role": "user", "content": prompt}]}
        headers = {"Content-Type": "application/json", "X-PasClaw-Session": "e2e-chat"}
        if inline:
            headers["X-PasClaw-Asks"] = "inline"
        conn = http.client.HTTPConnection("127.0.0.1", gport, timeout=120)
        conn.request("POST", "/v1/chat/completions", json.dumps(body), headers)
        resp = conn.getresponse()
        if not stream:
            j = json.loads(resp.read())
            conn.close()
            return j["choices"][0]["message"]["content"] or "", []
        content, asks = "", []
        while True:
            line = resp.readline()
            if not line:
                break
            line = line.decode("utf-8", "replace").rstrip("\r\n")
            if line.startswith(": pasclaw-ask-resolved "):
                r = json.loads(line[len(": pasclaw-ask-resolved "):])
                for a in asks:
                    if a["id"] == r["id"]:
                        a["resolved"] = r["answer"]
            elif line.startswith(": pasclaw-ask "):
                a = json.loads(line[len(": pasclaw-ask "):])
                asks.append(a)
                st, j = api("POST", "/v1/permissions/" + a["id"], {"answer": answer})
                if st != 200:
                    fail("answering ask %s: %d %r" % (a["id"], st, j))
            elif line.startswith("data: "):
                d = line[6:]
                if d == "[DONE]":
                    break
                try:
                    j = json.loads(d)
                    content += (j.get("choices") or [{}])[0].get("delta", {}).get("content") or ""
                except ValueError:
                    pass
        conn.close()
        return content, asks

    def pending_ids():
        return {p["id"] for p in api("GET", "/v1/workflows/pending")[1].get("pending", [])}

    def cli(*args):
        r = subprocess.run([binary, "workflow"] + list(args), env=env, cwd=home,
                           capture_output=True, text=True, timeout=60)
        return r.returncode, r.stdout + r.stderr

    try:
        proc = subprocess.Popen([binary, "gateway", "--port", str(gport), "--addr", "127.0.0.1",
                                 "--mcp-allow-write"],
                                env=env, cwd=home, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        for _ in range(80):
            try:
                urllib.request.urlopen(base + "/v1/health", timeout=1).read()
                break
            except Exception:
                time.sleep(0.25)
        else:
            fail("gateway never answered /v1/health")
        pid = proc.pid

        # 1. The operator's save is a tool at once.
        if "wf_readit" in tools():
            fail("wf_readit listed before it was saved")
        spec = {"name": "readit", "description": "Read a workspace file.",
                "inputs": [{"name": "path", "type": "string", "required": True}],
                "nodes": [{"id": "r", "tool": "read_file", "args": {"path": "{{inputs.path}}"}}]}
        st, j = api("POST", "/v1/workflows", spec)
        if st != 200 or not j.get("saved"):
            fail("operator save: %d %r" % (st, j))
        t = tools().get("wf_readit")
        if not t:
            fail("wf_readit not served after the save")
        schema = t.get("inputSchema", {})
        if schema.get("properties", {}).get("path", {}).get("type") != "string" or schema.get("required") != ["path"]:
            fail("wf_readit schema should be the workflow's inputs: %r" % schema)
        err, text = call("wf_readit", {"path": hello})
        if err or "hello from the workspace" not in text:
            fail("tools/call wf_readit should run it: %r %r" % (err, text[:400]))
        print("  ok: a saved workflow is the MCP tool wf_readit (inputs as schema), callable, no restart")

        # 2. The gates hold through /mcp and through the run endpoint.
        err, text = call("wf_readit", {"path": secret})
        if not err or "TOP-SECRET" in text or "read_file" not in text:
            fail("a denied step should fail the tool and not leak: %r %r" % (err, text[:400]))
        st, j = api("POST", "/v1/workflows/readit/run", {"path": secret})
        if st != 200 or j.get("ok") or "TOP-SECRET" in json.dumps(j) or "read_file" not in json.dumps(j):
            fail("POST /run with a denied step should fail without leaking: %d %r" % (st, j))
        print("  ok: a deny rule stops the step via /mcp and via /v1/workflows/<id>/run; nothing leaks")

        # 3. An agent's save is staged.
        agent_spec = {"name": "shout", "description": "Read a file, staged by an agent.",
                      "inputs": [{"name": "path", "type": "string", "required": True}],
                      "nodes": [{"id": "r", "tool": "read_file", "args": {"path": "{{inputs.path}}"}}]}
        err, text = call("workflow_save", agent_spec)
        if err or "approv" not in text:
            fail("workflow_save should stage for approval: %r %r" % (err, text))
        if "wf_shout" in tools() or os.path.exists(os.path.join(ws, "workflows", "shout.json")):
            fail("a staged workflow must not be saved or served")
        st, j = api("GET", "/v1/workflows/pending")
        pend = {p["id"]: p for p in j.get("pending", [])} if st == 200 else {}
        p = pend.get("shout")
        if not p or len(p.get("sha256", "")) != 64 or p["spec"]["nodes"][0]["tool"] != "read_file" or p.get("replaces"):
            fail("GET /v1/workflows/pending should list it with spec and sha256: %d %r" % (st, j))
        rc, out = cli("pending")
        if rc != 0 or "shout" not in out:
            fail("`workflow pending`: %d %r" % (rc, out))
        rc, out = cli("show", "shout")
        if rc != 0 or "Waiting for approval" not in out or p["sha256"] not in out or "read_file" not in out:
            fail("`workflow show` should print the steps and the sha256: %d %r" % (rc, out))
        print("  ok: workflow_save staged it: not saved, not served; listed over HTTP and the CLI with its sha256")

        # 4. Approve: stale sha refused, right sha -> a tool, no restart.
        st, j = api("POST", "/v1/workflows/pending/approve", {"id": "shout", "sha256": "0" * 64})
        if st != 400 or "changed" not in json.dumps(j) or "wf_shout" in tools():
            fail("approve with a stale sha should be refused: %d %r" % (st, j))
        st, j = api("POST", "/v1/workflows/pending/approve", {"id": "shout", "sha256": p["sha256"]})
        if st != 200:
            fail("approve: %d %r" % (st, j))
        if "wf_shout" not in tools():
            fail("wf_shout not served after approval")
        err, text = call("wf_shout", {"path": hello})
        if err or "hello from the workspace" not in text:
            fail("wf_shout should run: %r %r" % (err, text[:300]))
        print("  ok: a stale sha256 is refused; approved, it is served and runs -- same gateway process")

        # 5. Approve from another process; reject.
        call("workflow_save", dict(agent_spec, name="cli_ok"))
        call("workflow_save", dict(agent_spec, name="nope"))
        rc, out = cli("approve", "cli_ok")
        if rc != 0 or "wf_cli_ok" not in out:
            fail("`workflow approve`: %d %r" % (rc, out))
        if "wf_cli_ok" not in tools():
            fail("a CLI approval should reach the running gateway's tools/list")
        st, j = api("POST", "/v1/workflows/pending/reject", {"id": "nope"})
        if st != 200 or "nope" in {x["id"] for x in api("GET", "/v1/workflows/pending")[1]["pending"]} \
                or "wf_nope" in tools():
            fail("reject: %d %r" % (st, j))
        print("  ok: `pasclaw workflow approve` reaches the running gateway; reject discards")

        # 6. No way around the approval through the file tools.
        evil = os.path.join(ws, "workflows", "evil.json")
        err, text = call("write_file", {"path": evil, "content": json.dumps(dict(spec, name="evil"))})
        if "workflow_save" not in text:
            fail("write_file should be refused, pointing at workflow_save: %r %r" % (err, text))
        if os.path.exists(evil) or "wf_evil" in tools():
            fail("the spec was written around the approval")
        print("  ok: write_file cannot write a workflow spec")

        # 7. In a chat the save asks: allow -> a tool now; deny -> nothing.
        content, asks = chat("SAVE:chatwf", answer="allow")
        if len(asks) != 1 or asks[0]["tool"] != "workflow_save" or asks[0]["resource"] != "chatwf":
            fail("a web UI chat should get one workflow_save ask: %r %r" % (asks, content[-600:]))
        a = asks[0]
        if "wf_chatwf" not in a["reason"] or "read_file" not in a["reason"] \
                or json.loads(a["args"])["nodes"][0]["tool"] != "read_file" or a.get("resolved") != "allow":
            fail("the ask should name the tool and show the steps, and resolve as allow: %r" % a)
        if "approved by the user" not in content or "wf_chatwf" not in tools() or "chatwf" in pending_ids():
            fail("allowed in the chat it should be saved and served, not staged: %r" % content[-300:])
        content, asks = chat("SAVE:nopewf", answer="deny")
        if len(asks) != 1 or "declined" not in content or "wf_nopewf" in tools() or "nopewf" in pending_ids():
            fail("denied in the chat it should be neither saved nor staged: %r %r" % (asks, content[-300:]))
        print("  ok: in a web UI chat workflow_save asks with every step; allow -> tool at once, deny -> nothing")

        # 8. Nobody to ask: staged, without waiting for the ask timeout.
        t0 = time.time()
        content, asks = chat("SAVE:sdkwf", inline=False)
        content2, _ = chat("SAVE:apiwf", stream=False)
        took = time.time() - t0
        if asks or "staged" not in content or "staged" not in content2 or took > 20:
            fail("a client that cannot show asks should stage at once: %r %r %r %.1fs"
                 % (asks, content[-200:], content2[-200:], took))
        if not {"sdkwf", "apiwf"} <= pending_ids() or "wf_sdkwf" in tools():
            fail("those saves should be pending, not tools: %r" % pending_ids())
        print("  ok: an SDK stream and a plain API call are not asked; the save is staged in %.1fs" % took)

        # 9. An ordinary ask rule reaches the web UI chat the same way.
        askme = os.path.join(ws, "ask-me.txt")
        content, asks = chat("READ:" + askme, answer="deny")
        if len(asks) != 1 or asks[0]["tool"] != "read_file" or "ASKED-FOR-CONTENT" in content \
                or "declined" not in content:
            fail("an ask rule should be a card in the chat; deny refuses: %r %r" % (asks, content[-300:]))
        content, asks = chat("READ:" + askme, answer="allow")
        if len(asks) != 1 or "ASKED-FOR-CONTENT" not in content:
            fail("allowed, the call should run: %r %r" % (asks, content[-300:]))
        print("  ok: an `ask` permission rule is a card in the web UI chat; deny refuses, allow runs")

        if proc.poll() is not None or proc.pid != pid:
            fail("the gateway restarted or died")
        print("workflows_e2e: OK")
    finally:
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
        log.close()
        httpd.shutdown()
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    main()
