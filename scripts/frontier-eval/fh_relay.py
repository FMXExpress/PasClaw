#!/usr/bin/env python3
"""Relay worker for driving a PasClaw gateway from an external model.

PasClaw's `relay` provider inverts the usual direction: instead of PasClaw
calling a model API, the model connects INBOUND to the gateway, holds a
Server-Sent Events stream open on /v1/relay/poll, and answers each queued
request on /v1/relay/respond/<id>.  That makes any operator -- a person, a
script, or another agent -- usable as the model behind a full PasClaw agent
loop, with no API key and no outbound network.

This file is the worker half of that protocol, written so an interactive
operator can service jobs one shell command at a time.  Two properties of the
gateway make the naive approach (a short-lived `curl` per turn) wrong, and
both are handled here:

  * The poll stream is the worker's registration.  When it closes, the
    gateway calls UnregisterWorker, which REQUEUES every job that worker had
    in flight.  A per-turn curl therefore hands the same job back out again
    and the eventual respond arrives for an id the gateway no longer knows
    ("respond for unknown id ... (late?)").  So `start` forks a daemon that
    holds one stream open for the whole run, and `respond` posts on a
    separate connection.

  * Jobs arrive faster than an operator reads them, and each job repeats the
    entire transcript so far.  The daemon spools every job to its own file
    and `next` prints only the messages added since the previous job, which
    is all an operator needs to choose the next move.

Commands
    start    fork the daemon, hold the SSE stream, spool jobs
    next     block until an unanswered job exists, print its delta
    respond  answer a job (final text, or tool calls)
    show     reprint a spooled job (full transcript, or one field)
    status   daemon liveness, job counts, token totals
    stop     end the daemon and close the stream

The spool directory is the whole state; nothing is kept in memory between
commands.
"""

import argparse
import json
import os
import signal
import sys
import time
import urllib.error
import urllib.request

# --------------------------------------------------------------------------
# spool layout
# --------------------------------------------------------------------------
#   <spool>/jobs/<seq>-<id>.json   one queued request, verbatim
#   <spool>/answered/<id>          marker written after a successful respond
#   <spool>/daemon.pid             pid of the running poll daemon
#   <spool>/daemon.log             daemon diagnostics
#   <spool>/meta.json              base url, worker id


def _spool(args):
    d = os.path.abspath(args.spool)
    os.makedirs(os.path.join(d, "jobs"), exist_ok=True)
    os.makedirs(os.path.join(d, "answered"), exist_ok=True)
    return d


def _meta(spool):
    with open(os.path.join(spool, "meta.json")) as f:
        return json.load(f)


def _jobs(spool):
    """Spooled jobs, oldest first.  Filenames sort by the zero-padded seq."""
    d = os.path.join(spool, "jobs")
    return [os.path.join(d, n) for n in sorted(os.listdir(d)) if n.endswith(".json")]


def _answered(spool, job_id):
    return os.path.exists(os.path.join(spool, "answered", job_id))


def _load(path):
    with open(path) as f:
        return json.load(f)


def _post(url, obj, timeout=60):
    body = json.dumps(obj).encode("utf-8")
    req = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


# --------------------------------------------------------------------------
# start / daemon
# --------------------------------------------------------------------------


def cmd_start(args):
    spool = _spool(args)
    pidfile = os.path.join(spool, "daemon.pid")
    if _alive(pidfile):
        print("relay daemon already running (pid %s)" % open(pidfile).read().strip())
        return 0

    with open(os.path.join(spool, "meta.json"), "w") as f:
        json.dump({"base": args.base.rstrip("/"), "worker_id": args.worker_id}, f)

    try:
        os.remove(os.path.join(spool, "daemon.ready"))
    except OSError:
        pass

    pid = os.fork()
    if pid:
        # The PARENT writes the pidfile.  Letting the child write it races the
        # liveness check below: the parent would see no pidfile, conclude the
        # daemon had died, and report failure while a perfectly healthy child
        # was already holding the stream.
        with open(pidfile, "w") as f:
            f.write(str(pid))
        # Wait for the child to register before returning, so a caller that
        # immediately posts a chat request cannot race the stream open.
        for _ in range(100):
            if os.path.exists(os.path.join(spool, "daemon.ready")):
                print("relay worker %s attached to %s" % (args.worker_id, args.base))
                return 0
            if not _alive(pidfile):
                break
            time.sleep(0.1)
        sys.stderr.write("relay daemon did not attach; see %s/daemon.log\n" % spool)
        return 1

    os.setsid()
    # Detach the inherited stdio.  Without this the daemon keeps the caller's
    # stdout open for the life of the SSE stream, so any shell that runs
    # `start` blocks waiting for EOF that only arrives when the run ends.
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    _daemon(spool, args.base.rstrip("/"), args.worker_id)
    os._exit(0)


