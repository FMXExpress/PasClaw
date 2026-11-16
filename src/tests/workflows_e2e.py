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
  - write_file cannot write a workflow spec around the approval.

usage: workflows_e2e.py <pasclaw-binary>
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
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


def main():
    global LOG
    if len(sys.argv) < 2 or not os.path.exists(sys.argv[1]):
        print("  skip: needs the pasclaw binary")
        return
    binary = os.path.abspath(sys.argv[1])
    home = tempfile.mkdtemp(prefix="pasclaw-workflows-e2e-")
    gport = free_port()
    ws = os.path.join(home, "workspace")
    os.makedirs(ws)
    hello = os.path.join(ws, "hello.txt")
    secret = os.path.join(ws, "secret.txt")
    with open(hello, "w") as f:
        f.write("hello from the workspace\n")
    with open(secret, "w") as f:
        f.write("TOP-SECRET-VALUE\n")
    with open(os.path.join(home, "config.json"), "w") as f:
        json.dump({"providers": [{"name": "fake", "kind": "openai", "api_base": "http://127.0.0.1:9",
                                  "api_key": "sk-test", "model": "m"}],
                   "default_provider": "fake", "default_model": "m",
                   "gateway": {"port": gport, "bind_addr": "127.0.0.1"},
                   "workflows_enabled": True,
                   "permissions": [{"tool": "read_file", "effect": "deny", "resource": "*secret*"}]}, f)
    env = dict(os.environ, PASCLAW_HOME=home, NO_COLOR="1")
    base = "http://127.0.0.1:%d" % gport
    LOG = os.path.join(home, "gateway.log")
    log = open(LOG, "w")
    proc = None

    def http(method, path, body=None):
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
        st, j = http("POST", "/mcp", body)
        if st != 200 or not isinstance(j, dict) or "result" not in j:
            fail("mcp %s: %d %r" % (method, st, j))
        return j["result"]

    def tools():
        return {t["name"]: t for t in mcp("tools/list")["tools"]}

    def call(name, args):
        r = mcp("tools/call", {"name": name, "arguments": args})
        text = "".join(c.get("text", "") for c in r.get("content", []))
        return bool(r.get("isError")), text

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
        st, j = http("POST", "/v1/workflows", spec)
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
        st, j = http("POST", "/v1/workflows/readit/run", {"path": secret})
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
        st, j = http("GET", "/v1/workflows/pending")
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
        st, j = http("POST", "/v1/workflows/pending/approve", {"id": "shout", "sha256": "0" * 64})
        if st != 400 or "changed" not in json.dumps(j) or "wf_shout" in tools():
            fail("approve with a stale sha should be refused: %d %r" % (st, j))
        st, j = http("POST", "/v1/workflows/pending/approve", {"id": "shout", "sha256": p["sha256"]})
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
        st, j = http("POST", "/v1/workflows/pending/reject", {"id": "nope"})
        if st != 200 or "nope" in {x["id"] for x in http("GET", "/v1/workflows/pending")[1]["pending"]} \
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
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    main()
