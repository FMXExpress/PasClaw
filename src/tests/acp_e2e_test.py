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
  - the system prompt is built for the editor's project (its AGENTS.md) and
    follows session/set_mode after the first turn
  - a provider that fails is a JSON-RPC error, and is not saved as a reply
  - the session records the project as where it works
  - a session created under a profile is not opened without it
  - an explicit --max-iterations is kept, even at the CLI default
  - with the docker backend, shell commands run in the session's container
    and the container is stopped when the agent exits (a fake docker CLI)
  - a background subagent a turn started keeps that session's container and
    the editor's project after the turn has answered
  - the session's container mounts the editor's project
  - the reply streams: the provider asks for SSE, the model's text reaches
    the editor while the model is still writing (the fake holds its stream
    until the editor has shown the first piece), tool-call arguments put
    together from fragments, a paragraph between rounds; a server that
    refuses the streaming fields gets a plain request instead
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
    "search editor tools": [
        ("tool", "code_catalog", {"server": "editor-mcp"}),
        ("text", "Found them."),
    ],
    "improve check": [
        ("text", "Measured nothing yet."),
    ],
    "provider fails": [
        ("fail", "fake key rejected by the provider"),
    ],
    "loop forever": [
        ("tool", "list_dir", {"path": "."}),
    ],
    "docker shell": [
        ("tool", "shell_exec", {"command": "echo from-docker > docker.txt"}),
        ("text", "Ran it."),
    ],
    "stream check": [
        ("text", "Streaming works: alpha beta gamma delta."),
    ],
    "stream two rounds": [
        ("tooltext", "list_dir", {"path": "."}, "Looking first."),
        ("text", "Done looking."),
    ],
    "stream refused": [
        ("text", "Answered without streaming."),
    ],
    "docker background": [
        ("tool", "spawn_background", {"agent": "general-purpose",
                                      "prompt": "bg child: write child.txt"}),
        ("text", "Started it."),
    ],
    # The background child: its first round waits until the turn that
    # spawned it has answered, so its shell command runs after that turn.
    # Two sessions' turns held until both are in flight, then each runs a
    # shell command: side by side, each must land in its own container.
    "docker pair A": [
        ("pair", "shell_exec", {"command": "echo A > pair-a.txt"}),
        ("text", "A done"),
    ],
    "docker pair B": [
        ("pair", "shell_exec", {"command": "echo B > pair-b.txt"}),
        ("text", "B done"),
    ],
    "bg child": [
        ("after_parent", "shell_exec", {"command": "echo child > child.txt"}),
        ("text", "child done"),
    ],
}
requests_seen = []
slow_arrived = threading.Event()   # set when the slow round's request is in
parent_done = threading.Event()    # set once the spawning turn has answered
pair_barrier = threading.Barrier(2, timeout=20)
first_piece_seen = threading.Event()   # the editor showed the held stream's first piece
stream_log = {"held_live": None, "stream_requests": 0, "plain_requests": 0}


def system_of(body):
    return "".join(text_of(m.get("content")) for m in body.get("messages", [])
                   if m.get("role") == "system")


def requests_for(prompt):
    return [b for b in requests_seen
            if any(prompt in text_of(m.get("content")) for m in b.get("messages", [])
                   if m.get("role") == "user")]


def text_of(content):
    if isinstance(content, list):
        return " ".join(p.get("text", "") for p in content if isinstance(p, dict))
    return content or ""


