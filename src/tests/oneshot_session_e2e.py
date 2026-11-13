#!/usr/bin/env python3
"""`pasclaw agent -m ... --session ID` is a turn ON that session.

It used to send the model the new prompt alone and then save that turn's
history over the session file. Three things followed: the reply was never
saved (the loop's history stops one message short of it), the model did
not see the conversation so far, and the conversation so far was
replaced by the latest question -- whatever the session held, interactive
turns included.

Against the real binary, with a fake OpenAI-compatible provider this
script runs and scripts (a plain reply, a tool call, a 401). Checked:

  - a turn saves the question and the reply, and the next turn sends the
    model everything before it and adds to the saved transcript;
  - a turn that uses a tool saves the call, its result and the answer,
    and the next turn sends them back in order;
  - the working-state snapshot is brought up to date by a turn, is put in
    front of the next turn's prompt once, and never ends up in the prompt
    the session saves (it would be added again every turn);
  - a turn the provider refuses keeps the conversation and the question,
    saves no error text as a reply, and sends none the turn after;
  - a session that works in another directory has its tools run there;
  - without --session nothing is saved, as before;
  - when the turn compacts the history, the summary is saved with the
    session and the next turn starts from it.

usage: oneshot_session_e2e.py <pasclaw-binary>
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

REFUSAL = "Incorrect API key provided"
SUMMARY = "SUMMARY-OF-WHAT-WAS-DROPPED"
WORKING_STATE = "## Working state from prior turns"


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


class Provider(http.server.BaseHTTPRequestHandler):
    """OpenAI chat completions. A request with no tools is the compaction
    summariser's and gets SUMMARY-<n>, a different text each time. Any
    other takes the next scripted step, or says "reply number N"."""
    script = []      # {"text": ..} | {"tool": (name, args)} | {"status": 401}
    turns = []       # request bodies of ordinary calls
    summaries = []   # request bodies of summariser calls

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if not body.get("tools"):
            Provider.summaries.append(body)
            return self.reply({"role": "assistant",
                               "content": "%s-%d" % (SUMMARY, len(Provider.summaries))}, "stop")
        Provider.turns.append(body)
        step = Provider.script.pop(0) if Provider.script else {"text": "reply number %d" % len(Provider.turns)}
        if "status" in step:
            out = json.dumps({"error": {"message": REFUSAL, "type": "invalid_request_error"}}).encode()
            return self.send(step["status"], out)
        if "tool" in step:
            name, args = step["tool"]
            return self.reply({"role": "assistant", "content": None, "tool_calls": [
                {"id": "call_%d" % len(Provider.turns), "type": "function",
                 "function": {"name": name, "arguments": json.dumps(args)}}]}, "tool_calls")
        return self.reply({"role": "assistant", "content": step["text"]}, "stop")

    def reply(self, message, finish):
        self.send(200, json.dumps({"id": "c1", "object": "chat.completion", "model": "m",
                                   "choices": [{"index": 0, "finish_reason": finish, "message": message}],
                                   "usage": {"prompt_tokens": 11, "completion_tokens": 7}}).encode())

    def send(self, status, out):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def text_of(content):
    if isinstance(content, list):
        content = " ".join(str(p.get("text", "")) for p in content if isinstance(p, dict))
    return (content or "").split("\n\n[current date/time")[0]


def flat(msgs):
    """role:text, with the names of any tool calls, for comparing transcripts."""
    out = []
    for m in msgs:
        if m.get("role") == "system":
            continue
        calls = ",".join(c["function"]["name"] for c in m.get("tool_calls") or [])
        out.append("%s:%s%s" % (m.get("role"), text_of(m.get("content"))[:60], (" ->" + calls) if calls else ""))
    return out


class Home:
    def __init__(self, binary, port, extra=None):
        self.binary = binary
        self.home = tempfile.mkdtemp(prefix="pasclaw-oneshot-session-e2e-")
        self.ws = os.path.join(self.home, "ws")
        os.makedirs(self.ws)
        self.sessions = os.path.join(self.home, "workspace", "sessions")
        cfg = {"providers": [{"name": "fake", "kind": "openai",
                              "api_base": "http://127.0.0.1:%d/v1" % port,
                              "api_key": "sk-test", "model": "m"}],
               "default_provider": "fake", "default_model": "m",
               "stats_collection_enabled": True,
               "sandbox": {"workspace": self.ws}}
        cfg.update(extra or {})
        with open(os.path.join(self.home, "config.json"), "w") as f:
            json.dump(cfg, f)
        Provider.script, Provider.turns, Provider.summaries = [], [], []

    def turn(self, text, session="daily"):
        """One `pasclaw agent -m` run: (stdout, exit code)."""
        argv = [self.binary, "agent", "-m", text, "--quiet"]
        if session:
            argv += ["--session", session]
        r = subprocess.run(argv, env=dict(os.environ, PASCLAW_HOME=self.home), cwd=self.home,
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        return r.stdout.strip(), r.returncode

    def doc(self, sid="daily"):
        with open(os.path.join(self.sessions, sid + ".json")) as f:
            return json.load(f)

    def saved(self, sid="daily"):
        return flat(self.doc(sid).get("messages", []))

    def sent(self):
        return flat(Provider.turns[-1]["messages"])

    def system(self):
        return "\n".join(text_of(m.get("content")) for m in Provider.turns[-1]["messages"]
                         if m.get("role") == "system")

    def close(self):
        shutil.rmtree(self.home, ignore_errors=True)


def expect(got, want, what):
    if got != want:
        fail("%s:\n  got  %s\n  want %s" % (what, got, want))


def conversation(binary, port):
    h = Home(binary, port)
    try:
        # ---- a turn saves the question and the reply; the next one builds on it ----
        out, code = h.turn("first question")
        expect((out, code), ("reply number 1", 0), "the first turn's output")
        expect(h.saved(), ["user:first question", "assistant:reply number 1"],
               "what the first turn saved")
        out, _ = h.turn("second question")
        expect(h.sent(), ["user:first question", "assistant:reply number 1", "user:second question"],
               "what the second turn sent the model")
        want = ["user:first question", "assistant:reply number 1",
                "user:second question", "assistant:reply number 2"]
        expect(h.saved(), want, "the transcript after two turns")
        st = h.doc()["meta"].get("stats", {})
        expect((st.get("turns"), st.get("input_tokens"), st.get("output_tokens")), (2, 22, 14),
               "the session's counters after two turns")
        print("  ok: a turn saves its reply, and the next one sends and keeps the conversation so far")

        # ---- a tool turn: call, result and answer are saved and sent back ----
        Provider.script = [{"tool": ("write_file", {"path": "out.txt", "content": "hi"})},
                           {"text": "wrote it"}]
        out, _ = h.turn("write out.txt")
        expect(out, "wrote it", "the tool turn's output")
        if not os.path.exists(os.path.join(h.ws, "out.txt")):
            fail("the tool turn did not write out.txt in the workspace")
        got = h.saved()
        expect(got[:4], want, "the earlier turns after a tool turn")
        expect([g.split(":")[0] + (" ->" + g.split(" ->")[1] if " ->" in g else "") for g in got[4:]],
               ["user", "assistant ->write_file", "tool", "assistant"],
               "the shape of the saved tool turn")
        expect(got[-1], "assistant:wrote it", "the tool turn's saved answer")
        tool_msg = h.doc()["messages"][6]
        if tool_msg.get("tool_call_id") != h.doc()["messages"][5]["tool_calls"][0]["id"]:
            fail("the saved tool result is not paired with its call: %s" % tool_msg)
        meta = h.doc()["meta"]
        if "out.txt" not in json.dumps(meta.get("working_state", {}).get("edited_files", [])):
            fail("the working-state snapshot does not list the edited file: %s" % meta.get("working_state"))
        if not meta.get("system_prompt_override"):
            fail("the session saved no prompt for its next turn")
        if WORKING_STATE in meta["system_prompt_override"]:
            fail("the working-state block was saved into the session's prompt")
        print("  ok: a tool turn saves the call, its result and the answer, and updates the working state")

        # ---- the next turns: rich history back in order, the snapshot once ----
        for n, text in ((4, "fourth question"), (5, "fifth question")):
            h.turn(text)
            if n == 4:
                expect(h.sent(), got + ["user:fourth question"], "what the turn after the tool turn sent")
            sysp = h.system()
            if sysp.count(WORKING_STATE) != 1 or "out.txt" not in sysp:
                fail("turn %d's prompt carries the working-state block %d time(s), want once with out.txt"
                     % (n, sysp.count(WORKING_STATE)))
            if WORKING_STATE in h.doc()["meta"]["system_prompt_override"]:
                fail("after turn %d the working-state block is in the session's saved prompt" % n)
        print("  ok: later turns get the tool history in order and the working-state block exactly once")

        # ---- a refused turn: nothing lost, no error dressed as a reply ----
        before = h.saved()
        Provider.script = [{"status": 401}]
        out, _ = h.turn("sixth question")
        if REFUSAL not in out:
            fail("the refused turn did not report the provider's error: %r" % out)
        expect(h.saved(), before + ["user:sixth question"], "the transcript after a refused turn")
        h.turn("seventh question")
        if any(REFUSAL in s for s in h.sent()):
            fail("the turn after a refusal sent the error text to the model: %s" % h.sent()[-4:])
        expect(h.sent()[-2:], ["user:sixth question", "user:seventh question"],
               "the end of what the turn after a refusal sent")
        expect(h.saved()[-3:], ["user:sixth question", "user:seventh question", "assistant:" + out_of(h)],
               "the end of the transcript after the turn that followed a refusal")
        print("  ok: a refused turn keeps the conversation and the question, and no error becomes a reply")

        # ---- without --session nothing is saved ----
        files = sorted(os.listdir(h.sessions))
        out, code = h.turn("not for keeping", session=None)
        if code != 0 or not out:
            fail("a one-shot without a session failed: %r %d" % (out, code))
        expect(sorted(os.listdir(h.sessions)), files, "the saved sessions after a one-shot without --session")
        if any("not for keeping" in s for s in h.saved()):
            fail("a one-shot without --session was written into another session")
        print("  ok: a one-shot without --session still saves nothing")

        # ---- a session that works elsewhere has its tools run there ----
        elsewhere = os.path.join(h.home, "elsewhere")
        os.makedirs(elsewhere)
        moved = h.doc()
        moved["meta"]["id"] = "moved"
        moved["meta"]["location"] = elsewhere
        with open(os.path.join(h.sessions, "moved.json"), "w") as f:
            json.dump(moved, f)
        Provider.script = [{"tool": ("write_file", {"path": "there.txt", "content": "x"})},
                           {"text": "done there"}]
        out, _ = h.turn("write there.txt", session="moved")
        expect(out, "done there", "the output of the turn on the moved session")
        if not os.path.exists(os.path.join(elsewhere, "there.txt")):
            fail("the turn did not work in the session's own directory (%s)" % os.listdir(elsewhere))
        if os.path.exists(os.path.join(h.ws, "there.txt")):
            fail("the turn wrote into the launch workspace instead of the session's directory")
        expect(h.doc("moved")["meta"].get("location"), elsewhere, "the moved session's location afterwards")
        print("  ok: a turn on a session that works in another directory runs its tools there")
    finally:
        h.close()


def out_of(h):
    """The text of the last saved assistant message."""
    for m in reversed(h.doc().get("messages", [])):
        if m.get("role") == "assistant":
            return text_of(m.get("content"))[:60]
    return ""


def compaction(binary, port):
    # A threshold a few long prompts cross, so a one-shot turn compacts.
    h = Home(binary, port, {"compaction": {"enabled": True, "threshold_tokens": 600,
                                           "retain_budget_tokens": 150, "recent_turns": 1,
                                           "summary_budget": 100}})
    try:
        filler = "lorem ipsum dolor sit amet " * 40          # about 270 tokens
        n = 0
        while not Provider.summaries:
            n += 1
            if n > 8:
                fail("eight long turns never compacted the history")
            h.turn("long turn %d: %s" % (n, filler), session="long")
        meta = h.doc("long")["meta"]
        first = "%s-%d" % (SUMMARY, len(Provider.summaries))
        if first not in meta.get("system_prompt_override", ""):
            fail("turn %d compacted the history and the summary was not saved with the session: %r"
                 % (n, meta.get("system_prompt_override", "")[-200:]))
        if len(h.doc("long")["messages"]) >= 2 * n:
            fail("the saved transcript was not compacted: %d messages after %d turns"
                 % (len(h.doc("long")["messages"]), n))
        # The next turn starts from that summary: it is in the prompt the
        # model gets, or -- when this turn compacts again -- in what the
        # summariser is given to fold into the next one. A turn that
        # rebuilt its prompt from scratch has it in neither.
        t0, s0 = len(Provider.turns), len(Provider.summaries)
        h.turn("and after the compaction?", session="long")
        if not any(first in json.dumps(b) for b in Provider.turns[t0:] + Provider.summaries[s0:]):
            fail("the turn after a compaction did not start from the saved summary (%s)" % first)
        if h.saved("long")[-2:] != ["user:and after the compaction?", "assistant:" + text_of(
                h.doc("long")["messages"][-1].get("content"))[:60]]:
            fail("the turn after a compaction was not saved whole: %s" % h.saved("long")[-3:])
        print("  ok: a turn that compacts saves the summary, and the next turn starts from it (turn %d)" % n)
    finally:
        h.close()


def main():
    if len(sys.argv) != 2 or not os.path.exists(sys.argv[1]):
        print("  skip: needs the pasclaw binary")
        return
    binary = os.path.abspath(sys.argv[1])
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), Provider)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        conversation(binary, port)
        compaction(binary, port)
    finally:
        httpd.shutdown()
    print("one-shot session e2e: all checks passed")


if __name__ == "__main__":
    main()
