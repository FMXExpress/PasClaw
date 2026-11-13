#!/usr/bin/env python3
"""/v1/context reports the context the chat turn really sends.

The breakdown is only worth drawing if it describes the request the model
gets, so this runs the real binary: a scratch gateway with the relay
provider (this script is the model and records every request it is sent),
a MEMORY.md, an AGENTS.md in its workspace, and a stub MCP server. For each request shape it asks /v1/context, then sends the same
body to /v1/chat/completions and checks the report against the request
the model received:

  - the tools it lists are exactly the tools the model was offered, with
    the MCP one under its server and counted as MCP;
  - compaction.counted_tokens is exactly what compaction measures for that
    request (chars/4 of the system prompt, plus each message body + 4);
  - the system prompt sections add up to the system prompt the model got,
    and memory / project rules / skills are where they should be;
  - a caller's own system message replaces PasClaw's prompt and is counted
    as system, not messages;
  - no_tools leaves the tools and the skill catalog out;
  - session_context counts the stored turns the server will add;
  - the categories add up to the total, and the window is the request's,
    the config's or the compaction threshold.

usage: context_usage_e2e.py <pasclaw-binary>
"""
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

MCP_STUB = r'''
import json, sys
TOOL = {"name": "echo_text", "description": "Echo the text back, unchanged.",
        "inputSchema": {"type": "object", "properties": {"text": {"type": "string",
        "description": "What to echo"}}, "required": ["text"]}}
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    if "id" not in msg:
        continue
    m = msg.get("method")
    if m == "initialize":
        res = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
               "serverInfo": {"name": "stub", "version": "1"}}
    elif m == "tools/list":
        res = {"tools": [TOOL]}
    elif m == "tools/call":
        res = {"content": [{"type": "text", "text": msg["params"]["arguments"].get("text", "")}]}
    else:
        res = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": res}) + "\n")
    sys.stdout.flush()
'''

MEMORY_MARK = "The operator keeps a pet tortoise called Brick."
RULES_MARK = "In this project, every function needs a docstring."


LOG = None


def fail(msg):
    print("FAIL: " + msg)
    if LOG and os.path.exists(LOG):
        with open(LOG, errors="replace") as f:
            print("---- gateway log (tail) ----\n" + "".join(f.readlines()[-30:]))
    sys.exit(1)


