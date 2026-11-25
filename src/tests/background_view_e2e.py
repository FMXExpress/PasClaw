#!/usr/bin/env python3
"""The gateway's view of background work (/v1/background), end to end.

A scripted model behind a real gateway with a bearer token. The chat model
starts the jobs itself, as it would in use: a /v1/chat turn asks it to, and
it calls spawn_background or shell_background. The subagent's model calls
come to the same fake provider (told apart by the sub-agent system prompt)
and can be held until the test lets them go, so a job is seen running.

  - without the token every route answers 401;
  - a subagent job is listed running (kind, agent, prompt, session, start
    time, no finish time), then done with a finish time and a result
    preview; its detail holds the transcript: the task, the model's tool
    call with the chat's own one-line form, the tool result, the answer;
  - running jobs come first, then the newest;
  - a follow-up message to a running job is 409, to a shell job 400, with
    no text 400, to an unknown handle 404; to a finished subagent it is 202
    and a new job that continues the conversation (the model is sent the
    old transcript), runs in the same chat, and is linked both ways;
  - cancelling a finished job is 409; a running subagent's cancel says it
    is advisory, the job stops at its next step (the model is not asked
    again) and stays cancelled; a running shell job's cancel kills it;
  - a shell job's detail carries its output and exit code.

usage: background_view_e2e.py <pasclaw-binary>
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

TOKEN = "bg-e2e-token"
SESSION = "chat-bg-e2e"
SUB_MARK = "focused sub-agent"   # PasClaw.Agent.Subagent's general-purpose prompt
LOG = None

HOLDS = {}            # "HOLD-1" -> threading.Event released by the test
SUB_CALLS = {}        # task tag -> number of model calls the subagent made
SUB_REQUESTS = []     # every subagent request body
LOCK = threading.Lock()


def fail(msg):
    print("FAIL: " + msg)
    if LOG and os.path.exists(LOG):
        with open(LOG, errors="replace") as f:
            print("---- gateway.log (tail) ----\n" + "".join(f.readlines()[-30:]))
    sys.exit(1)


def check(cond, msg):
    if not cond:
        fail(msg)


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


def tag_of(text):
    return text.split(" ", 1)[0].split(":", 1)[0]


class Provider(http.server.BaseHTTPRequestHandler):
    """The chat model: "BG <task>" -> spawn_background(general-purpose, task),
    "SH <cmd>" -> shell_background(cmd); after the tool result, "ok".

    The subagent: a task whose first word is HOLD-n waits for the test to
    release it; any task then calls list_dir once and answers
    "answer for <tag>". A follow-up ("FOLLOW ...") answers with what it was
    sent of the earlier conversation."""

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        msgs = body.get("messages") or []
        system = " ".join(text_of(m) for m in msgs if m.get("role") == "system")
        last = msgs[-1] if msgs else {}
        if SUB_MARK in system:
            msg, fin = self.subagent(body, msgs, last)
        elif last.get("role") == "tool":
            msg, fin = {"role": "assistant", "content": "ok"}, "stop"
        else:
            words = text_of(last).split("\n")[0].strip()
            verb, _, rest = words.partition(" ")
            if verb == "BG":
                msg = {"role": "assistant", "content": None,
                       "tool_calls": [call("p1", "spawn_background", {"agent": "general-purpose", "prompt": rest})]}
                fin = "tool_calls"
            elif verb == "SH":
                msg = {"role": "assistant", "content": None,
                       "tool_calls": [call("p1", "shell_background", {"command": rest})]}
                fin = "tool_calls"
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

    def subagent(self, body, msgs, last):
        users = [text_of(m) for m in msgs if m.get("role") == "user"]
        task = users[0] if users else ""
        latest = users[-1] if users else ""
        with LOCK:
            SUB_REQUESTS.append(body)
        if latest.startswith("FOLLOW"):
            earlier = [text_of(m) for m in msgs[:-1] if m.get("role") in ("user", "assistant")]
            return {"role": "assistant",
                    "content": "follow-up answer; earlier: " + " | ".join(e for e in earlier if e)}, "stop"
        tag = tag_of(task)
        with LOCK:
            SUB_CALLS[tag] = SUB_CALLS.get(tag, 0) + 1
        if last.get("role") == "tool":
            return {"role": "assistant", "content": "answer for " + tag}, "stop"
        ev = HOLDS.get(tag)
        if ev is not None:
            ev.wait(60)
        return {"role": "assistant", "content": "looking around first",
                "tool_calls": [call("s1", "list_dir", {"path": "."})]}, "tool_calls"

    def log_message(self, *a):
        pass


class Gateway:
    def __init__(self, port):
        self.base = "http://127.0.0.1:%d" % port

    def req(self, method, path, body=None, token=TOKEN, raw=None):
        data = None
        headers = {"X-PasClaw-Session": SESSION}
        if token:
            headers["Authorization"] = "Bearer " + token
        if raw is not None:
            data = raw.encode()
            headers["Content-Type"] = "application/json"
        elif body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        r = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(r, timeout=60) as resp:
                return resp.status, json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            txt = e.read().decode("utf-8")
            try:
                return e.code, json.loads(txt)
            except ValueError:
                return e.code, {"raw": txt}

    def jobs(self):
        st, j = self.req("GET", "/v1/background")
        check(st == 200, "GET /v1/background: %d %r" % (st, j))
        return j

    def job(self, handle):
        st, j = self.req("GET", "/v1/background/" + handle)
        check(st == 200, "GET /v1/background/%s: %d %r" % (handle, st, j))
        return j

    def wait_job(self, handle, pred, what, secs=20):
        t0 = time.time()
        while time.time() - t0 < secs:
            j = self.job(handle)
            if pred(j):
                return j
            time.sleep(0.1)
        fail("timed out waiting for %s: %r" % (what, self.job(handle)))

    def chat(self, message):
        st, j = self.req("POST", "/v1/chat", {"message": message})
        check(st == 200, "POST /v1/chat %r: %d %r" % (message, st, j))
        return j


def new_handle(gw, before, kind):
    t0 = time.time()
    while time.time() - t0 < 10:
        for j in gw.jobs()["jobs"]:
            if j["handle"] not in before and j["kind"] == kind:
                return j["handle"]
        time.sleep(0.1)
    fail("no new %s job appeared" % kind)


def main():
    global LOG
    if len(sys.argv) < 2 or not os.path.exists(sys.argv[1]):
        print("  skip: needs the pasclaw binary")
        return
    binary = os.path.abspath(sys.argv[1])
    home = tempfile.mkdtemp(prefix="pasclaw-bg-e2e-")
    gport, pport = free_port(), free_port()
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", pport), Provider)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    with open(os.path.join(home, "config.json"), "w") as f:
        json.dump({"providers": [{"name": "fake", "kind": "openai", "api_base": "http://127.0.0.1:%d" % pport,
                                  "api_key": "sk-test", "model": "m"}],
                   "default_provider": "fake", "default_model": "m",
                   "gateway": {"port": gport, "bind_addr": "127.0.0.1", "token": TOKEN}}, f)
    env = dict(os.environ, PASCLAW_HOME=home, NO_COLOR="1")
    env.pop("PASCLAW_GATEWAY_TOKEN", None)
    LOG = os.path.join(home, "gateway.log")
    glog = open(LOG, "w")
    gw_proc = None
    for tag in ("HOLD-1", "HOLD-2"):
        HOLDS[tag] = threading.Event()
    try:
        gw_proc = subprocess.Popen([binary, "gateway", "--port", str(gport), "--addr", "127.0.0.1", "--no-mcp"],
                                   env=env, cwd=home, stdin=subprocess.DEVNULL, stdout=glog, stderr=subprocess.STDOUT)
        gw = Gateway(gport)
        for _ in range(80):
            try:
                urllib.request.urlopen(gw.base + "/v1/health", timeout=1).read()
                break
            except Exception:
                time.sleep(0.25)
        else:
            fail("gateway never answered /v1/health")

        # ---- the token gate ----
        for method, path, body in (("GET", "/v1/background", None), ("GET", "/v1/background/bg-000000", None),
                                   ("POST", "/v1/background/bg-000000/cancel", {}),
                                   ("POST", "/v1/background/bg-000000/message", {"text": "x"})):
            st, _ = gw.req(method, path, body, token=None)
            check(st == 401, "%s %s without the token: %d, want 401" % (method, path, st))
            st, _ = gw.req(method, path, body, token="wrong")
            check(st == 401, "%s %s with a wrong token: %d, want 401" % (method, path, st))
        j = gw.jobs()
        check(j["jobs"] == [] and j["running"] == 0, "a fresh gateway has no jobs: %r" % j)
        check(j.get("cron") == "/v1/cron", "the list points at /v1/cron for scheduled work: %r" % j)
        print("  ok: 401 without the token; an empty list with it")

        # ---- a subagent job, running then done ----
        gw.chat("BG HOLD-1 research the frobnicator")
        h1 = new_handle(gw, set(), "subagent")
        lst = gw.jobs()
        e = [x for x in lst["jobs"] if x["handle"] == h1][0]
        check(e["state"] == "running" and lst["running"] == 1, "job listed running: %r" % lst)
        check(e["agent"] == "general-purpose", "agent named: %r" % e)
        check(e["prompt"] == "HOLD-1 research the frobnicator", "prompt preview: %r" % e)
        check(e["session"] == SESSION, "the chat it belongs to: %r" % e)
        check(isinstance(e["started_at"], int) and e["started_at"] > 1700000000, "start time: %r" % e)
        check(e["finished_at"] is None, "no finish time while running: %r" % e)
        check(e["elapsed_sec"] >= 0 and e["can_cancel"] and not e["can_message"], "running flags: %r" % e)
        d = gw.job(h1)
        check(d["messages"] and d["messages"][0]["role"] == "user" and
              "HOLD-1 research the frobnicator" in d["messages"][0]["content"], "running transcript has the task: %r" % d)
        st, r = gw.req("POST", "/v1/background/%s/message" % h1, {"text": "FOLLOW too early"})
        check(st == 409 and "running" in r.get("error", ""), "message to a running job: %d %r" % (st, r))
        print("  ok: a subagent job is listed running with its agent, prompt, chat and start time")

        HOLDS["HOLD-1"].set()
        d = gw.wait_job(h1, lambda j: j["state"] == "done", "job 1 done")
        check(isinstance(d["finished_at"], int) and d["finished_at"] >= d["started_at"], "finish time: %r" % d)
        check("answer for HOLD-1" in d["result_preview"], "result preview: %r" % d)
        roles = [m["role"] for m in d["messages"]]
        check(roles[:4] == ["user", "assistant", "tool", "assistant"], "transcript roles: %r" % roles)
        tc = d["messages"][1].get("tool_calls") or []
        check(tc and tc[0]["name"] == "list_dir" and tc[0]["line"].startswith("⏺"),
              "the tool call, with the chat's one-liner: %r" % d["messages"][1])
        check(d["messages"][2].get("name") == "list_dir" and "⎿" in d["messages"][2].get("line", ""),
              "the tool result, with its one-liner: %r" % d["messages"][2])
        check(d["messages"][3]["content"] == "answer for HOLD-1", "the answer: %r" % d["messages"][3])
        check(d["can_message"] and not d["can_cancel"], "finished flags: %r" % d)
        print("  ok: it finishes; the detail holds the transcript with tool lines")

        # ---- cancel / message refusals ----
        st, r = gw.req("POST", "/v1/background/%s/cancel" % h1, {})
        check(st == 409 and r.get("state") == "done", "cancel a finished job: %d %r" % (st, r))
        for path, body, want in (("/v1/background/bg-zzzzzz", None, 404),
                                 ("/v1/background/bg-zzzzzz/cancel", {}, 404),
                                 ("/v1/background/bg-zzzzzz/message", {"text": "x"}, 404),
                                 ("/v1/background/%s/message" % h1, {"text": "   "}, 400),
                                 ("/v1/background/%s/nonsense" % h1, {}, 404)):
            st, r = gw.req("GET" if body is None else "POST", path, body)
            check(st == want and "error" in r, "%s: %d %r, want %d" % (path, st, r, want))
        st, r = gw.req("POST", "/v1/background/%s/message" % h1, raw="not json")
        check(st == 400, "a body that is not JSON: %d %r" % (st, r))
        st, r = gw.req("GET", "/v1/background/%s/cancel" % h1)
        check(st == 405, "GET on cancel: %d %r" % (st, r))
        print("  ok: refusals -- 409 cancel of a finished job, 404 unknown, 400 empty or bad body, 405 wrong verb")

        # ---- a follow-up message ----
        n_before = len(SUB_REQUESTS)
        st, r = gw.req("POST", "/v1/background/%s/message" % h1, {"text": "FOLLOW tell me more"})
        check(st == 202 and r.get("continued_from") == h1 and r.get("handle", "").startswith("bg-") and
              r["handle"] != h1, "follow-up accepted as a new job: %d %r" % (st, r))
        check(r.get("session") == SESSION, "the follow-up runs in the same chat: %r" % r)
        h2 = r["handle"]
        d2 = gw.wait_job(h2, lambda j: j["state"] == "done", "the follow-up done")
        check(d2.get("continued_from") == h1, "the new job links back: %r" % d2)
        check(gw.job(h1).get("continued_by") == h2, "the old job links forward")
        sent = SUB_REQUESTS[n_before:]
        check(sent, "the follow-up asked the model")
        conv = [text_of(m) for m in sent[0]["messages"] if m.get("role") != "system"]
        check(any("HOLD-1 research the frobnicator" in c for c in conv) and
              any("answer for HOLD-1" in c for c in conv) and conv[-1].startswith("FOLLOW tell me more"),
              "the model was sent the old conversation and then the message: %r" % conv)
        check("answer for HOLD-1" in d2["result_preview"] and "earlier:" in d2["result_preview"],
              "the follow-up's answer: %r" % d2["result_preview"])
        users = [m["content"] for m in d2["messages"] if m["role"] == "user"]
        check(users[0].startswith("HOLD-1") and users[-1].startswith("FOLLOW tell me more"),
              "the follow-up's transcript continues the old one: %r" % users)
        print("  ok: a follow-up message continues the conversation as a linked job in the same chat")

        # ---- cancel a running subagent (advisory) ----
        gw.chat("BG HOLD-2 a long survey")
        h3 = new_handle(gw, {h1, h2}, "subagent")
        gw.wait_job(h3, lambda j: SUB_CALLS.get("HOLD-2", 0) >= 1, "the subagent's first model call")
        st, r = gw.req("POST", "/v1/background/%s/cancel" % h3, {})
        check(st == 200 and r.get("cancelled") and r.get("advisory") is True and r.get("killed") is False,
              "a subagent's cancel is advisory: %d %r" % (st, r))
        check("next step" in r.get("message", ""), "and says when it stops: %r" % r)
        e = [x for x in gw.jobs()["jobs"] if x["handle"] == h3][0]
        check(e["state"] == "cancelled" and e["stopping"] is True and e["finished_at"] is None,
              "cancelled, still finishing its model call: %r" % e)
        lst = gw.jobs()["jobs"]
        check(lst[0]["handle"] == h3, "the job still running sorts first: %r" % [x["handle"] for x in lst])
        HOLDS["HOLD-2"].set()
        d3 = gw.wait_job(h3, lambda j: j["finished_at"] is not None, "the cancelled job's thread ending")
        check(d3["state"] == "cancelled" and not d3["stopping"], "stays cancelled: %r" % d3)
        time.sleep(0.5)
        check(SUB_CALLS.get("HOLD-2") == 1, "the model was not asked again after the cancel: %r" % SUB_CALLS)
        print("  ok: cancelling a running subagent is advisory; it stops at its next step")

        # ---- shell jobs ----
        gw.chat("SH echo hello-from-shell")
        hs = new_handle(gw, {h1, h2, h3}, "shell")
        ds = gw.wait_job(hs, lambda j: j["state"] == "done", "the shell job done")
        check(ds.get("exit_code") == 0 and "hello-from-shell" in ds.get("output", ""), "shell output: %r" % ds)
        check(ds["command"] == "echo hello-from-shell" and ds["agent"] == "shell", "shell fields: %r" % ds)
        st, r = gw.req("POST", "/v1/background/%s/message" % hs, {"text": "FOLLOW?"})
        check(st == 400 and "shell" in r.get("error", ""), "message to a shell job: %d %r" % (st, r))

        gw.chat("SH sleep 30")
        hk = new_handle(gw, {h1, h2, h3, hs}, "shell")
        gw.wait_job(hk, lambda j: j["state"] == "running", "sleep running")
        lst = gw.jobs()
        check(lst["jobs"][0]["handle"] == hk and lst["running"] == 1, "running first: %r" % lst["jobs"][:2])
        started = [x["started_at"] for x in lst["jobs"][1:]]
        check(started == sorted(started, reverse=True), "then newest first: %r" % started)
        time.sleep(0.3)
        st, r = gw.req("POST", "/v1/background/%s/cancel" % hk, {})
        check(st == 200 and r.get("killed") is True and r.get("advisory") is False, "a shell cancel kills: %d %r" % (st, r))
        t0 = time.time()
        dk = gw.wait_job(hk, lambda j: j["finished_at"] is not None, "the killed job ending", secs=8)
        check(time.time() - t0 < 8 and dk["state"] == "cancelled", "killed promptly: %r" % dk)
        print("  ok: shell jobs -- output and exit code, a 400 for a message, cancel kills")

        print("background_view_e2e: OK")
    finally:
        for ev in HOLDS.values():
            ev.set()
        if gw_proc and gw_proc.poll() is None:
            gw_proc.terminate()
            try:
                gw_proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                gw_proc.kill()
        glog.close()
        httpd.shutdown()
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    main()