class Model(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"   # chunked transfer for the streamed replies

    def send_json(self, status, obj):
        out = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def chunk(self, data):
        self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
        self.wfile.flush()

    def sse(self, obj):
        self.chunk(("data: " + json.dumps(obj) + "\n\n").encode())

    def stream_reply(self, message, finish, hold_first=False):
        """Send message as an OpenAI chat.completion.chunk stream."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        base = {"id": "fake-%d" % len(requests_seen), "object": "chat.completion.chunk",
                "model": "fake-model"}
        def delta(d, fin=None):
            self.sse(dict(base, choices=[{"index": 0, "delta": d, "finish_reason": fin}]))
        delta({"role": "assistant"})
        text = message.get("content") or ""
        if text:
            n = max(1, len(text) // 3)
            pieces = [text[i:i + n] for i in range(0, len(text), n)]
            for k, piece in enumerate(pieces):
                delta({"content": piece})
                if k == 0 and hold_first:
                    # Hold the rest until the editor has shown this piece:
                    # it only can if PasClaw passes text on as it arrives.
                    stream_log["held_live"] = first_piece_seen.wait(10)
        for i, tc in enumerate(message.get("tool_calls") or []):
            delta({"tool_calls": [{"index": i, "id": tc["id"], "type": "function",
                                   "function": {"name": tc["function"]["name"], "arguments": ""}}]})
            args = tc["function"]["arguments"]
            half = len(args) // 2
            for frag in (args[:half], args[half:]):
                delta({"tool_calls": [{"index": i, "function": {"arguments": frag}}]})
        delta({}, finish)
        self.sse(dict(base, choices=[], usage={"prompt_tokens": 10, "completion_tokens": 5,
                                                "total_tokens": 15}))
        self.chunk(b"data: [DONE]\n\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

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
        streamed = bool(body.get("stream")) and \
            body.get("stream_options", {}).get("include_usage") is True
        if key == "stream refused" and "stream_options" in body:
            self.send_json(400, {"error": {"message": "Unrecognized request argument supplied: "
                                                      "stream_options", "type": "invalid_request_error"}})
            return
        if streamed:
            stream_log["stream_requests"] += 1
        else:
            stream_log["plain_requests"] += 1
        if step[0] == "fail":
            self.send_json(401, {"error": {"message": step[1], "type": "invalid_request_error"}})
            return
        if step[0] == "slow":
            slow_arrived.set()
            time.sleep(1.5)
        if step[0] == "after_parent":
            parent_done.wait(30)
        if step[0] == "pair":
            try:
                pair_barrier.wait()
            except threading.BrokenBarrierError:
                pass
        if step[0] in ("tool", "slow", "after_parent", "pair", "tooltext"):
            message = {"role": "assistant",
                       "content": step[3] if step[0] == "tooltext" else None,
                       "tool_calls": [{"id": "call_%s_%d" % (key.split()[0], done),
                                       "type": "function",
                                       "function": {"name": step[1],
                                                    "arguments": json.dumps(step[2])}}]}
            finish = "tool_calls"
        else:
            message = {"role": "assistant", "content": step[1]}
            finish = "stop"
        if streamed:
            self.stream_reply(message, finish, hold_first=(key == "stream check"))
            return
        self.send_json(200, {"id": "fake-%d" % len(requests_seen), "object": "chat.completion",
                             "model": "fake-model",
                             "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                             "usage": {"prompt_tokens": 10, "completion_tokens": 5,
                                       "total_tokens": 15}})

    def log_message(self, *a):
        pass


# -------------------------------------------------------------- the client --
class Client:
    """An ACP client: spawns the agent, writes requests, answers the agent's
    own requests, and collects every notification in between."""

    def __init__(self, env, label, args=()):
        self.stderr_path = os.path.join(WORK, "agent-%s.stderr" % label)
        self.p = subprocess.Popen([BIN, "acp"] + list(args), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
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
            if msg.get("method") == "session/update" and "Streaming wor" in json.dumps(msg):
                first_piece_seen.set()   # seen by the editor, as it arrives
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

    def call_all(self, calls, timeout=60):
        """Send several requests at once; return {index: response}."""
        ids = {}
        for i, (method, params) in enumerate(calls):
            self.next_id += 1
            ids[self.next_id] = i
            self.send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        out = {}
        deadline = time.time() + timeout
        while len(out) < len(ids):
            msg = self.q.get(timeout=max(0.1, deadline - time.time()))
            if msg is None:
                raise RuntimeError("agent exited")
            if "method" in msg and "id" in msg:
                self.send({"jsonrpc": "2.0", "id": msg["id"],
                           "error": {"code": -32601, "message": "not handled"}})
            elif "method" not in msg and msg.get("id") in ids:
                out[ids[msg["id"]]] = msg
        return out

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


def session_file(home, sid):
    path = os.path.join(home, "workspace", "sessions", sid + ".json")
    try:
        return json.load(open(path))
    except Exception:
        return {}


# A docker CLI that records what it is asked and runs `exec` on the host, in
# the -w directory: enough to see which container each command was sent to.
FAKE_DOCKER = r"""#!/bin/sh
echo "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  info) echo 99.0; exit 0;;
  run) echo fakecontainer; exit 0;;
  exec)
    shift
    dir=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -e) shift 2;;
        -w) dir="$2"; shift 2;;
        *) break;;
      esac
    done
    shift
    [ -n "$dir" ] && cd "$dir"
    exec "$@";;