def est(s):
    """PasClaw.Tokenizer.EstimateTokens: (bytes + 3) div 4 on the FPC build."""
    n = len(s.encode("utf-8"))
    return 0 if n == 0 else (n + 3) // 4


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Gateway:
    def __init__(self, binary):
        self.home = tempfile.mkdtemp(prefix="pasclaw-context-e2e-")
        self.ws = os.path.join(self.home, "ws")
        os.makedirs(self.ws)
        os.makedirs(os.path.join(self.home, "workspace", "memory"))
        with open(os.path.join(self.home, "workspace", "memory", "MEMORY.md"), "w") as f:
            f.write("# Memory\n\n" + MEMORY_MARK + "\n")
        # Project rules are read from the sandbox workspace, not the
        # gateway's launch directory (BuildProjectRulesSection).
        with open(os.path.join(self.ws, "AGENTS.md"), "w") as f:
            f.write("# Rules\n\n" + RULES_MARK + "\n")
        stub = os.path.join(self.home, "mcp_stub.py")
        with open(stub, "w") as f:
            f.write(MCP_STUB)
        self.port = free_port()
        self.base = "http://127.0.0.1:%d" % self.port
        cfg = {
            "providers": [{"name": "relay", "kind": "relay", "api_base": "", "api_key": "",
                           "model": "claude-router"}],
            "default_provider": "relay", "default_model": "claude-router",
            "relay_wait_timeout_ms": 60000,
            "sandbox": {"workspace": self.ws},
            "gateway": {"port": self.port, "bind_addr": "127.0.0.1"},
            "mcp_progressive_disclosure": False,
            "mcp_servers": [{"name": "stub", "cmd": sys.executable,
                             "args": "-I " + stub, "codemode": False}],
            "context_window": 50000,
        }
        with open(os.path.join(self.home, "config.json"), "w") as f:
            json.dump(cfg, f)
        env = dict(os.environ, PASCLAW_HOME=self.home)
        global LOG
        LOG = os.path.join(self.home, "gateway.log")
        self.log = open(LOG, "w")
        self.proc = subprocess.Popen([binary, "gateway", "--port", str(self.port),
                                      "--addr", "127.0.0.1"],
                                     env=env, cwd=self.home, stdin=subprocess.DEVNULL,
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
        self.seen = []
        self.lock = threading.Lock()
        threading.Thread(target=self.model, daemon=True).start()
        time.sleep(0.5)

    def model(self):
        """The relay worker: records each request, answers "noted"."""
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
            with self.lock:
                self.seen.append(env)
            body = json.dumps({"content": "noted", "finish_reason": "stop"}).encode()
            r = urllib.request.Request(self.base + "/v1/relay/respond/" + env["id"],
                                       data=body, method="POST")
            r.add_header("Authorization", "Bearer " + self.relay_token)
            r.add_header("Content-Type", "application/json")
            urllib.request.urlopen(r).read()

    def post(self, path, body, session=None):
        r = urllib.request.Request(self.base + path, data=json.dumps(body).encode(),
                                   method="POST")
        r.add_header("Content-Type", "application/json")
        if session:
            r.add_header("X-PasClaw-Session", session)
        return json.loads(urllib.request.urlopen(r, timeout=60).read().decode("utf-8"))

    def get(self, path):
        return json.loads(urllib.request.urlopen(self.base + path, timeout=10).read())

    def turn(self, body, session=None):
        """Send a chat turn; return the first request the model got for it."""
        with self.lock:
            n = len(self.seen)
        self.post("/v1/chat/completions", body, session)
        with self.lock:
            if len(self.seen) <= n:
                fail("the model got no request for the turn")
            return self.seen[n]

    def stop(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.log.close()
        shutil.rmtree(self.home, ignore_errors=True)


def sent_system(env):
    return (env.get("options") or {}).get("system_prompt") or ""


CLOCK = re.compile(r"\n\n\[current date/time: [^\]]*\]")


def compaction_measure(env):
    """NeedsCompact's sum for the request the model got. The loop measures
    its history before it stamps the turn clock on the last user message
    (the stamp is never stored), so the stamp comes off first."""
    total = est(sent_system(env))
    for m in env["messages"]:
        total += est(CLOCK.sub("", m.get("content") or "")) + 4
    return total


def check_common(name, rep, env):
    cats = {c["id"]: c["tokens"] for c in rep["categories"]}
    if [c["id"] for c in rep["categories"]] != ["system", "memory", "project", "skills",
                                                 "tools", "mcp", "messages"]:
        fail("%s: categories out of order: %s" % (name, rep["categories"]))
    if sum(cats.values()) != rep["total_tokens"]:
        fail("%s: categories add to %d, total says %d" % (name, sum(cats.values()),
                                                          rep["total_tokens"]))
    if rep["total_tokens"] != (rep["system"]["tokens"] + rep["tools"]["tokens"]
                               + rep["messages"]["tokens"]):
        fail("%s: total is not system + tools + messages" % name)
    want = compaction_measure(env)
    if rep["compaction"]["counted_tokens"] != want:
        fail("%s: compaction counted %d, the request the model got measures %d"
             % (name, rep["compaction"]["counted_tokens"], want))
    got_tools = sorted(t["name"] for t in env.get("tools") or [])
    rep_tools = sorted(t["name"] for t in rep["tools"]["items"])
    if got_tools != rep_tools:
        fail("%s: report lists tools %s, model was offered %s" % (name, rep_tools, got_tools))
    nonsys = [m for m in env["messages"] if m["role"] != "system"]
    if rep["messages"]["count"] != len(nonsys):
        fail("%s: report counts %d messages, model got %d" % (name, rep["messages"]["count"],
                                                              len(nonsys)))
    # The messages as the model got them, turn clock and all (its stamp
    # is fixed-width, so a second's drift between the two calls does not
    # change the count).
    want = sum(est(m.get("content") or "") + 4 for m in nonsys)
    if nonsys and CLOCK.search(nonsys[-1]["content"]) is None:
        fail("%s: no turn clock on the model's last user message" % name)
    if rep["messages"]["tokens"] != want:
        fail("%s: report says messages cost %d tokens, the model's messages are %d"
             % (name, rep["messages"]["tokens"], want))


def main():
    if len(sys.argv) != 2 or not os.path.exists(sys.argv[1]):
        print("  skip: needs the pasclaw binary")
        return
    gw = Gateway(os.path.abspath(sys.argv[1]))
    try:
        for _ in range(80):
            names = [t["name"] for t in gw.get("/v1/tools")["tools"]]
            if "stub__echo_text" in names:
                break
            time.sleep(0.25)
        else:
            fail("the stub MCP server's tool never registered")

        # ---- PasClaw's own prompt, tools on, MCP tool present ----
        body = {"model": "claude-router", "mode": "build", "messages": [
            {"role": "user", "content": "hello"},
            {"role": "assistant", "content": "hi, what are we building?"},
            {"role": "user", "content": "a small parser, please"}]}
        rep = gw.post("/v1/context", body)
        env = gw.turn(body)
        check_common("pasclaw prompt", rep, env)
        sysp = sent_system(env)
        if MEMORY_MARK not in sysp or RULES_MARK not in sysp:
            fail("the model's system prompt lacks the memory / AGENTS.md marks")
        if rep["system"]["source"] != "pasclaw":
            fail("system source %r, want pasclaw" % rep["system"]["source"])
        secs = rep["system"]["sections"]
        ids = [s["id"] for s in secs]
        for want in ("identity", "memory", "project_rules", "skills", "rules"):
            if want not in ids:
                fail("section %s missing from %s" % (want, ids))
        groups = {s["id"]: s["group"] for s in secs}
        if groups["memory"] != "memory" or groups["project_rules"] != "project" \
                or groups["skills"] != "skills" or groups["identity"] != "system":
            fail("sections drawn in the wrong categories: %s" % groups)
        # Sections are charged with their separators, rounded up one by
        # one, so they add up to the prompt the model got within one token
        # a section.
        st = sum(s["tokens"] for s in secs)
        if abs(st - est(sysp)) > len(secs):
            fail("sections add to %d tokens, the model's system prompt is %d"
                 % (st, est(sysp)))
        if st != rep["system"]["tokens"]:
            fail("system.tokens %d is not the sum of its sections %d"
                 % (rep["system"]["tokens"], st))
        mcp = [t for t in rep["tools"]["items"] if t["name"] == "stub__echo_text"]
        if not mcp or mcp[0]["server"] != "stub":
            fail("the MCP tool is not filed under its server: %s" % mcp)
        cats = {c["id"]: c["tokens"] for c in rep["categories"]}
        if cats["mcp"] != mcp[0]["tokens"] or cats["mcp"] <= 0:
            fail("MCP category %d, the one MCP tool costs %d" % (cats["mcp"], mcp[0]["tokens"]))
        if any(t["server"] for t in rep["tools"]["items"] if t["name"] != "stub__echo_text"):
            fail("a built-in tool was filed under an MCP server")
        if cats["tools"] + cats["mcp"] != rep["tools"]["tokens"]:
            fail("tool categories do not add up to tools.tokens")
        if rep["window"] != {"tokens": 50000, "source": "config"}:
            fail("window %s, want the config's 50000" % rep["window"])
        if rep["free_tokens"] != 50000 - rep["total_tokens"]:
            fail("free_tokens %d, want %d" % (rep["free_tokens"], 50000 - rep["total_tokens"]))
        # The last user message is the largest as sent -- it carries the
        # turn clock -- but its preview is what the person wrote.
        big = rep["messages"]["largest"][0]
        if big["index"] != 2 or big["role"] != "user" or \
                big["preview"] != "a small parser, please":
            fail("largest message %s" % big)
        print("  ok: the report matches the request the model got (prompt, tools, MCP, "
              "compaction measure)")

        # ---- the caller's own system message, plan mode ----
        body = {"model": "claude-router", "mode": "plan", "messages": [
            {"role": "system", "content": "You are a terse code reviewer."},
            {"role": "user", "content": "look at main.c"}]}
        rep = gw.post("/v1/context", body)
        env = gw.turn(body)
        check_common("caller system", rep, env)
        if sent_system(env):
            fail("PasClaw's prompt went out alongside the caller's system message")
        if rep["system"]["source"] != "caller" or \
                [s["id"] for s in rep["system"]["sections"]] != ["caller"]:
            fail("caller system: %s" % rep["system"])
        sysmsg = [m for m in env["messages"] if m["role"] == "system"][0]["content"]
        if "## Plan Mode" not in sysmsg:
            fail("the plan-mode directive did not reach the caller's system message")
        if rep["system"]["tokens"] != est(sysmsg) + 4:
            fail("caller system tokens %d, the system message the model got is %d"
                 % (rep["system"]["tokens"], est(sysmsg) + 4))
        if rep["messages"]["by_role"]["user"]["count"] != 1:
            fail("the system message was counted as a message: %s" % rep["messages"])
        print("  ok: a caller's system message is counted as the system prompt, with "
              "the mode directive the model got")

        # ---- no_tools ----
        body = {"model": "claude-router", "no_tools": True,
                "messages": [{"role": "user", "content": "just answer"}]}
        rep = gw.post("/v1/context", body)
        env = gw.turn(body)
        check_common("no_tools", rep, env)
        if rep["tools"]["enabled"] or rep["tools"]["count"] or rep["tools"]["tokens"]:
            fail("no_tools still reports tools: %s" % rep["tools"])
        if "skills" in [s["id"] for s in rep["system"]["sections"]]:
            fail("no_tools still reports the skill catalog")
        print("  ok: no_tools reports no tools and no skill catalog")

        # ---- session_context: stored turns count ----
        sess = "context-e2e-session"
        first = {"model": "claude-router", "session_context": True,
                 "messages": [{"role": "user", "content": "remember: blue"}]}
        gw.turn(first, sess)
        nxt = {"model": "claude-router", "session_context": True,
               "messages": [{"role": "user", "content": "what colour?"}]}
        rep = gw.post("/v1/context", nxt, sess)
        if not rep.get("session_context"):
            fail("session_context not echoed")
        if rep["messages"]["from_session"] < 2:
            fail("stored turns not counted: %s" % rep["messages"])
        env = gw.turn(nxt, sess)
        check_common("session_context", rep, env)
        stateless = gw.post("/v1/context", dict(nxt, session_context=False), sess)
        if stateless["messages"]["count"] != 1 or stateless["messages"]["from_session"] != 0:
            fail("without session_context the stored turns were still counted")
        print("  ok: session_context counts the %d stored turns the server adds"
              % rep["messages"]["from_session"])

        # ---- window from the request; empty body ----
        rep = gw.post("/v1/context", {"context_window": 200000})
        if rep["window"] != {"tokens": 200000, "source": "request"}:
            fail("request window: %s" % rep["window"])
        if rep["messages"]["count"] != 0 or rep["system"]["tokens"] <= 0:
            fail("an empty chat should be all system prompt and tools: %s" % rep["messages"])
        print("  ok: the request's window wins; an empty chat is system prompt and tools")
    finally:
        gw.stop()
    print("context usage e2e: all checks passed")


if __name__ == "__main__":
    main()
