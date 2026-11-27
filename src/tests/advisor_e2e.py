#!/usr/bin/env python3
"""The advisor tool, end to end, against two scripted fake providers.

"main" is the agent's model, scripted on the user's first word; "adv" is the
advisor's provider, which answers every request with numbered advice and
records what it was sent. Each check runs build/pasclaw against them:

  - `agent -m`: the main model calls `advisor`; the advisor's request has the
    advisor system prompt, one user message carrying the transcript (the
    user's words, the assistant's advisor call) and the question, the
    configured model, and no tools; the main model's next request carries
    the advice, verbatim, as the tool result; the advisor's tokens land in a
    stats bucket of their own, under the advisor's model;
  - the cap: a third call in one turn is refused with a message the model can
    act on, in sequential rounds and in one parallel round; a new turn of the
    same session starts the count again;
  - plan mode: the advisor is read-only, so plan mode lets it run;
  - the tool is absent with no advisor model configured, and with
    --no-advisor; --advisor provider:model turns it on and picks the model;
  - the agent REPL and the line TUI: /advisor shows the status, /advisor off
    takes the tool out of the next request, /advisor provider:model puts it
    back with that model;
  - `gateway --advisor` serves it to /v1/chat; `gateway --no-advisor` does not.

usage: advisor_e2e.py <pasclaw-binary>
"""
import glob
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

MAIN_REQS = []   # every request the main model saw
ADV_REQS = []    # every request the advisor saw
LOCK = threading.Lock()
HOMES = []


def fail(msg, out=None):
    print("FAIL: " + msg)
    if out:
        print("---- output (tail) ----\n" + "\n".join(out.splitlines()[-40:]))
    sys.exit(1)


def ok(msg):
    print("  ok   " + msg)


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


def tool_names(body):
    return [t.get("function", {}).get("name") for t in (body.get("tools") or [])]


def reply(handler, msg, finish, usage=(5, 3)):
    out = json.dumps({"id": "c", "object": "chat.completion", "model": "m",
                      "choices": [{"index": 0, "finish_reason": finish, "message": msg}],
                      "usage": {"prompt_tokens": usage[0], "completion_tokens": usage[1]}}).encode()
    handler.send_response(200)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(out)))
    handler.end_headers()
    handler.wfile.write(out)


def advisor_call(cid, question):
    return {"id": cid, "type": "function",
            "function": {"name": "advisor", "arguments": json.dumps({"question": question})}}


class Main(http.server.BaseHTTPRequestHandler):
    """The agent's model. Scripted on the first word of the turn's user message:
         ASK1  -> one advisor call, then "final: <result>"
         ASK3  -> three advisor calls, one per round, then "final: r1 | r2 | r3"
         PAR3  -> three advisor calls in one round, then "final: ..."
         else  -> a plain answer."""

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        with LOCK:
            MAIN_REQS.append(body)
        msgs = body.get("messages") or []
        users = [m for m in msgs if m.get("role") == "user"]
        word = text_of(users[-1]).split()[0] if users else ""
        # The tool results of this turn: everything after the last user message.
        last_user = max(i for i, m in enumerate(msgs) if m.get("role") == "user") if users else -1
        results = [text_of(m) for m in msgs[last_user + 1:] if m.get("role") == "tool"]
        want = {"ASK1": 1, "ASK3": 3}.get(word, 0)
        if word == "PAR3":
            if not results:
                calls = [advisor_call("p%d" % i, "parallel question %d" % i) for i in (1, 2, 3)]
                return reply(self, {"role": "assistant", "content": None, "tool_calls": calls}, "tool_calls")
            return reply(self, {"role": "assistant", "content": "final: " + " | ".join(results)}, "stop")
        if want and len(results) < want:
            n = len(results) + 1
            q = "Q%d: should I patch the build script or the source file?" % n
            return reply(self, {"role": "assistant", "content": "Let me get a second opinion.",
                                "tool_calls": [advisor_call("a%d" % n, q)]}, "tool_calls")
        if want:
            return reply(self, {"role": "assistant", "content": "final: " + " | ".join(results)}, "stop")
        return reply(self, {"role": "assistant", "content": "plain answer"}, "stop")

    def log_message(self, *a):
        pass


