#!/usr/bin/env python3
"""PCLAW.EXE on DOS, end to end: DOSBox-X with COM1 wired to the bridge.

The scripted model and the gateway of dos_bridge_e2e.py; `pasclaw bridge
--listen`; DOSBox-X (headless) with serial1=nullmodem to the bridge, running
the real go32v2 build from `make dos` under CWSDPMI:

  - two tool calls in one step (read_file + list_dir) on the DOS drive: a
    CP437 file reaches the model as UTF-8 and the answer comes back to the
    screen as CP437; the listing leaves out the drive's volume label;
  - write_file answered "y" on DOS's standard input writes a CP437, CR LF
    file ("--" for an em dash the model sent); answered "n" writes nothing;
  - run goes through COMMAND.COM and its output comes back;
  - the model saw the DOS system prompt and the client's five tools.

usage: dos_dosbox_e2e.py <pasclaw-binary> <dir with PCLAW.EXE and CWSDPMI.EXE>
"""
import importlib.util
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
import http.server

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("dos_bridge_e2e", os.path.join(HERE, "dos_bridge_e2e.py"))
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)


def fail(msg, home=None):
    print("FAIL: " + msg)
    if home:
        for name in ("bridge.log", "gateway.log", "dosbox.log"):
            p = os.path.join(home, name)
            if os.path.exists(p):
                with open(p, errors="replace") as f:
                    print("---- %s (tail) ----\n" % name + "".join(f.readlines()[-20:]))
    sys.exit(1)


