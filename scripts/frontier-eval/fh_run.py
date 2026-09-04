#!/usr/bin/env python3
"""Run PasClaw as a coding-agent harness on a FrontierHarness Eval task.

FrontierHarness Eval (github.com/frontier-harness-eval/eval) holds the model
constant and varies the harness: one model, 30 tasks, 12 harness
configurations, 360 runs.  This driver adds PasClaw as another harness on the
same task definitions, with the `relay` provider standing in for the model
endpoint so an external operator answers each turn.

What it reproduces exactly
    * the instruction: `instruction.md` is sent verbatim as the user message
    * the environment: the container image named in the task's `task.toml`,
      pulled from the public registry the benchmark publishes
    * the repository state: whatever that image ships at `/app`, which is the
      upstream repo at the task's `base_commit_hash`
    * network posture: the container joins an `--internal` Docker network, so
      the agent has no route off-box.  The operator reaches the gateway over
      the bridge from the host, the same shape as the benchmark's
      "no-network agent, reachable model endpoint"
    * the artifact: the `[[verifier.collect]]` commands from `task.toml` run
      in the container and their outputs are copied out

What it cannot reproduce
    * the verifier.  The eval repository withholds solutions and verifiers by
      design, so this driver produces the artifact a verifier would score but
      never a pass/fail.  `fh_verify.py` runs locally-authored checks instead;
      those are ours, not the benchmark's, and must not be reported as a
      FrontierHarness score.
    * the model.  The published table is Kimi K3 through Fireworks on every
      row.  A relay operator is a different model, so a PasClaw number varies
      the axis the benchmark holds fixed and does not belong in that table.

Layout of a run directory
    run.json          task name, image, container, ports, timings
    instruction.md    copy of the prompt actually sent
    home/             PASCLAW_HOME mounted into the container
    spool/            fh_relay.py state
    artifacts/        files collected from the container
    gateway.log       gateway stdout from inside the container
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import tomllib
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
NETWORK = "fh-eval-internal"

# Directories PasClaw creates inside its workspace.  They are harness state,
# not part of any task's solution, so they are excluded from the task repo.
HARNESS_DIRS = ["agents/", "checkpoints/", "teams/", "skills/", "memory/",
                "sessions/", "projects/", "plans/"]


def sh(cmd, check=True, capture=True, **kw):
    r = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=capture, text=True, **kw)
    if check and r.returncode != 0:
        raise SystemExit("command failed (%d): %s\n%s" % (r.returncode, cmd, (r.stderr or "")[:2000]))
    return r


def load_task(tasks_dir, name):
    d = os.path.join(tasks_dir, name)
    with open(os.path.join(d, "task.toml"), "rb") as f:
        toml = tomllib.load(f)
    with open(os.path.join(d, "instruction.md")) as f:
        instruction = f.read()
    return toml, instruction


def run_state(run_dir, update=None):
    p = os.path.join(run_dir, "run.json")
    state = {}
    if os.path.exists(p):
        with open(p) as f:
            state = json.load(f)
    if update:
        state.update(update)
        with open(p, "w") as f:
            json.dump(state, f, indent=1)
    return state


# --------------------------------------------------------------------------
# up
# --------------------------------------------------------------------------


def ensure_network(internal=True):
    name = NETWORK if internal else NETWORK + "-open"
    r = sh(["docker", "network", "inspect", name], check=False)
    if r.returncode != 0:
        # --internal: no route off the host.  The bridge interface still
        # exists on the host side, so the operator can reach the gateway
        # while the agent itself cannot reach the internet.
        cmd = ["docker", "network", "create"]
        if internal:
            cmd.append("--internal")
        sh(cmd + [name])
    return name


def cmd_up(args):
    toml, instruction = load_task(args.tasks_dir, args.task)
    env = toml.get("environment", {})
    image = env.get("docker_image")
    if not image:
        raise SystemExit("task.toml has no environment.docker_image")

    run_dir = os.path.abspath(args.run_dir)
    for sub in ("home", "spool", "artifacts"):
        os.makedirs(os.path.join(run_dir, sub), exist_ok=True)
    with open(os.path.join(run_dir, "instruction.md"), "w") as f:
        f.write(instruction)

    binary = args.binary or os.path.join(REPO, "build", "pasclaw")
    if not os.path.exists(binary):
        raise SystemExit("pasclaw binary not found at %s (run `make`)" % binary)

    # Relay config: no api_key, no outbound endpoint.  `providers` must carry
    # the entry -- FindProvider scans that array, so naming a default_provider
    # that is not listed yields "no provider entry for ...".
    cfg = {
        "default_provider": "relay",
        "default_model": args.model,
        "providers": [{"name": "relay", "kind": "relay"}],
        "auto_router": {"enabled": False},
        "sandbox": {"shell_deny_enabled": False},
    }
    with open(os.path.join(run_dir, "home", "config.json"), "w") as f:
        json.dump(cfg, f, indent=1)

    print("pulling %s" % image)
    sh(["docker", "pull", image], capture=False)
    # The DeepSWE tasks declare `network_mode = "no-network"` for the agent;
    # the Terminal-Bench tasks declare nothing, and some of them need the
    # network to do their work at all.  Default to the stricter posture and
    # let the caller open it.
    network = ensure_network(internal=args.network == "internal")

    container = args.container or ("fh-%s" % args.task)
    sh(["docker", "rm", "-f", container], check=False)

    cpus = str(env.get("cpus", 2))
    mem = "%dm" % int(env.get("memory_mb", 8192))
    sh([
        "docker", "run", "-d", "--name", container,
        "--network", network,
        "--cpus", cpus, "--memory", mem,
        "-v", "%s:/opt/pasclaw:ro" % binary,
        "-v", "%s:/pasclaw-home" % os.path.join(run_dir, "home"),
        "-e", "PASCLAW_HOME=/pasclaw-home",
        image, "sleep", "infinity",
    ])

    ip = sh([
        "docker", "inspect", "-f",
        "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", container,
    ]).stdout.strip()
    base = "http://%s:%d" % (ip, args.port)

    # Point PasClaw's workspace at the task checkout.  PASCLAW_WORKSPACE names
    # a directory *under* PASCLAW_HOME rather than an absolute path, so the
    # way to put the agent in /app is to make that directory be /app.  Without
    # this the agent works in an empty scratch directory and the task's
    # collect command -- a git diff inside /app -- returns nothing.
    sh(["docker", "exec", container, "sh", "-lc",
        "rm -rf /pasclaw-home/workspace && ln -sfn %s /pasclaw-home/workspace"
        % args.workdir])

    # Keep the harness out of the task's diff.  PasClaw creates its own
    # scratch directories inside whatever it treats as the workspace, and the
    # collected artifact is a git diff of that same directory -- so without
    # this, an agent that runs `git add -A` commits harness droppings as part
    # of its solution.  .git/info/exclude is used rather than .gitignore
    # because .gitignore is a tracked file and editing it would itself show up
    # in the diff.
    sh(["docker", "exec", container, "sh", "-lc",
        "cd %s && test -d .git && printf '%%s\\n' %s >> .git/info/exclude || true"
        % (args.workdir, " ".join(HARNESS_DIRS))], check=False)

    # `serve`, not `gateway`: same TGatewayServer and the same /v1/chat and
    # /v1/relay/* routes, but it accepts --max-iter.  The gateway default of
    # 25 tool-loop iterations is far below these tasks -- the benchmark's own
    # metadata reports a median of 86 agent steps.
    sh([
        "docker", "exec", "-d", container, "sh", "-lc",
        "cd /app && /opt/pasclaw serve --addr 0.0.0.0 --port %d --max-iter %d "
        "> /pasclaw-home/gateway.log 2>&1" % (args.port, args.max_iter),
    ])

    for _ in range(120):
        try:
            with urllib.request.urlopen(base + "/v1/health", timeout=2):
                break
        except Exception:  # noqa: BLE001
            time.sleep(0.5)
    else:
        log = os.path.join(run_dir, "home", "gateway.log")
        tail = open(log).read()[-2000:] if os.path.exists(log) else "(no log)"
        raise SystemExit("gateway never became healthy at %s\n%s" % (base, tail))

    run_state(run_dir, {
        "task": args.task,
        "image": image,
        "container": container,
        "base": base,
        "port": args.port,
        "max_iter": args.max_iter,
        "model": args.model,
        "collect": toml.get("verifier", {}).get("collect", []),
        "artifacts": toml.get("artifacts", []),
        "workdir": args.workdir,
        "network": args.network,
        "created_at": time.time(),
    })

    spool = os.path.join(run_dir, "spool")
    sh([sys.executable, os.path.join(HERE, "fh_relay.py"), "--spool", spool,
        "start", "--base", base, "--worker-id", "fh-operator"], capture=False)

    print("\nrun ready: %s" % run_dir)
    print("  container %s at %s" % (container, base))
    print("  drive it with:")
    print("    %s %s/fh_relay.py --spool %s next" % (sys.executable, HERE, spool))
    print("    %s %s/fh_relay.py --spool %s respond --content ..." % (sys.executable, HERE, spool))
    return 0


# --------------------------------------------------------------------------
# ask / collect / down
# --------------------------------------------------------------------------


def cmd_ask(args):
    run_dir = os.path.abspath(args.run_dir)
    state = run_state(run_dir)
    with open(os.path.join(run_dir, "instruction.md")) as f:
        instruction = f.read()

    body = json.dumps({"message": instruction}).encode()
    out = os.path.join(run_dir, "chat-response.json")
    # Detached: /v1/chat blocks for the whole agent loop, which is the
    # operator's entire session.  The response lands in a file.
    proc = subprocess.Popen(
        [sys.executable, "-c",
         "import sys,urllib.request;"
         "r=urllib.request.Request(sys.argv[1],data=sys.stdin.buffer.read(),"
         "headers={'Content-Type':'application/json'},method='POST');"
         "open(sys.argv[2],'w').write(urllib.request.urlopen(r,timeout=%d).read().decode())"
         % args.timeout,
         state["base"] + "/v1/chat", out],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=open(
            os.path.join(run_dir, "chat-error.log"), "w"),
        start_new_session=True,
    )
    proc.stdin.write(body)
    proc.stdin.close()
    run_state(run_dir, {"asked_at": time.time(), "chat_pid": proc.pid})
    print("instruction sent (%d chars); response will land in %s" % (len(instruction), out))
    print("now service turns with fh_relay.py next / respond")
    return 0


def cmd_collect(args):
    run_dir = os.path.abspath(args.run_dir)
    state = run_state(run_dir)
    container = state["container"]
    art_dir = os.path.join(run_dir, "artifacts")

    # The 21 Terminal-Bench tasks declare no artifacts and no collect step:
    # everything they are scored on happens inside the withheld verifier,
    # which runs against the container's final state.  There is nothing to
    # copy out, so record what the agent actually changed instead -- both a
    # git diff when the workdir is a repo, and the container's own changed
    # -path list, which covers work outside any repo.
    if not state.get("collect") and not state.get("artifacts"):
        workdir = state.get("workdir", "/app")
        sh(["docker", "exec", container, "sh", "-lc",
            "git config --global --add safe.directory %s" % workdir], check=False)
        r = sh(["docker", "exec", "-w", workdir, container, "sh", "-lc",
                "git diff --binary HEAD 2>/dev/null"], check=False)
        if r.stdout:
            with open(os.path.join(art_dir, "workdir.patch"), "w") as f:
                f.write(r.stdout)
            print("no collect step; wrote workdir.patch (%d bytes)" % len(r.stdout))
        r = sh(["docker", "diff", container], check=False)
        # Drop the harness's own footprint so the record shows what the agent
        # changed, not where PasClaw was mounted and what it scratched.
        noise = ["/pasclaw-home", "/opt/pasclaw"] + [
            "%s/%s" % (workdir.rstrip("/"), d.rstrip("/")) for d in HARNESS_DIRS]
        lines = [
            ln for ln in (r.stdout or "").splitlines()
            if not any(ln[2:] == p or ln[2:].startswith(p + "/") for p in noise)
        ]
        with open(os.path.join(art_dir, "container-diff.txt"), "w") as f:
            f.write("\n".join(lines) + ("\n" if lines else ""))
        print("no collect step; wrote container-diff.txt (%d lines)" % len(lines))
        run_state(run_dir, {"collected_at": time.time(), "collect_results": []})
        return 0

    results = []
    for step in state.get("collect", []):
        cmd = step["command"]
        r = sh(["docker", "exec", container, "sh", "-lc", cmd], check=False)
        results.append({"command": cmd, "exit": r.returncode,
                        "stderr": (r.stderr or "")[:2000]})
        print("collect exit=%d: %s" % (r.returncode, cmd[:100]))
    for path in state.get("artifacts", []):
        dest = os.path.join(art_dir, os.path.basename(path))
        r = sh(["docker", "cp", "%s:%s" % (container, path), dest], check=False)
        if r.returncode == 0:
            print("artifact %s -> %s (%d bytes)" % (path, dest, os.path.getsize(dest)))
        else:
            print("artifact %s NOT produced" % path)
    run_state(run_dir, {"collected_at": time.time(), "collect_results": results})
    return 0


def cmd_down(args):
    run_dir = os.path.abspath(args.run_dir)
    state = run_state(run_dir)
    spool = os.path.join(run_dir, "spool")
    sh([sys.executable, os.path.join(HERE, "fh_relay.py"), "--spool", spool, "stop"],
       check=False, capture=False)
    log = os.path.join(run_dir, "home", "gateway.log")
    if os.path.exists(log):
        shutil.copyfile(log, os.path.join(run_dir, "gateway.log"))
    if state.get("container") and not args.keep:
        sh(["docker", "rm", "-f", state["container"]], check=False)
        print("container removed")
    return 0


def cmd_report(args):
    run_dir = os.path.abspath(args.run_dir)
    state = run_state(run_dir)
    spool = os.path.join(run_dir, "spool")
    jobs_dir = os.path.join(spool, "jobs")
    jobs = sorted(os.listdir(jobs_dir)) if os.path.isdir(jobs_dir) else []
    answers = []
    ans_dir = os.path.join(spool, "answered")
    if os.path.isdir(ans_dir):
        for n in os.listdir(ans_dir):
            try:
                answers.append(json.load(open(os.path.join(ans_dir, n))))
            except ValueError:
                pass
    tool_calls = sum(len(a.get("tool_calls") or []) for a in answers)
    rep = {
        "task": state.get("task"),
        "harness": "pasclaw",
        "model": state.get("model"),
        "turns": len(jobs),
        "tool_calls": tool_calls,
        "wall_seconds": round((state.get("collected_at") or time.time())
                              - (state.get("asked_at") or state.get("created_at", 0)), 1),
        "artifact_bytes": {
            n: os.path.getsize(os.path.join(run_dir, "artifacts", n))
            for n in sorted(os.listdir(os.path.join(run_dir, "artifacts")))
        } if os.path.isdir(os.path.join(run_dir, "artifacts")) else {},
        "scored": False,
        "score_note": "FrontierHarness withholds its verifiers; this run is unscored by the benchmark.",
    }
    print(json.dumps(rep, indent=1))
    with open(os.path.join(run_dir, "report.json"), "w") as f:
        json.dump(rep, f, indent=1)
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("up", help="start the task container and gateway")
    s.add_argument("--task", required=True)
    s.add_argument("--tasks-dir", required=True, help="tasks/ from the eval repo")
    s.add_argument("--run-dir", required=True)
    s.add_argument("--binary", help="pasclaw binary (default build/pasclaw)")
    s.add_argument("--container")
    s.add_argument("--port", type=int, default=8400)
    s.add_argument("--max-iter", type=int, default=200)
    s.add_argument("--model", default="relay-operator")
    s.add_argument("--workdir", default="/app",
                   help="directory in the image the agent works in")
    s.add_argument("--network", choices=("internal", "bridge"), default="internal",
                   help="internal: agent has no route off-box (default). "
                        "bridge: agent has internet, for tasks that need it")
    s.set_defaults(fn=cmd_up)

    s = sub.add_parser("ask", help="send instruction.md as the user message")
    s.add_argument("--run-dir", required=True)
    s.add_argument("--timeout", type=int, default=21600)
    s.set_defaults(fn=cmd_ask)

    s = sub.add_parser("collect", help="run task.toml collect commands, copy artifacts out")
    s.add_argument("--run-dir", required=True)
    s.set_defaults(fn=cmd_collect)

    s = sub.add_parser("report", help="summarise the run")
    s.add_argument("--run-dir", required=True)
    s.set_defaults(fn=cmd_report)

    s = sub.add_parser("down", help="stop the relay and remove the container")
    s.add_argument("--run-dir", required=True)
    s.add_argument("--keep", action="store_true", help="leave the container running")
    s.set_defaults(fn=cmd_down)

    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