def _alive(pidfile):
    try:
        pid = int(open(pidfile).read().strip())
    except (OSError, ValueError):
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def _daemon(spool, base, worker_id):
    log = open(os.path.join(spool, "daemon.log"), "a", buffering=1)
    ready = os.path.join(spool, "daemon.ready")
    seq = len(_jobs(spool))

    def note(msg):
        log.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))

    while True:
        try:
            req = urllib.request.Request(
                base + "/v1/relay/poll", headers={"X-Relay-Worker-Id": worker_id}
            )
            # No read timeout: the stream is idle between jobs by design, and a
            # timeout here would drop registration and requeue in-flight work.
            stream = urllib.request.urlopen(req)
            note("stream open")
            open(ready, "w").write("1")
            for raw in stream:
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                if not line.startswith("data: "):
                    continue
                payload = line[6:]
                try:
                    job = json.loads(payload)
                except ValueError:
                    note("unparseable data line (%d bytes)" % len(payload))
                    continue
                jid = job.get("id")
                if not jid:
                    continue
                seq += 1
                path = os.path.join(spool, "jobs", "%04d-%s.json" % (seq, jid))
                tmp = path + ".tmp"
                with open(tmp, "w") as f:
                    json.dump(job, f)
                os.replace(tmp, path)  # readers never see a half-written job
                note("job %s (%d messages)" % (jid, len(job.get("messages", []))))
        except Exception as exc:  # noqa: BLE001 - daemon must survive anything
            note("stream error: %r" % (exc,))
            try:
                os.remove(ready)
            except OSError:
                pass
            time.sleep(1.0)


def cmd_stop(args):
    spool = _spool(args)
    pidfile = os.path.join(spool, "daemon.pid")
    if not _alive(pidfile):
        print("no relay daemon running")
        return 0
    pid = int(open(pidfile).read().strip())
    os.kill(pid, signal.SIGTERM)
    for _ in range(30):
        if not _alive(pidfile):
            break
        time.sleep(0.1)
    for p in (pidfile, os.path.join(spool, "daemon.ready")):
        try:
            os.remove(p)
        except OSError:
            pass
    print("relay daemon stopped")
    return 0


# --------------------------------------------------------------------------
# next
# --------------------------------------------------------------------------


def _pending(spool):
    for path in _jobs(spool):
        job = _load(path)
        if not _answered(spool, job["id"]):
            return path, job
    return None, None


def _render_tools(tools):
    out = []
    for t in tools:
        fn = t.get("function", t)
        out.append(fn.get("name", "?"))
    return out


def _render_message(m, width):
    role = m.get("role", "?")
    content = m.get("content") or ""
    if len(content) > width:
        content = content[:width] + "\n  ... [%d more chars; `show --field messages`]" % (
            len(content) - width
        )
    head = "--- %s" % role
    if m.get("tool_call_id"):
        head += " (result for %s)" % m["tool_call_id"]
    lines = [head]
    if content:
        lines.append(content)
    for tc in m.get("tool_calls") or []:
        fn = tc.get("function", {})
        args = fn.get("arguments", "")
        if len(args) > width:
            args = args[:width] + " ...[truncated]"
        lines.append("  call %s %s(%s)" % (tc.get("id"), fn.get("name"), args))
    return "\n".join(lines)


def cmd_next(args):
    spool = _spool(args)
    deadline = time.time() + args.timeout
    path = job = None
    while time.time() < deadline:
        path, job = _pending(spool)
        if job:
            break
        time.sleep(0.25)
    if not job:
        print("no pending job after %ss" % args.timeout)
        return 2

    msgs = job.get("messages", [])
    # The delta: a relay job repeats the whole transcript, so only the
    # messages beyond the previous job's count are new information.
    prev = 0
    all_jobs = _jobs(spool)
    idx = all_jobs.index(path)
    if idx > 0 and not args.full:
        prev = len(_load(all_jobs[idx - 1]).get("messages", []))

    print("job: %s" % job["id"])
    print("model: %s   turn: %d/%d messages" % (job.get("model", "?"), idx + 1, len(msgs)))
    if idx == 0 or args.full:
        print("tools: %s" % ", ".join(_render_tools(job.get("tools", []))))
        opts = job.get("options") or {}
        sp = opts.get("system_prompt") or ""
        print("system_prompt: %d chars (`show --field system_prompt`)" % len(sp))
    shown = msgs if args.full else msgs[prev:]
    if prev:
        print("(%d earlier messages elided; --full for all)" % prev)
    for m in shown:
        print(_render_message(m, args.width))
    return 0