def main():
    if len(sys.argv) < 3 or not os.path.exists(sys.argv[1]) or \
       not os.path.exists(os.path.join(sys.argv[2], "PCLAW.EXE")):
        print("  skip: needs the pasclaw binary and build/dos/PCLAW.EXE (make dos)")
        return
    if not shutil.which("dosbox-x"):
        print("  skip: needs dosbox-x")
        return
    binary, dosbuild = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    home = tempfile.mkdtemp(prefix="pasclaw-dosbox-e2e-")
    gport, pport, bport = base.free_port(), base.free_port(), base.free_port()
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", pport), base.Provider)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    with open(os.path.join(home, "config.json"), "w") as f:
        json.dump({"providers": [{"name": "fake", "kind": "openai", "api_base": "http://127.0.0.1:%d" % pport,
                                  "api_key": "sk-test", "model": "m"}],
                   "default_provider": "fake", "default_model": "m",
                   "gateway": {"port": gport, "bind_addr": "127.0.0.1"}}, f)
    drive = os.path.join(home, "c")       # DOS drive C:
    os.makedirs(drive)
    for name in ("PCLAW.EXE", "CWSDPMI.EXE"):
        shutil.copy(os.path.join(dosbuild, name), drive)

    def put(name, data):
        with open(os.path.join(drive, name), "wb") as f:
            f.write(data)

    put("NOTES.TXT", b"first line\r\nsecond line caf\x82\r\n")    # CP437 e-acute
    put("P1.TXT", b"TWO NOTES.TXT .\r\n")
    put("P2.TXT", b"WRITE MADE.TXT\r\n")
    put("P3.TXT", b"WRITE REFUSED.TXT\r\n")
    put("P4.TXT", b"RUN VER\r\n")
    put("Y.ANS", b"y\r\n")
    put("N.ANS", b"n\r\n")
    env = dict(os.environ, PASCLAW_HOME=home, NO_COLOR="1")
    glog = open(os.path.join(home, "gateway.log"), "w")
    blog = open(os.path.join(home, "bridge.log"), "w")
    gw = br = None
    try:
        gw = subprocess.Popen([binary, "gateway", "--port", str(gport), "--addr", "127.0.0.1"],
                              env=env, cwd=home, stdin=subprocess.DEVNULL, stdout=glog, stderr=subprocess.STDOUT)
        for _ in range(80):
            try:
                urllib.request.urlopen("http://127.0.0.1:%d/v1/health" % gport, timeout=1).read()
                break
            except Exception:
                time.sleep(0.25)
        else:
            fail("gateway never answered /v1/health", home)
        br = subprocess.Popen([binary, "bridge", "--listen", "127.0.0.1:%d" % bport],
                              env=env, cwd=home, stdin=subprocess.DEVNULL, stdout=blog, stderr=subprocess.STDOUT)
        for _ in range(80):
            try:
                socket.create_connection(("127.0.0.1", bport), timeout=1).close()
                break
            except OSError:
                time.sleep(0.25)
        else:
            fail("bridge never listened", home)

        base.REQUESTS.clear()
        dos_env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
        cmd = ["dosbox-x", "-silent", "-nogui", "-nomenu",
               "-set", "sdl output=surface", "-set", "dosbox memsize=64",
               "-set", "mixer nosound=true", "-set", "cpu core=normal",
               "-set", "serial serial1=nullmodem server:127.0.0.1 port:%d transparent:1" % bport,
               "-c", "mount c \"%s\" -label PCLAWVOL" % drive, "-c", "c:",
               "-c", "PCLAW /YES /F:P1.TXT > OUT1.TXT",
               "-c", "PCLAW /F:P2.TXT < Y.ANS > OUT2.TXT",
               "-c", "PCLAW /F:P3.TXT < N.ANS > OUT3.TXT",
               "-c", "PCLAW /YES /F:P4.TXT > OUT4.TXT",
               "-c", "exit"]
        with open(os.path.join(home, "dosbox.log"), "w") as dl:
            try:
                subprocess.run(cmd, env=dos_env, stdout=dl, stderr=subprocess.STDOUT, timeout=240)
            except subprocess.TimeoutExpired:
                fail("DOSBox-X did not finish in 240 s", home)

        def out(name):
            p = os.path.join(drive, name)
            if not os.path.exists(p):
                fail("DOS wrote no %s" % name, home)
            with open(p, "rb") as f:
                return f.read()

        o1 = out("OUT1.TXT")
        if b"done: [ca] first line\r\nsecond line caf\x82" not in o1:
            fail("read_file on DOS / CP437 round trip: %r" % o1, home)
        if b"NOTES.TXT" not in o1 or b"PCLAWVOL" in o1:
            fail("list_dir on DOS (names, no volume label): %r" % o1, home)
        if b"> read_file NOTES.TXT" not in o1 or b"> list_dir ." not in o1:
            fail("the screen does not show the two calls: %r" % o1, home)

        o2 = out("OUT2.TXT")
        if b"[y/N/a=all]" not in o2 or b"wrote MADE.TXT" not in o2:
            fail("write_file answered y: %r" % o2, home)
        if out("MADE.TXT") != b"made by the model\r\nline 2 -- caf\x82\r\n":
            fail("MADE.TXT is not CP437 with CR LF: %r" % out("MADE.TXT"), home)

        o3 = out("OUT3.TXT")
        if os.path.exists(os.path.join(drive, "REFUSED.TXT")) or b"the user said no" not in o3:
            fail("write_file answered n: %r" % o3, home)

        o4 = out("OUT4.TXT")
        if b"done: [c1]" not in o4 or b"DOS" not in o4.split(b"done: [c1]")[1]:
            fail("run VER through COMMAND.COM: %r" % o4, home)

        reqs = [r for r in base.REQUESTS if any(m.get("role") == "system" for m in r.get("messages", []))]
        if not reqs:
            fail("no request with a system prompt reached the model", home)
        sysmsg = base.text_of([m for m in reqs[0]["messages"] if m.get("role") == "system"][0])
        if "MS-DOS" not in sysmsg or "COMMAND.COM" not in sysmsg:
            fail("the model did not get the DOS system prompt: %r" % sysmsg[:300], home)
        names = sorted(t["function"]["name"] for t in reqs[0].get("tools", []))
        if names != ["edit_file", "list_dir", "read_file", "run", "write_file"]:
            fail("the model saw tools %r" % names, home)
        print("dos_dosbox_e2e: OK")
    finally:
        for p in (br, gw):
            if p and p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill()
        glog.close()
        blog.close()
        httpd.shutdown()
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    main()
