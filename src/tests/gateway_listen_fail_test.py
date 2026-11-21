#!/usr/bin/env python3
"""A gateway that cannot listen says so in one line and exits 1.

Each of its three listeners -- the main port, --mcp-port and --apps-port --
is pointed at a port this test holds. The gateway must exit 1 promptly,
name the address and port (and which flag) in its error, print no
unhandled-exception dump, and leave no run file behind (the main listener
was up and had written one when the second listener failed).

usage: gateway_listen_fail_test.py <pasclaw binary>
"""
import os
import shutil
import socket
import subprocess
import sys
import tempfile


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def main():
    binary = os.path.abspath(sys.argv[1])
    held = socket.socket()
    held.bind(("127.0.0.1", 0))
    held.listen(1)
    busy = held.getsockname()[1]
    fails = 0
    cases = [
        ("main port", ["--port", str(busy)], "cannot listen on 127.0.0.1:%d: " % busy),
        ("--mcp-port", ["--port", str(free_port()), "--mcp-port", str(busy)],
         "cannot listen on 127.0.0.1:%d (--mcp-port): " % busy),
        ("--apps-port", ["--port", str(free_port()), "--apps-port", str(busy)],
         "cannot listen on 127.0.0.1:%d (--apps-port): " % busy),
    ]
    try:
        for name, args, want in cases:
            home = tempfile.mkdtemp(prefix="pasclaw-listen-fail-")
            try:
                env = dict(os.environ, PASCLAW_HOME=home, NO_COLOR="1")
                try:
                    r = subprocess.run([binary, "gateway", "--addr", "127.0.0.1", "--no-tools"] + args,
                                       env=env, cwd=home, stdin=subprocess.DEVNULL,
                                       capture_output=True, text=True, timeout=60)
                except subprocess.TimeoutExpired:
                    print("FAIL: %s: the gateway kept running on a port it could not have" % name)
                    fails += 1
                    continue
                out = r.stdout + r.stderr
                problems = []
                if r.returncode != 1:
                    problems.append("exit %d, want 1" % r.returncode)
                if want not in out:
                    problems.append("no %r" % want)
                if "nhandled exception" in out or "An unhandled" in out:
                    problems.append("an unhandled-exception dump")
                if os.path.exists(os.path.join(home, "run")) and os.listdir(os.path.join(home, "run")):
                    problems.append("a run file left behind: %r" % os.listdir(os.path.join(home, "run")))
                if problems:
                    print("FAIL: %s: %s\n----\n%s" % (name, "; ".join(problems), out[-1500:]))
                    fails += 1
                else:
                    print("  ok: %s" % name)
            finally:
                shutil.rmtree(home, ignore_errors=True)
    finally:
        held.close()
    if fails:
        sys.exit(1)
    print("gateway_listen_fail: OK")


if __name__ == "__main__":
    main()
