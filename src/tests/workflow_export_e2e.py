#!/usr/bin/env python3
"""Workflow export end to end: the exports run, and a workflow file travels.

Against the real binary, a fake OpenAI-compatible provider and the fake MCP
server (src/tests/fake_mcp_server.py, a stdio server in config.json). The
config carries a provider key, an MCP env value and a gateway token, so a
leak of any of them into an export shows.

Code export (a workflow with an llm step and an MCP step feeding an output;
its prompt has quotes, backslashes, a newline, an unclosed "{{" and a
{{inputs...}} template):

  - GET /v1/workflows/<id>/export?lang=python|pascal answers the same text
    as `pasclaw workflow export <id> --lang ...`, with a Content-Disposition
    of wf_<id>.py / wf_<id>.dpr; 404 for an unknown id, 400 for an unknown
    language; no secret from config.json is in either;
  - the reference: the same workflow run by PasClaw (the wf_<id> tool over
    /mcp, and `pasclaw workflow run --json`);
  - the Python export, run with python3 in a venv with the `mcp` package
    (pip install mcp; without it the run is skipped and the reason said),
    prints the same outputs, and the provider saw the same prompt;
  - the Pascal export compiles with FPC against this build's units and
    prints the same outputs.

Workflow file:

  - `--lang workflow` / ?lang=workflow: the envelope, no secrets, `requires`
    naming the MCP server (command + args, env NAMES only) and the provider;
    the spec inside is the saved spec;
  - imported on a second gateway with a fresh PASCLAW_HOME it is staged:
    not listed, not a tool, not runnable; approved, it runs with the same
    outputs, and reads back as the same spec;
  - an id clash is refused (409) unless ?as= or ?replace=1; a workflow
    whose MCP server is not configured is reported missing; a bad file is
    refused with its reason; `pasclaw workflow import` stages, --approve
    saves, and a URL import of a private address is refused by the SSRF
    guard.

usage: workflow_export_e2e.py <pasclaw-binary>
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
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SECRETS = ["sk-EXPORT-SECRET-KEY-42", "MCP-ENV-SECRET-VALUE-42", "GW-TOKEN-SECRET-42"]
TOKEN = SECRETS[2]
LOGS = []
PROMPTS = []
PROMPT = ('He said "stop" \\ then left.\nTopic: {{inputs.topic}} -- café, '
          'braces {{ stay, \'single\' quotes, a tab\there.')


def fail(msg):
    print("FAIL: " + msg)
    for p in LOGS:
        if os.path.exists(p):
            with open(p, errors="replace") as f:
                print("---- %s (tail) ----\n%s" % (p, "".join(f.readlines()[-20:])))
    sys.exit(1)


def ok(msg):
    print("  ok: " + msg)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Provider(http.server.BaseHTTPRequestHandler):
    """Answers with the prompt it got, so every run's output depends on it."""

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        last = (body.get("messages") or [{}])[-1].get("content") or ""
        PROMPTS.append(last)
        msg = {"role": "assistant", "content": "LLM<" + last + ">"}
        out = json.dumps({"id": "c", "object": "chat.completion", "model": body.get("model", "m"),
                          "choices": [{"index": 0, "finish_reason": "stop", "message": msg}],
                          "usage": {"prompt_tokens": 1, "completion_tokens": 1}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def make_home(prefix, pport, gport, with_mcp=True):
    home = tempfile.mkdtemp(prefix=prefix)
    os.makedirs(os.path.join(home, "workspace"))
    cfg = {"providers": [{"name": "fake", "kind": "openai", "api_base": "http://127.0.0.1:%d" % pport,
                          "api_key": SECRETS[0], "model": "m"}],
           "default_provider": "fake", "default_model": "m",
           "gateway": {"port": gport, "bind_addr": "127.0.0.1", "token": TOKEN},
           "workflows_enabled": True}
    if with_mcp:
        cfg["mcp_servers"] = [{"name": "fk", "cmd": sys.executable,
                               "args": os.path.join(HERE, "fake_mcp_server.py") + " --era legacy",
                               "env": "FAKE_TOKEN=" + SECRETS[1], "enabled": True}]
    with open(os.path.join(home, "config.json"), "w") as f:
        json.dump(cfg, f)
    return home


class Gateway:
    def __init__(self, binary, home, port):
        self.binary, self.home, self.port = binary, home, port
        self.env = dict(os.environ, PASCLAW_HOME=home, NO_COLOR="1")
        self.log = os.path.join(home, "gateway.log")
        LOGS.append(self.log)
        self.proc = subprocess.Popen([binary, "gateway", "--mcp-allow-write"], env=self.env, cwd=home,
                                     stdout=open(self.log, "w"), stderr=subprocess.STDOUT)
        t0 = time.time()
        while time.time() - t0 < 30:
            try:
                if self.api("GET", "/v1/workflows")[0] == 200:
                    return
            except OSError:
                pass
            time.sleep(0.2)
        fail("gateway on %d did not come up" % port)

    def raw(self, method, path, body=None, token=True):
        data = None if body is None else (body if isinstance(body, (bytes, str)) else json.dumps(body))
        if isinstance(data, str):
            data = data.encode()
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (self.port, path), method=method, data=data)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if token:
            req.add_header("Authorization", "Bearer " + TOKEN)
        try:
            r = urllib.request.urlopen(req, timeout=120)
            return r.status, r.read().decode("utf-8"), dict(r.headers)
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace"), dict(e.headers)

    def api(self, method, path, body=None):
        st, raw, _ = self.raw(method, path, body)
        try:
            return st, (json.loads(raw) if raw.strip() else {})
        except ValueError:
            return st, raw

    def mcp(self, method, params=None):
        st, j = self.api("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})
        if st != 200 or "result" not in j:
            fail("mcp %s: %d %r" % (method, st, j))
        return j["result"]

    def tools(self):
        return {t["name"] for t in self.mcp("tools/list")["tools"]}

    def run_tool(self, name, args):
        r = self.mcp("tools/call", {"name": name, "arguments": args})
        text = "".join(c.get("text", "") for c in r.get("content", []))
        if r.get("isError"):
            fail("%s failed: %s" % (name, text))
        return json.loads(text)

    def cli(self, *args, check=True):
        r = subprocess.run([self.binary, "workflow"] + list(args), env=self.env, cwd=self.home,
                           capture_output=True, text=True, timeout=120)
        if check and r.returncode != 0:
            fail("pasclaw workflow %s: rc=%d\n%s\n%s" % (" ".join(args), r.returncode, r.stdout, r.stderr))
        return r

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def no_secrets(what, text):
    for s in SECRETS:
        if s in text:
            fail("%s contains the secret %r" % (what, s))


def mcp_python():
    """A python3 that has the mcp package: a fresh venv with pip install mcp."""
    try:
        import mcp  # noqa: F401
        return sys.executable, "the running python3 has mcp"
    except ImportError:
        pass
    venv = os.path.join(tempfile.gettempdir(), "pasclaw-wf-export-venv")
    py = os.path.join(venv, "bin", "python")
    if not os.path.exists(py):
        r = subprocess.run([sys.executable, "-m", "venv", venv], capture_output=True, text=True)
        if r.returncode != 0:
            return None, "python3 -m venv failed: " + r.stderr.strip()[-200:]
    chk = subprocess.run([py, "-c", "import mcp"], capture_output=True)
    if chk.returncode == 0:
        return py, "venv with mcp (cached)"
    r = subprocess.run([py, "-m", "pip", "install", "-q", "mcp"], capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        return None, "pip install mcp failed: " + (r.stderr.strip() or r.stdout.strip())[-300:]
    return py, "venv with mcp (pip install mcp)"


def main():
    if len(sys.argv) < 2 or not os.path.exists(sys.argv[1]):
        print("  skip: needs the pasclaw binary")
        return
    binary = os.path.abspath(sys.argv[1])
    pport = free_port()
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", pport), Provider)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    ga_port, gb_port = free_port(), free_port()
    home_a = make_home("pasclaw-wfx-a-", pport, ga_port)
    home_b = make_home("pasclaw-wfx-b-", pport, gb_port)
    work = tempfile.mkdtemp(prefix="pasclaw-wfx-work-")
    ga = gb = None
    try:
        ga = Gateway(binary, home_a, ga_port)
        spec = {"id": "demo", "name": "demo", "description": 'Ask, then echo -- "quoted" \\ back',
                "inputs": [{"name": "topic", "type": "string", "required": True}],
                "outputs": [{"name": "result", "value": "{{nodes.echo}}", "type": "string"},
                            {"name": "topic_was", "value": "T={{inputs.topic}}", "type": "string"}],
                "nodes": [{"id": "ask", "tool": "llm", "args": {"prompt": PROMPT}},
                          {"id": "echo", "tool": "fk__echo", "args": {"text": "{{nodes.ask}}"}}],
                "edges": [{"from": "ask", "to": "echo"}]}
        st, j = ga.api("POST", "/v1/workflows", spec)
        if st != 200:
            fail("save: %d %r" % (st, j))
        saved = ga.api("GET", "/v1/workflows/demo")[1]
        topic = 'tea "green" \\ & {{x}}'

        # ---- the reference: PasClaw's own run
        t0 = time.time()
        while "wf_demo" not in ga.tools() and time.time() - t0 < 10:
            time.sleep(0.2)
        ref = None
        for _ in range(30):     # the MCP server may still be connecting
            r = ga.mcp("tools/call", {"name": "wf_demo", "arguments": {"topic": topic}})
            body = json.loads("".join(c.get("text", "") for c in r.get("content", [])))
            if body.get("ok"):
                ref = body["output"]
                break
            time.sleep(0.5)
        if ref is None:
            fail("the reference run failed: %r" % body)
        want_echo = "echo:LLM<" + PROMPT.replace("{{inputs.topic}}", topic) + ">"
        if ref != {"result": want_echo, "topic_was": "T=" + topic}:
            fail("reference outputs: %r" % ref)
        n_prompts = len(PROMPTS)
        ok("PasClaw runs the workflow: %d chars of output" % len(ref["result"]))
        r = ga.cli("run", "demo", "--input", "topic=" + topic, "--json", "--no-files")
        if json.loads(r.stdout) != ref:
            fail("pasclaw workflow run --json: %r" % r.stdout)
        ok("`pasclaw workflow run --json` prints the same outputs")

        # ---- the route and the CLI give the same text
        exports = {}
        for lang, fname in (("python", "wf_demo.py"), ("pascal", "wf_demo.dpr")):
            st, text, hdrs = ga.raw("GET", "/v1/workflows/demo/export?lang=" + lang)
            if st != 200:
                fail("export %s: %d %s" % (lang, st, text))
            cd = hdrs.get("Content-Disposition", "")
            if fname not in cd or not hdrs.get("Content-Type", "").startswith("text/plain"):
                fail("export %s headers: %r" % (lang, hdrs))
            r = ga.cli("export", "demo", "--lang", lang)
            if r.stdout != text:
                fail("export %s: the CLI and the route differ" % lang)
            out = os.path.join(work, "cli-" + fname)
            ga.cli("export", "demo", "--lang", lang, "-o", out)
            if open(out, encoding="utf-8").read() != text:
                fail("export %s -o: the file differs from stdout" % lang)
            no_secrets("the %s export" % lang, text)
            exports[lang] = text
        ok("route == CLI for python and pascal, with wf_demo.py / wf_demo.dpr, and no secrets")
        if ga.raw("GET", "/v1/workflows/nope/export?lang=python")[0] != 404:
            fail("unknown id is not 404")
        if ga.raw("GET", "/v1/workflows/demo/export?lang=cobol")[0] != 400:
            fail("unknown language is not 400")
        if ga.cli("export", "demo", "--lang", "cobol", check=False).returncode == 0:
            fail("the CLI took an unknown language")
        ok("404 for an unknown id, 400 for an unknown language")

        # ---- the Python export runs
        py_path = os.path.join(work, "wf_demo.py")
        with open(py_path, "w", encoding="utf-8") as f:
            f.write(exports["python"])
        py, why = mcp_python()
        print("  mcp package: " + why)
        if py is None:
            print("  skip: the Python export's MCP step (no mcp package: %s)" % why)
        else:
            env = dict(os.environ, LLM_API_KEY="dummy", PYTHONIOENCODING="utf-8")
            env.pop("PASCLAW_HOME", None)
            r = subprocess.run([py, py_path, "--input", "topic=" + topic, "--json", "--no-files"],
                               cwd=work, env=env, capture_output=True, text=True, timeout=120)
            if r.returncode != 0:
                fail("the Python export failed: rc=%d\n%s\n%s" % (r.returncode, r.stdout, r.stderr))
            if json.loads(r.stdout) != ref:
                fail("the Python export printed %r, PasClaw %r" % (r.stdout, ref))
            if PROMPTS[-1] != PROMPTS[n_prompts - 1]:
                fail("the Python export sent another prompt: %r vs %r" % (PROMPTS[-1], PROMPTS[n_prompts - 1]))
            ok("the Python export prints the same outputs (and sent the same prompt)")
            r = subprocess.run([py, py_path, "--help"], capture_output=True, text=True)
            if "topic: string (required)" not in r.stdout:
                fail("python --help does not list the inputs: %r" % r.stdout)
            r = subprocess.run([py, py_path, "--input", "topic=x"], cwd=work, env=env,
                               capture_output=True, text=True, timeout=120)
            if r.returncode != 0 or not os.path.exists(os.path.join(work, "workflows", "demo")):
                fail("the Python export did not write its outputs: %s" % r.stderr)
            ok("--help lists the inputs; a run writes its outputs under workflows/demo/")

        # ---- the Pascal export compiles and runs
        fpc = shutil.which("fpc")
        if not fpc:
            print("  skip: the Pascal export (no fpc)")
        else:
            dpr = os.path.join(work, "wf_demo.dpr")
            with open(dpr, "w", encoding="utf-8") as f:
                f.write(exports["pascal"])
            lib = os.path.join(os.path.dirname(binary), "lib")
            units = os.path.join(work, "units")
            os.makedirs(units)
            r = subprocess.run([fpc, "-MDelphi", "-Sh", "-Fu" + lib, "-FE" + work, "-FU" + units, dpr],
                               cwd=ROOT, capture_output=True, text=True, timeout=300)
            exe = os.path.join(work, "wf_demo")
            if r.returncode != 0 or not os.path.exists(exe):
                fail("the Pascal export does not compile:\n" + r.stdout[-3000:])
            ok("the Pascal export compiles with fpc -MDelphi -Sh -Fu<build>/lib")
            env = dict(os.environ, PASCLAW_HOME=home_a, NO_COLOR="1")
            r = subprocess.run([exe, "--input", "topic=" + topic, "--json", "--no-files"], cwd=work, env=env,
                               capture_output=True, text=True, timeout=120)
            if r.returncode != 0:
                fail("the Pascal export failed: rc=%d\n%s\n%s" % (r.returncode, r.stdout, r.stderr))
            if json.loads(r.stdout) != ref:
                fail("the Pascal export printed %r, PasClaw %r" % (r.stdout, ref))
            if PROMPTS[-1] != PROMPTS[n_prompts - 1]:
                fail("the Pascal export sent another prompt")
            r = subprocess.run([exe, "--help"], env=env, capture_output=True, text=True, timeout=60)
            if "topic: string (required)" not in r.stdout:
                fail("pascal --help does not list the inputs: %r" % r.stdout)
            ok("the Pascal export prints the same outputs; --help lists the inputs")

        # ---- the workflow file
        st, ftext, hdrs = ga.raw("GET", "/v1/workflows/demo/export?lang=workflow")
        if st != 200 or "demo.pasclaw-workflow.json" not in hdrs.get("Content-Disposition", ""):
            fail("export workflow: %d %r" % (st, hdrs))
        no_secrets("the workflow file", ftext)
        cli_text = ga.cli("export", "demo", "--lang", "workflow").stdout
        no_secrets("the CLI workflow file", cli_text)
        env_ = json.loads(ftext)
        if json.loads(cli_text)["workflow"] != env_["workflow"]:
            fail("the CLI's workflow file holds another spec")
        if env_["format"] != "pasclaw-workflow" or env_["version"] != 1 or not env_.get("exported_at") \
                or not env_.get("pasclaw_version"):
            fail("envelope: %r" % {k: env_.get(k) for k in ("format", "version", "exported_at", "pasclaw_version")})
        if env_["workflow"] != saved:
            fail("the file's spec is not the saved spec:\n%r\n%r" % (env_["workflow"], saved))
        req = env_["requires"]
        srv = req["mcp_servers"]
        if len(srv) != 1 or srv[0]["name"] != "fk" or srv[0]["command"] != sys.executable \
                or srv[0]["args"] != [os.path.join(HERE, "fake_mcp_server.py"), "--era", "legacy"] \
                or srv[0].get("env") != ["FAKE_TOKEN"]:
            fail("requires.mcp_servers: %r" % srv)
        if req["providers"] != [{"name": "fake", "kind": "openai", "models": ["m"]}]:
            fail("requires.providers: %r" % req["providers"])
        if req["tools"] != [] or req["replicate_models"] != []:
            fail("requires.tools / replicate_models: %r" % req)
        ok("the workflow file: envelope, the saved spec, requires right, no secrets")
        fpath = os.path.join(work, "demo.pasclaw-workflow.json")
        with open(fpath, "w", encoding="utf-8") as f:
            f.write(ftext)

        # ---- import on a second gateway, fresh home
        gb = Gateway(binary, home_b, gb_port)
        st, j = gb.api("POST", "/v1/workflows/import", ftext)
        if st != 200 or not j.get("staged") or j.get("id") != "demo" or j.get("missing"):
            fail("import: %d %r" % (st, j))
        if any(w["id"] == "demo" for w in gb.api("GET", "/v1/workflows")[1]["workflows"]):
            fail("an imported workflow is listed as saved before approval")
        if "wf_demo" in gb.tools():
            fail("an imported workflow is a tool before approval")
        if gb.api("POST", "/v1/workflows/demo/run", {"topic": "x"})[0] != 404:
            fail("an imported workflow runs before approval")
        pend = {p["id"]: p for p in gb.api("GET", "/v1/workflows/pending")[1]["pending"]}
        if "demo" not in pend or pend["demo"]["sha256"] != j["sha256"]:
            fail("the import is not in the approvals list: %r" % pend)
        ok("imported on a fresh gateway: staged, not listed, not a tool, not runnable")
        st, j2 = gb.api("POST", "/v1/workflows/pending/approve", {"id": "demo", "sha256": j["sha256"]})
        if st != 200:
            fail("approve: %d %r" % (st, j2))
        if gb.api("GET", "/v1/workflows/demo")[1] != saved:
            fail("the imported spec differs from the exported one")
        t0 = time.time()
        while "wf_demo" not in gb.tools() and time.time() - t0 < 10:
            time.sleep(0.2)
        out_b = None
        for _ in range(30):
            r = gb.mcp("tools/call", {"name": "wf_demo", "arguments": {"topic": topic}})
            body = json.loads("".join(c.get("text", "") for c in r.get("content", [])))
            if body.get("ok"):
                out_b = body["output"]
                break
            time.sleep(0.5)
        if out_b != ref:
            fail("the imported workflow gives %r, the original %r" % (out_b, ref))
        ok("approved: the same spec, a tool, and the same outputs")

        # ---- clashes
        st, j = gb.api("POST", "/v1/workflows/import", ftext)
        if st != 409 or not j.get("clash") or "already" not in j.get("error", ""):
            fail("a clash is not refused: %d %r" % (st, j))
        st, j = gb.api("POST", "/v1/workflows/import?as=demo2", ftext)
        if st != 200 or j.get("id") != "demo2" or j.get("replaces"):
            fail("import ?as=demo2: %d %r" % (st, j))
        st, j = gb.api("POST", "/v1/workflows/import?replace=1", ftext)
        if st != 200 or j.get("id") != "demo" or not j.get("replaces"):
            fail("import ?replace=1: %d %r" % (st, j))
        if gb.api("GET", "/v1/workflows/demo")[0] != 200:
            fail("a staged replacement removed the saved workflow")
        gb.api("POST", "/v1/workflows/pending/reject", {"id": "demo"})
        ok("an id clash is refused (409) unless ?as= or ?replace=1; the saved one keeps running")

        # ---- a missing MCP server, bad files
        other = json.loads(ftext)
        other["workflow"]["nodes"][1]["tool"] = "elsewhere__echo"
        other["requires"]["mcp_servers"] = [{"name": "elsewhere", "url": "https://mcp.example.com/mcp"}]
        st, j = gb.api("POST", "/v1/workflows/import?as=other", json.dumps(other))
        miss = " ".join(j.get("missing", [])) if isinstance(j, dict) else ""
        if st != 200 or 'MCP server "elsewhere"' not in miss or "mcp.example.com" not in miss:
            fail("a missing MCP server is not reported: %d %r" % (st, j))
        pend = {p["id"]: p for p in gb.api("GET", "/v1/workflows/pending")[1]["pending"]}
        if not any("elsewhere" in m for m in pend.get("other", {}).get("missing", [])):
            fail("the approvals list does not show what is missing: %r" % pend.get("other"))
        ok("a missing MCP server is reported, by the import and in the approvals list")
        for body, why in (("not json", "not a JSON object"),
                          (json.dumps({"format": "zip"}), '"format" is "zip"'),
                          (json.dumps(dict(env_, version=99)), "version 99"),
                          (json.dumps(dict(env_, workflow={"name": "x"})), "at least one node")):
            st, j = gb.api("POST", "/v1/workflows/import", body)
            if st != 400 or why not in j.get("error", ""):
                fail("bad file %r: %d %r" % (why, st, j))
        ok("bad files are refused with their reason")

        # ---- the CLI
        r = gb.cli("import", fpath, check=False)
        if r.returncode == 0 or "already saved" not in r.stdout:
            fail("CLI import clash: %r" % r.stdout)
        gb.cli("import", fpath, "--as", "demo3")
        if not os.path.exists(os.path.join(home_b, "workspace", "workflows", ".pending", "demo3.json")):
            fail("CLI import did not stage")
        gb.cli("import", fpath, "--as", "demo4", "--approve")
        if not os.path.exists(os.path.join(home_b, "workspace", "workflows", "demo4.json")):
            fail("CLI import --approve did not save")
        r = gb.cli("import", "http://127.0.0.1:%d/v1/workflows" % gb_port, check=False)
        if r.returncode == 0 or "SSRF" not in r.stdout:
            fail("a URL import of a private address is not refused: %r" % r.stdout)
        r = gb.cli("import", "file:///etc/passwd", check=False)
        if r.returncode == 0 or "http" not in r.stdout:
            fail("a non-http URL import is not refused: %r" % r.stdout)
        ok("CLI: a clash refused, --as stages, --approve saves, private and non-http URLs refused")
    finally:
        for g in (ga, gb):
            if g:
                g.stop()
        httpd.shutdown()
    for d in (home_a, home_b, work):
        shutil.rmtree(d, ignore_errors=True)
    print("workflow export e2e: OK")


if __name__ == "__main__":
    main()