esac
exit 0
"""


# -------------------------------------------------------------------- run --
def main():
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    home = os.path.join(WORK, "home")
    project = os.path.join(WORK, "project")
    os.makedirs(home)
    os.makedirs(project)
    with open(os.path.join(project, "AGENTS.md"), "w") as f:
        f.write("# Rules\n\nRULES-OF-THE-EDITOR-PROJECT-7Q\n")

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
    check("as working in the editor's project (where `pasclaw resume` goes)",
          session_file(home, sid).get("meta", {}).get("location") == project,
          session_file(home, sid).get("meta", {}).get("location"))
    first = requests_for("build hello")
    check("the system prompt carries the project's AGENTS.md",
          first and "RULES-OF-THE-EDITOR-PROJECT-7Q" in system_of(first[0]))

    print("-- streaming:")
    check("the provider asks the model to stream (stream + stream_options.include_usage)",
          stream_log["stream_requests"] > 0 and stream_log["plain_requests"] == 0, stream_log)
    r, notes = c.call("session/prompt", {"sessionId": sid,
                                         "prompt": [{"type": "text", "text": "stream check"}]})
    chunks = [u["content"]["text"] for u in updates(notes, "agent_message_chunk")]
    check("the editor got the model's first piece while the model was still writing",
          stream_log["held_live"] is True, stream_log)
    check("one round arrives as several chunks that add up to the reply",
          len(chunks) >= 3 and "".join(chunks) == "Streaming works: alpha beta gamma delta.", chunks)
    r, notes = c.call("session/prompt", {"sessionId": sid,
                                         "prompt": [{"type": "text", "text": "stream two rounds"}]})
    lst = [u for u in updates(notes, "tool_call") if u.get("name") == "list_dir"]
    done = [u for u in updates(notes, "tool_call_update")
            if lst and u.get("toolCallId") == lst[0].get("toolCallId")]
    check("a streamed tool call's arguments are put together from fragments",
          lst and lst[0].get("rawInput") == {"path": "."} and done and
          done[-1].get("status") == "completed", (lst, done))
    check("two streamed rounds read as two paragraphs",
          agent_text(notes).replace("\r\n", "\n") == "Looking first.\n\nDone looking.",
          agent_text(notes))
    before = dict(stream_log)
    r, notes = c.call("session/prompt", {"sessionId": sid,
                                         "prompt": [{"type": "text", "text": "stream refused"}]})
    check("a server that refuses the streaming fields is asked again without them",
          r.get("result", {}).get("stopReason") == "end_turn" and
          agent_text(notes) == "Answered without streaming." and
          stream_log["plain_requests"] == before["plain_requests"] + 1, (r, agent_text(notes), stream_log))

    print("-- the editor's MCP tools:")
    r, notes = c.call("session/prompt", {"sessionId": sid,
                                         "prompt": [{"type": "text", "text": "search editor tools"}]})
    found = json.dumps([u.get("content") for u in updates(notes, "tool_call_update")])
    check("code_catalog lists the editor-supplied server's tools (code mode, the default)",
          "editor-mcp__" in found, found[:400])

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
    planned = requests_for("plan mode write")
    check("and the model was told it is in plan mode (a switch after the first turn)",
          planned and "## Plan Mode" in system_of(planned[0]))
    c.call("session/set_mode", {"sessionId": sid, "modeId": "improve"})
    r, _ = c.call("session/prompt", {"sessionId": sid,
                                     "prompt": [{"type": "text", "text": "improve check"}]})
    improve = requests_for("improve check")
    check("improve mode reaches the system prompt, and plan mode's directive is gone",
          improve and "## Improve Mode" in system_of(improve[0]) and
          "## Plan Mode" not in system_of(improve[0]))
    c.call("session/set_mode", {"sessionId": sid, "modeId": "build"})

    print("-- a provider that fails:")
    r, notes = c.call("session/prompt", {"sessionId": sid,
                                         "prompt": [{"type": "text", "text": "provider fails"}]})
    check("the turn is a JSON-RPC error with the provider's message",
          "fake key rejected" in r.get("error", {}).get("message", ""), r)
    saved = json.dumps(session_file(home, sid).get("messages", []))
    check("the error is not saved as the assistant's reply", "fake key rejected" not in saved)
    check("nor is the prompt nothing answered", "provider fails" not in saved)

    print("-- cancel:")
    # Cancel once the model call is in flight -- not after a guessed delay.
    r, notes = c.call("session/prompt", {"sessionId": sid,
                                         "prompt": [{"type": "text", "text": "slow then cancel"}]},
                      after_send=lambda: (slow_arrived.wait(30),
                                          c.notify("session/cancel", {"sessionId": sid})))
    check("a cancelled turn answers cancelled", r.get("result", {}).get("stopReason") == "cancelled", r)
    slow = requests_for("slow then cancel")
    check("and never asked the model for the next round", len(slow) == 1, len(slow))
    check("build mode again: no mode directive left in the prompt",
          slow and "## Plan Mode" not in system_of(slow[0]) and
          "## Improve Mode" not in system_of(slow[0]))

    time.sleep(1.0)
    mcp_started = "editor-mcp" in open(c.stderr_path).read()
    c.close()
    check("stdout carried only JSON-RPC", not c.bad_lines, c.bad_lines[:3])
    check("the editor's MCP server was started", mcp_started)

    print("-- a profile, and an explicit --max-iterations:")
    c = Client(env, "c", ["--profile", "low-token", "--max-iterations", "8"])
    c.call("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
    r, _ = c.call("session/new", {"cwd": project, "mcpServers": []})
    sid2 = r.get("result", {}).get("sessionId", "")
    r, _ = c.call("session/prompt", {"sessionId": sid2,
                                     "prompt": [{"type": "text", "text": "loop forever"}]})
    check("--max-iterations 8 stops the turn at 8 rounds, not 50",
          r.get("result", {}).get("stopReason") == "max_turn_requests" and
          len(requests_for("loop forever")) <= 9,
          (r, len(requests_for("loop forever"))))
    c.close()
    check("the session records its profile",
          session_file(home, sid2).get("meta", {}).get("profile") == "low-token",
          session_file(home, sid2).get("meta", {}))

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
    r, _ = c.call("session/load", {"sessionId": sid2, "cwd": project, "mcpServers": []})
    check("a session made under a profile is not opened without it",
          "pasclaw acp --profile low-token" in r.get("error", {}).get("message", ""), r)
    c.close()
    check("stdout carried only JSON-RPC (second process)", not c.bad_lines, c.bad_lines[:3])
    c = Client(env, "d", ["--profile", "low-token"])
    c.call("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
    other = os.path.join(WORK, "other-project")
    os.makedirs(other)
    r, notes = c.call("session/load", {"sessionId": sid2, "cwd": other, "mcpServers": []})
    check("and is opened with it", "modes" in r.get("result", {}), r)
    c.call("session/prompt", {"sessionId": sid2, "prompt": [{"type": "text", "text": "improve check"}]})
    c.close()
    check("a session reopened in another project records that one",
          session_file(home, sid2).get("meta", {}).get("location") == other,
          session_file(home, sid2).get("meta", {}).get("location"))

    print("-- the docker backend (a fake docker CLI):")
    fakebin = os.path.join(WORK, "fakebin")
    os.makedirs(fakebin)
    with open(os.path.join(fakebin, "docker"), "w") as f:
        f.write(FAKE_DOCKER)
    os.chmod(os.path.join(fakebin, "docker"), 0o755)
    dlog = os.path.join(WORK, "docker.log")
    # A home without the shell ask rule: a background subagent has no one
    # to answer an ask, so the rule would refuse its command.
    dhome = os.path.join(WORK, "home-docker")
    os.makedirs(dhome)
    json.dump({"default_provider": "fake", "default_model": "fake-model",
               "providers": [{"name": "fake", "kind": "openai",
                              "api_base": "http://127.0.0.1:%d" % port,
                              "api_key": "sk-fake", "model": "fake-model"}],
               "auto_router": {"enabled": False}},
              open(os.path.join(dhome, "config.json"), "w"))
    denv = dict(env)
    denv["PASCLAW_HOME"] = dhome
    denv["PATH"] = fakebin + os.pathsep + env.get("PATH", "")
    denv["FAKE_DOCKER_LOG"] = dlog
    c = Client(denv, "e", ["--backend", "docker"])
    c.answers["session/request_permission"] = permission("allow_once")
    c.call("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
    r, _ = c.call("session/new", {"cwd": project, "mcpServers": []})
    sid3 = r.get("result", {}).get("sessionId", "")
    r, notes = c.call("session/prompt", {"sessionId": sid3,
                                         "prompt": [{"type": "text", "text": "docker shell"}]})
    log = open(dlog).read() if os.path.exists(dlog) else ""
    run = [l for l in log.splitlines() if l.startswith("run") and ("pasclaw-" + sid3) in l]
    check("the session's container mounts the editor's project (outside the workspace)",
          run and ("-v %s:%s" % (project, project)) in run[0], run[:1])
    check("the shell command ran in the session's container",
          os.path.exists(os.path.join(project, "docker.txt")) and
          ("exec" in log and "pasclaw-" + sid3 in log),
          (log[-500:], [u.get("content") for u in updates(notes, "tool_call_update")]))
    r, _ = c.call("session/load", {"sessionId": sid3, "cwd": project, "mcpServers": []})
    log = open(dlog).read() if os.path.exists(dlog) else ""
    check("a reloaded session keeps its container",
          "modes" in r.get("result", {}) and "stop" not in log, log[-300:])
    ra, _ = c.call("session/new", {"cwd": project, "mcpServers": []})
    rb, _ = c.call("session/new", {"cwd": project, "mcpServers": []})
    sa = ra.get("result", {}).get("sessionId", "")
    sb = rb.get("result", {}).get("sessionId", "")
    both = c.call_all([
        ("session/prompt", {"sessionId": sa, "prompt": [{"type": "text", "text": "docker pair A"}]}),
        ("session/prompt", {"sessionId": sb, "prompt": [{"type": "text", "text": "docker pair B"}]})])
    log = open(dlog).read() if os.path.exists(dlog) else ""
    ea = [l for l in log.splitlines() if l.startswith("exec") and "echo A" in l]
    eb = [l for l in log.splitlines() if l.startswith("exec") and "echo B" in l]
    check("two sessions' turns at once each run in their own container",
          not pair_barrier.broken and
          all(m.get("result", {}).get("stopReason") == "end_turn" for m in both.values()) and
          ea and eb and ("pasclaw-" + sa) in ea[0] and ("pasclaw-" + sb) in eb[0],
          (both, ea, eb))
    r, _ = c.call("session/new", {"cwd": project, "mcpServers": []})
    sid4 = r.get("result", {}).get("sessionId", "")
    r, notes = c.call("session/prompt", {"sessionId": sid4,
                                         "prompt": [{"type": "text", "text": "docker background"}]})
    check("a turn starts a background subagent and answers",
          r.get("result", {}).get("stopReason") == "end_turn" and
          any(u.get("name") == "spawn_background" for u in updates(notes, "tool_call")), r)
    parent_done.set()
    child = os.path.join(project, "child.txt")
    deadline = time.time() + 30
    while time.time() < deadline and not os.path.exists(child):
        time.sleep(0.2)
    log = open(dlog).read() if os.path.exists(dlog) else ""
    child_exec = [l for l in log.splitlines() if l.startswith("exec") and "echo child" in l]
    check("after the turn, the subagent's command ran in that session's container, in the project",
          os.path.exists(child) and child_exec and ("pasclaw-" + sid4) in child_exec[0],
          (child_exec, os.path.exists(os.path.join(dhome, "workspace", "child.txt")),
           open(c.stderr_path).read()[-600:]))
    c.close()
    log = open(dlog).read() if os.path.exists(dlog) else ""
    check("and the container is stopped when the agent exits",
          "stop --time 2 pasclaw-" + sid3 in log, log[-500:])

    srv.shutdown()
    if fails:
        print("FAILED: %d" % len(fails))
        sys.exit(1)
    print("PASS")


if __name__ == "__main__":
    main()