class Adv(http.server.BaseHTTPRequestHandler):
    """The advisor's provider: numbered advice, fixed usage."""

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        with LOCK:
            ADV_REQS.append(body)
            n = len(ADV_REQS)
        reply(self, {"role": "assistant", "content": "ADVICE-%d: patch the source file, not the build script." % n},
              "stop", usage=(111, 22))

    def log_message(self, *a):
        pass


def make_home(main_port, adv_port, advisor=None, extra=None):
    home = tempfile.mkdtemp(prefix="pasclaw-advisor-e2e-")
    HOMES.append(home)
    cfg = {"providers": [
               {"name": "main", "kind": "openai", "api_base": "http://127.0.0.1:%d" % main_port,
                "api_key": "sk-test", "model": "main-model"},
               {"name": "adv", "kind": "openai", "api_base": "http://127.0.0.1:%d" % adv_port,
                "api_key": "sk-test", "model": "adv-default"}],
           "default_provider": "main", "default_model": "main-model",
           "stats_collection_enabled": True,
           "auto_router": {"enabled": False},
           "subagents_enabled": False}
    if advisor is not None:
        cfg["advisor"] = advisor
    if extra:
        cfg.update(extra)
    with open(os.path.join(home, "config.json"), "w") as f:
        json.dump(cfg, f)
    os.makedirs(os.path.join(home, "workspace"), exist_ok=True)
    return home