def cmd_show(args):
    spool = _spool(args)
    target = None
    for path in _jobs(spool):
        job = _load(path)
        if args.id in (None, job["id"]):
            target = job
    if target is None:
        sys.stderr.write("no such job\n")
        return 1
    if args.field == "system_prompt":
        print((target.get("options") or {}).get("system_prompt", ""))
    elif args.field:
        print(json.dumps(target.get(args.field), indent=1))
    else:
        print(json.dumps(target, indent=1))
    return 0


# --------------------------------------------------------------------------
# respond
# --------------------------------------------------------------------------


def cmd_respond(args):
    spool = _spool(args)
    meta = _meta(spool)

    if args.file:
        with open(args.file) as f:
            body = json.load(f)
    else:
        body = {"content": args.content or "", "finish_reason": "stop"}
        if args.call:
            # Convenience for the common case: one tool call, arguments given
            # as JSON on the command line or in a file.  Saves hand-building
            # the OpenAI envelope (and hand-escaping arguments, which is a
            # JSON string containing JSON) for every turn of a long run.
            raw = args.args
            if raw and os.path.exists(raw):
                with open(raw) as f:
                    raw = f.read()
            parsed = json.loads(raw or "{}")
            body["tool_calls"] = [{
                "id": args.call_id,
                "type": "function",
                "function": {"name": args.call, "arguments": json.dumps(parsed)},
            }]
            body["finish_reason"] = "tool_calls"
        elif args.tool_calls:
            with open(args.tool_calls) as f:
                calls = json.load(f)
            # Accept either a bare list of calls or already-wrapped OpenAI shape.
            body["tool_calls"] = calls if isinstance(calls, list) else calls["tool_calls"]
            body["finish_reason"] = "tool_calls"

    body.setdefault(
        "usage",
        {"prompt_tokens": args.prompt_tokens, "completion_tokens": args.completion_tokens},
    )

    job_id = args.id
    if not job_id:
        path, job = _pending(spool)
        if not job:
            sys.stderr.write("no pending job to answer\n")
            return 1
        job_id = job["id"]

    url = "%s/v1/relay/respond/%s" % (meta["base"], job_id)
    try:
        out = _post(url, body)
    except urllib.error.HTTPError as e:
        sys.stderr.write("respond failed: HTTP %s %s\n" % (e.code, e.read().decode()[:300]))
        return 1
    open(os.path.join(spool, "answered", job_id), "w").write(json.dumps(body))
    print("%s -> %s" % (job_id, out.strip()))
    return 0


def cmd_status(args):
    spool = _spool(args)
    pidfile = os.path.join(spool, "daemon.pid")
    jobs = _jobs(spool)
    answered = sum(1 for p in jobs if _answered(spool, _load(p)["id"]))
    print("daemon: %s" % ("running" if _alive(pidfile) else "stopped"))
    print("attached: %s" % os.path.exists(os.path.join(spool, "daemon.ready")))
    print("jobs: %d spooled, %d answered, %d pending" % (len(jobs), answered, len(jobs) - answered))
    if jobs:
        last = _load(jobs[-1])
        print("last job: %s (%d messages)" % (last["id"], len(last.get("messages", []))))
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--spool", default=".fh-relay", help="state directory")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("start", help="fork the poll daemon")
    s.add_argument("--base", default="http://127.0.0.1:8300")
    s.add_argument("--worker-id", default="relay-1")
    s.set_defaults(fn=cmd_start)

    s = sub.add_parser("next", help="print the oldest unanswered job")
    s.add_argument("--timeout", type=float, default=120.0)
    s.add_argument("--width", type=int, default=4000, help="per-message character budget")
    s.add_argument("--full", action="store_true", help="print the whole transcript")
    s.set_defaults(fn=cmd_next)

    s = sub.add_parser("respond", help="answer a job")
    s.add_argument("--id", help="job id (default: oldest unanswered)")
    s.add_argument("--content", help="final assistant text")
    s.add_argument("--call", help="name of a single tool to call")
    s.add_argument("--args", help="JSON arguments for --call, inline or a file path")
    s.add_argument("--call-id", default="c1", help="id for --call")
    s.add_argument("--tool-calls", help="JSON file holding an OpenAI tool_calls array")
    s.add_argument("--file", help="JSON file holding the entire response body")
    s.add_argument("--prompt-tokens", type=int, default=0)
    s.add_argument("--completion-tokens", type=int, default=0)
    s.set_defaults(fn=cmd_respond)

    s = sub.add_parser("show", help="print a spooled job")
    s.add_argument("--id")
    s.add_argument("--field")
    s.set_defaults(fn=cmd_show)

    s = sub.add_parser("status", help="daemon and spool state")
    s.set_defaults(fn=cmd_status)

    s = sub.add_parser("stop", help="stop the poll daemon")
    s.set_defaults(fn=cmd_stop)

    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
