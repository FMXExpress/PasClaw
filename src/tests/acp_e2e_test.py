#!/usr/bin/env python3
"""End-to-end check of `pasclaw acp` through the real wire.

    acp_e2e_test.py <pasclaw binary> <scratch dir>

A fake OpenAI-compatible model (a scripted playbook keyed on the user's
prompt) stands in for the provider, so every run makes the same decisions;
a small ACP client drives `pasclaw acp` over stdin/stdout exactly as an
editor would. What it pins:

  - the handshake: initialize, session/new with modes, errors for a call
    before initialize, an unknown method, an unknown session
  - a turn: the plan from todo_write, a file write shown as a diff in the
    editor's project (not PasClaw's workspace), a permissions "ask" rule
    answered through session/request_permission, the reply, end_turn
  - a denied ask: the command does not run
  - plan mode via session/set_mode: the write is refused
  - session/cancel: the turn answers stopReason "cancelled"
  - session/load in a NEW process: the conversation is replayed
  - an MCP server the editor supplies is started
  - stdout carries nothing but JSON-RPC 2.0, one message per line
"""
import http.server
import json
import os
import queue
import shutil
import socket
import subprocess
import sys
import threading
import time

BIN = os.path.abspath(sys.argv[1])
WORK = os.path.abspath(sys.argv[2])
fails = []


def check(name, cond, detail=""):
    if cond:
        print("  ok: " + name)
    else:
        print("FAIL: %s %s" % (name, detail))
        fails.append(name)


# --------------------------------------------------------------- the model --
# One playbook per prompt. Each step is one model round: a tool call, or the
# closing text. The step is chosen by how many tool results the turn already
# has, so the same request always gets the same answer.
PLAYBOOKS = {
    "build hello": [
        ("tool", "todo_write", {"checklist": "- [ ] write hello.py\n- [ ] run it"}),
        ("tool", "write_file", {"path": "hello.py", "content": "print('hi')\n"}),
        ("tool", "shell_exec", {"command": "python3 hello.py"}),
        ("text", "Done: hello.py prints hi."),
    ],
    "try a denied command": [
        ("tool", "shell_exec", {"command": "touch denied.txt"}),
        ("text", "It was denied."),
    ],
    "plan mode write": [
        ("tool", "write_file", {"path": "planned.txt", "content": "x"}),
        ("text", "Plan mode stopped the write."),
    ],
    "slow then cancel": [
        ("slow", "list_dir", {"path": "."}),
        ("text", "this round should never be asked for"),
    ],
}
requests_seen = []


def text_of(content):
    if isinstance(content, list):
        return " ".join(p.get("text", "") for p in content if isinstance(p, dict))
    return content or ""