def run(binary, home, args, stdin=None):
    env = dict(os.environ, PASCLAW_HOME=home, NO_COLOR="1")
    env.pop("PASCLAW_PROFILE", None)
    r = subprocess.run([binary] + args, cwd=os.path.join(home, "workspace"), env=env, input=stdin,
                       capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout + r.stderr


def reset():
    with LOCK:
        del MAIN_REQS[:]
        del ADV_REQS[:]


def first_main_with(word):
    """The first main-model request whose latest user message starts with word."""
    for b in MAIN_REQS:
        users = [m for m in (b.get("messages") or []) if m.get("role") == "user"]
        if users and text_of(users[-1]).startswith(word):
            return b
    return None


def check_advisor_request(body, question_part, user_part, model):
    if body.get("model") != model:
        fail("advisor request went to model %r, want %r" % (body.get("model"), model))
    if body.get("tools"):
        fail("advisor request carried tools: %r" % tool_names(body))
    msgs = body.get("messages") or []
    roles = [m.get("role") for m in msgs]
    if roles != ["system", "user"]:
        fail("advisor request roles %r, want system + one user message" % roles)
    sysp, user = text_of(msgs[0]), text_of(msgs[1])
    if "second-opinion advisor" not in sysp or "cannot run tools" not in sysp:
        fail("advisor system prompt is not the advisor's: %r" % sysp[:200])
    if "<transcript>" not in user or user_part not in user:
        fail("advisor did not get the transcript with the user's words: %r" % user[:600])
    if "[assistant called advisor]" not in user:
        fail("transcript does not show the agent's tool call: %r" % user[:800])
    tail = user.split("</transcript>", 1)[-1]
    if question_part not in tail:
        fail("the question is not after the transcript: %r" % tail[:300])


def main():
    if len(sys.argv) < 2 or not os.path.exists(sys.argv[1]):
        print("  skip: needs the pasclaw binary")
        return
    binary = os.path.abspath(sys.argv[1])
    mport, aport = free_port(), free_port()
    for port, h in ((mport, Main), (aport, Adv)):
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), h)
        threading.Thread(target=srv.serve_forever, daemon=True).start()

    adv_cfg = {"provider": "adv", "model": "adv-model", "max_calls_per_turn": 2}
    home = make_home(mport, aport, adv_cfg)

    # 1. One consultation, one-shot.
    reset()
    code, out = run(binary, home, ["agent", "-m", "ASK1 the build fails on a missing include"])
    if code != 0 or "final: ADVICE-1: patch the source file" not in out:
        fail("agent -m ASK1: exit %d" % code, out)
    first = first_main_with("ASK1")
    if "advisor" not in tool_names(first):
        fail("main model was not offered advisor: %r" % tool_names(first))
    desc = [t["function"]["description"] for t in first["tools"] if t["function"]["name"] == "advisor"][0]
    if "second opinion" not in desc or "At most 2 call(s)" not in desc:
        fail("advisor description: %r" % desc)
    if len(ADV_REQS) != 1:
        fail("advisor got %d requests, want 1" % len(ADV_REQS), out)
    check_advisor_request(ADV_REQS[0], "Q1: should I patch the build script",
                          "ASK1 the build fails on a missing include", "adv-model")
    last = MAIN_REQS[-1]["messages"][-1]
    if last.get("role") != "tool" or text_of(last) != "ADVICE-1: patch the source file, not the build script.":
        fail("the main model's next request does not carry the advice as the tool result: %r" % last)
    ok("agent -m: advisor gets the transcript + question with no tools; the advice comes back as the tool result")

    buckets = glob.glob(os.path.join(home, "workspace", "sessions", "_gateway_advisor_*.json"))
    if len(buckets) != 1:
        fail("want one advisor stats bucket, found %r" % buckets)
    meta = json.load(open(buckets[0]))["meta"]
    st = meta.get("stats") or {}
    if meta.get("model") != "adv-model" or st.get("input_tokens") != 111 or st.get("output_tokens") != 22:
        fail("advisor stats bucket: %r" % meta)
    ok("advisor usage lands in its own stats bucket under the advisor's model (111 in / 22 out)")

    # 2. The cap, sequential rounds.
    reset()
    code, out = run(binary, home, ["agent", "--session", "cap-test", "-m", "ASK3 three opinions please"])
    if code != 0:
        fail("agent -m ASK3: exit %d" % code, out)
    if len(ADV_REQS) != 2:
        fail("cap 2: advisor got %d requests" % len(ADV_REQS), out)
    final = MAIN_REQS[-1]["messages"]
    third = text_of([m for m in final if m.get("role") == "tool"][-1])
    if not third.startswith("ERROR: advisor: limit reached") or "max_calls_per_turn" not in third \
            or "next message" not in third:
        fail("third call's result: %r" % third)
    ok("cap: the third call in a turn is refused with a message the model can act on")

    # 2b. A new turn of the same session counts from zero, though the history
    #     already holds this session's earlier advisor calls.
    reset()
    code, out = run(binary, home, ["agent", "--session", "cap-test", "-m", "ASK3 and again"])
    if code != 0 or len(ADV_REQS) != 2:
        fail("second turn: exit %d, advisor got %d requests, want 2" % (code, len(ADV_REQS)), out)
    ok("cap: the next turn of the same session starts the count again")

    # 2c. The cap holds in one parallel round.
    reset()
    code, out = run(binary, home, ["agent", "-m", "PAR3 all at once"])
    if code != 0:
        fail("agent -m PAR3: exit %d" % code, out)
    results = [text_of(m) for m in MAIN_REQS[-1]["messages"] if m.get("role") == "tool"]
    refused = [r for r in results if r.startswith("ERROR: advisor: limit reached")]
    if len(results) != 3 or len(refused) != 1 or len(ADV_REQS) != 2:
        fail("parallel round: results %r, advisor requests %d" % (results, len(ADV_REQS)), out)
    ok("cap: three calls in one parallel round -> two answered, one refused")

    # 3. Plan mode lets the read-only advisor run.
    reset()
    code, out = run(binary, home, ["agent", "--plan", "-m", "ASK1 plan it"])
    if code != 0 or "final: ADVICE-1" not in out or len(ADV_REQS) != 1:
        fail("plan mode: exit %d, advisor requests %d" % (code, len(ADV_REQS)), out)
    ok("plan mode: the advisor runs (read-only)")

    # 4. --no-advisor takes the tool away.
    reset()
    code, out = run(binary, home, ["agent", "--no-advisor", "-m", "PLAIN hello"])
    if code != 0 or "advisor" in tool_names(first_main_with("PLAIN")):
        fail("--no-advisor: exit %d, tools %r" % (code, tool_names(first_main_with("PLAIN") or {})), out)
    ok("--no-advisor: no advisor tool")

    # 5. Not configured: absent; --advisor provider:model turns it on.
    bare = make_home(mport, aport, None)
    reset()
    code, out = run(binary, bare, ["agent", "-m", "PLAIN hello"])
    if code != 0 or "advisor" in tool_names(first_main_with("PLAIN")):
        fail("no advisor configured: exit %d, tools %r" % (code, tool_names(first_main_with("PLAIN") or {})), out)
    ok("no advisor model configured: no advisor tool")
    reset()
    code, out = run(binary, bare, ["agent", "--advisor", "adv:flag-model", "-m", "ASK1 via the flag"])
    if code != 0 or len(ADV_REQS) != 1:
        fail("--advisor adv:flag-model: exit %d, advisor requests %d" % (code, len(ADV_REQS)), out)
    check_advisor_request(ADV_REQS[0], "Q1:", "ASK1 via the flag", "flag-model")
    ok("--advisor provider:model: the tool is there and asks that model on that provider")
    code, out = run(binary, bare, ["agent", "--advisor", "adv:", "-m", "x"])
    if code != 2 or "names no model" not in out:
        fail("--advisor adv: should be refused (exit 2): exit %d" % code, out)
    ok("--advisor provider: with no model is refused")

    # 6. The REPL: /advisor status, off, and a new model.
    reset()
    code, out = run(binary, home, ["agent"],
                    stdin="/advisor\n/advisor off\nPLAIN in the repl\n/advisor adv:repl-model\n"
                          "ASK1 from the repl\n/quit\n")
    if code != 0:
        fail("agent REPL: exit %d" % code, out)
    if "advisor: adv-model on adv (from config.json)" not in out or "advisor: off for this session" not in out \
            or "advisor: repl-model on adv (this session)" not in out:
        fail("REPL /advisor lines missing", out)
    if "advisor" in tool_names(first_main_with("PLAIN")):
        fail("REPL: /advisor off left the tool in the next request")
    if "advisor" not in tool_names(first_main_with("ASK1")) or len(ADV_REQS) != 1 \
            or ADV_REQS[0].get("model") != "repl-model":
        fail("REPL: /advisor adv:repl-model did not bring it back with that model", out)
    ok("agent REPL: /advisor shows, /advisor off removes, /advisor provider:model restores with that model")

    # 7. The line TUI: the same command.
    reset()
    code, out = run(binary, home, ["tui"], stdin="/advisor\n/advisor off\nPLAIN in the tui\n/quit\n")
    if "advisor: adv-model on adv (from config.json)" not in out or "advisor: off for this session" not in out:
        fail("tui /advisor lines missing (exit %d)" % code, out)
    plain = first_main_with("PLAIN")
    if plain is None or "advisor" in tool_names(plain):
        fail("tui: /advisor off left the tool in the next request (%r)" % (plain and tool_names(plain)), out)
    ok("tui: /advisor shows the status, /advisor off removes the tool")

    # 8. The gateway: --advisor serves it, --no-advisor does not.
    for flags, want in ((["--advisor", "adv:gw-model"], True), (["--no-advisor"], False)):
        reset()
        gport = free_port()
        env = dict(os.environ, PASCLAW_HOME=bare if want else home, NO_COLOR="1")
        log = open(os.path.join(HOMES[0], "gateway.log"), "w")
        gw = subprocess.Popen([binary, "gateway", "--port", str(gport), "--addr", "127.0.0.1"] + flags,
                              env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        try:
            for _ in range(80):
                try:
                    urllib.request.urlopen("http://127.0.0.1:%d/v1/health" % gport, timeout=1).read()
                    break
                except Exception:
                    time.sleep(0.25)
            else:
                fail("gateway never answered /v1/health")
            req = urllib.request.Request("http://127.0.0.1:%d/v1/chat" % gport,
                                         data=json.dumps({"message": "ASK1 through the gateway"}).encode(),
                                         headers={"Content-Type": "application/json"})
            body = urllib.request.urlopen(req, timeout=60).read().decode()
            offered = "advisor" in tool_names(first_main_with("ASK1") or {})
            if offered != want:
                fail("gateway %s: advisor offered=%s" % (flags, offered))
            if want and (len(ADV_REQS) != 1 or ADV_REQS[0].get("model") != "gw-model" or "ADVICE-1" not in body):
                fail("gateway --advisor: advisor requests %r, reply %r" % (
                    [r.get("model") for r in ADV_REQS], body[:300]))
        finally:
            gw.terminate()
            try:
                gw.wait(timeout=10)
            except subprocess.TimeoutExpired:
                gw.kill()
            log.close()
    ok("gateway: --advisor serves the tool to /v1/chat, --no-advisor does not")

    for h in HOMES:
        shutil.rmtree(h, ignore_errors=True)
    print("advisor_e2e: all checks passed")


if __name__ == "__main__":
    main()