class Model(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        requests_seen.append(body)
        msgs = body.get("messages", [])
        last_user = max(i for i, m in enumerate(msgs) if m.get("role") == "user")
        done = sum(1 for m in msgs[last_user + 1:] if m.get("role") == "tool")
        prompt = text_of(msgs[last_user].get("content"))
        key = next((k for k in PLAYBOOKS if k in prompt), None)
        if key is None:
            step = ("text", "no playbook for this prompt")
        else:
            step = PLAYBOOKS[key][min(done, len(PLAYBOOKS[key]) - 1)]
        if step[0] == "slow":
            time.sleep(1.5)
        if step[0] in ("tool", "slow"):
            message = {"role": "assistant", "content": None,
                       "tool_calls": [{"id": "call_%s_%d" % (key.split()[0], done),
                                       "type": "function",
                                       "function": {"name": step[1],
                                                    "arguments": json.dumps(step[2])}}]}
            finish = "tool_calls"
        else:
            message = {"role": "assistant", "content": step[1]}
            finish = "stop"
        out = json.dumps({"id": "fake-%d" % len(requests_seen), "object": "chat.completion",
                          "model": "fake-model",
                          "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                          "usage": {"prompt_tokens": 10, "completion_tokens": 5,
                                    "total_tokens": 15}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


# -------------------------------------------------------------- the client --
class Client:
    """An ACP client: spawns the agent, writes requests, answers the agent's
    own requests, and collects every notification in between."""

    def __init__(self, env, label):
        self.stderr_path = os.path.join(WORK, "agent-%s.stderr" % label)
        self.p = subprocess.Popen([BIN, "acp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=open(self.stderr_path, "w"), env=env, cwd=WORK,
                                  text=True, encoding="utf-8", bufsize=1)
        self.q = queue.Queue()
        self.bad_lines = []
        self.next_id = 100
        self.answers = {}          # method -> function(params) -> result
        self.asked = []            # the agent's requests, as received
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            line = line.rstrip("\n")
            try:
                msg = json.loads(line)
                if msg.get("jsonrpc") != "2.0":
                    raise ValueError("no jsonrpc 2.0")
            except Exception:
                self.bad_lines.append(line)
                continue
            self.q.put(msg)
        self.q.put(None)

    def send(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def call(self, method, params, timeout=60, after_send=None):
        """Send a request; return (response, notifications before it)."""
        self.next_id += 1
        rid = self.next_id
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        if after_send:
            after_send()
        notes = []
        deadline = time.time() + timeout
        while True:
            msg = self.q.get(timeout=max(0.1, deadline - time.time()))
            if msg is None:
                raise RuntimeError("agent exited")
            if "method" in msg and "id" in msg:
                self.asked.append(msg)
                fn = self.answers.get(msg["method"])
                if fn is None:
                    self.send({"jsonrpc": "2.0", "id": msg["id"],
                               "error": {"code": -32601, "message": "not handled"}})
                else:
                    self.send({"jsonrpc": "2.0", "id": msg["id"], "result": fn(msg["params"])})
            elif "method" in msg:
                notes.append(msg)
            elif msg.get("id") == rid:
                return msg, notes

    def close(self):
        try:
            self.p.stdin.close()
        except Exception:
            pass
        try:
            self.p.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.p.kill()
            fails.append("agent did not exit when stdin closed")


def updates(notes, kind=None):
    out = [n["params"]["update"] for n in notes if n.get("method") == "session/update"]
    return [u for u in out if kind is None or u.get("sessionUpdate") == kind]


def agent_text(notes):
    return "".join(u["content"].get("text", "") for u in updates(notes, "agent_message_chunk"))


def permission(choice):
    return lambda params: {"outcome": {"outcome": "selected", "optionId": choice}}


# -------------------------------------------------------------------- run --
def main():
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    home = os.path.join(WORK, "home")
    project = os.path.join(WORK, "project")
    os.makedirs(home)
    os.makedirs(project)

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    json.dump({"default_provider": "fake", "default_model": "fake-model",
               "providers": [{"name": "fake", "kind": "openai",
                              "api_base": "http://127.0.0.1:%d" % port,
                              "api_key": "sk-fake", "model": "fake-model"}],
               "permissions": [{"tool": "shell_exec", "effect": "ask"}],
               "auto_router": {"enabled": False}},
              open(os.path.join(home, "config.json"), "w"))
    env = {k: v for k, v in os.environ.items()
           if k.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
    env["PASCLAW_HOME"] = home
    env["NO_COLOR"] = "1"

    print("-- handshake:")
    c = Client(env, "a")
    r, _ = c.call("session/new", {"cwd": project, "mcpServers": []})
    check("a request before initialize is refused", r.get("error", {}).get("code") == -32600, r)
    r, _ = c.call("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
    res = r.get("result", {})
    check("initialize answers protocol version 1", res.get("protocolVersion") == 1, r)
    check("and can load sessions", res.get("agentCapabilities", {}).get("loadSession") is True, r)
    r, _ = c.call("nope/nothing", {})
    check("an unknown method is -32601", r.get("error", {}).get("code") == -32601, r)
    r, _ = c.call("session/prompt", {"sessionId": "no-such", "prompt": [{"type": "text", "text": "x"}]})
    check("an unknown session is -32002", r.get("error", {}).get("code") == -32002, r)
    r, _ = c.call("session/new", {"cwd": "relative/dir", "mcpServers": []})
    check("a relative cwd is refused", r.get("error", {}).get("code") == -32602, r)
    r, _ = c.call("session/new", {"cwd": project, "mcpServers": [
        {"name": "editor-mcp", "command": BIN, "args": ["mcp", "stdio"], "env": []}]})
    sid = r.get("result", {}).get("sessionId", "")
    modes = r.get("result", {}).get("modes", {})
    check("session/new returns a session id", sid != "", r)
    check("with the four modes, build current",
          modes.get("currentModeId") == "build" and
          [m["id"] for m in modes.get("availableModes", [])] == ["build", "plan", "improve", "space"],
          modes)

    print("-- a turn:")
    c.answers["session/request_permission"] = permission("allow_once")
    r, notes = c.call("session/prompt", {"sessionId": sid, "prompt": [
        {"type": "text", "text": "build hello"},
        {"type": "resource_link", "uri": "file://%s/README" % project, "name": "README"}]})
    check("the turn ends with end_turn", r.get("result", {}).get("stopReason") == "end_turn", r)
    plans = updates(notes, "plan")
    check("todo_write becomes a plan",
          plans and [e["content"] for e in plans[0]["entries"]] == ["write hello.py", "run it"]
          and all(e["status"] == "pending" for e in plans[0]["entries"]), plans)
    calls = updates(notes, "tool_call")
    write = next((u for u in calls if u.get("name") == "write_file"), {})
    check("the write is an edit, located in the project",
          write.get("kind") == "edit" and
          write.get("locations") == [{"path": os.path.join(project, "hello.py")}], write)
    done = [u for u in updates(notes, "tool_call_update") if u.get("toolCallId") == write.get("toolCallId")]
    diff = [c_ for d in done for c_ in d.get("content", []) if c_.get("type") == "diff"]
    check("and its result carries a diff of a new file",
          diff and diff[0].get("oldText") is None and diff[0].get("newText") == "print('hi')\n", done)
    check("the file is in the editor's project",
          os.path.exists(os.path.join(project, "hello.py")) and
          not os.path.exists(os.path.join(home, "workspace", "hello.py")))
    asks = [a for a in c.asked if a["method"] == "session/request_permission"]
    shell = next((u for u in calls if u.get("name") == "shell_exec"), {})
    check("the ask rule asked the editor, about that call",
          len(asks) == 1 and asks[0]["params"]["toolCall"]["toolCallId"] == shell.get("toolCallId")
          and [o["kind"] for o in asks[0]["params"]["options"]] ==
          ["allow_once", "allow_always", "reject_once"], asks)
    ran = [u for u in updates(notes, "tool_call_update") if u.get("toolCallId") == shell.get("toolCallId")]
    check("allowed once, the command ran",
          ran and ran[-1].get("status") == "completed" and
          "hi" in json.dumps(ran[-1].get("content")), ran)
    check("the reply streams as message chunks", "Done: hello.py prints hi." in agent_text(notes),
          agent_text(notes))
    check("the session is saved",
          os.path.exists(os.path.join(home, "workspace", "sessions", sid + ".json")))

    print("-- a denied ask:")
    c.answers["session/request_permission"] = permission("reject_once")
    r, notes = c.call("session/prompt", {"sessionId": sid,
                                         "prompt": [{"type": "text", "text": "try a denied command"}]})
    check("the turn ends", r.get("result", {}).get("stopReason") == "end_turn", r)
    check("the denied command did not run", not os.path.exists(os.path.join(project, "denied.txt")))
    res = [u for u in updates(notes, "tool_call_update")]
    check("and the agent was told", any("declined" in json.dumps(u) for u in res), res)
    check("the editor shows it as failed, not done",
          any("declined" in json.dumps(u) and u.get("status") == "failed" for u in res), res)

    print("-- plan mode:")
    r, _ = c.call("session/set_mode", {"sessionId": sid, "modeId": "plan"})
    check("set_mode plan", r.get("result") == {}, r)
    r, _ = c.call("session/set_mode", {"sessionId": sid, "modeId": "r"})
    check("an alias is not a mode id", r.get("error", {}).get("code") == -32602, r)
    r, notes = c.call("session/prompt", {"sessionId": sid,
                                         "prompt": [{"type": "text", "text": "plan mode write"}]})
    check("plan mode refused the write",
          not os.path.exists(os.path.join(project, "planned.txt")) and
          any("needs build mode" in json.dumps(u) for u in updates(notes, "tool_call_update")),
          updates(notes, "tool_call_update"))
    c.call("session/set_mode", {"sessionId": sid, "modeId": "build"})

    print("-- cancel:")
    r, notes = c.call("session/prompt", {"sessionId": sid,
                                         "prompt": [{"type": "text", "text": "slow then cancel"}]},
                      after_send=lambda: (time.sleep(0.5),
                                          c.notify("session/cancel", {"sessionId": sid})))
    check("a cancelled turn answers cancelled", r.get("result", {}).get("stopReason") == "cancelled", r)
    slow = [b for b in requests_seen
            if any("slow then cancel" in text_of(m.get("content")) for m in b.get("messages", [])
                   if m.get("role") == "user")]
    check("and never asked the model for the next round", len(slow) == 1, len(slow))

    time.sleep(1.0)
    mcp_started = "editor-mcp" in open(c.stderr_path).read()
    c.close()
    check("stdout carried only JSON-RPC", not c.bad_lines, c.bad_lines[:3])
    check("the editor's MCP server was started", mcp_started)

    print("-- load in a new process:")
    c = Client(env, "b")
    c.call("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
    r, notes = c.call("session/load", {"sessionId": sid, "cwd": project, "mcpServers": []})
    check("session/load answers with the modes", "modes" in r.get("result", {}), r)
    users = "".join(u["content"]["text"] for u in updates(notes, "user_message_chunk"))
    check("the user's prompts are replayed", "build hello" in users and "[current date" not in users, users)
    check("so are the tool calls",
          any(u.get("name") == "write_file" and u.get("status") == "completed"
              for u in updates(notes, "tool_call")))
    check("and the replies", "Done: hello.py prints hi." in agent_text(notes))
    r, _ = c.call("session/load", {"sessionId": "../etc", "cwd": project, "mcpServers": []})
    check("a load of no such session is -32002", r.get("error", {}).get("code") == -32002, r)
    c.close()
    check("stdout carried only JSON-RPC (second process)", not c.bad_lines, c.bad_lines[:3])

    srv.shutdown()
    if fails:
        print("FAILED: %d" % len(fails))
        sys.exit(1)
    print("PASS")


if __name__ == "__main__":
    main()
