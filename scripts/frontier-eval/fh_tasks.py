#!/usr/bin/env python3
"""Fetch and inspect the FrontierHarness Eval task set.

The benchmark repository is data only -- an instruction and a task.toml per
task, plus published results.  This fetches it and answers the questions you
need before starting a run: which tasks exist, what language and image each
needs, how hard the benchmark found them, and how much image download a run
implies.

    fetch    clone or update the eval repository
    list     one line per task
    show     a task's metadata and instruction
    images   image sizes, without pulling
"""

import argparse
import json
import os
import subprocess
import sys
import tomllib

EVAL_REPO = "https://github.com/frontier-harness-eval/eval.git"


def sh(cmd, check=True, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if check and r.returncode != 0:
        raise SystemExit("failed: %s\n%s" % (" ".join(cmd), r.stderr[:1000]))
    return r


def cmd_fetch(args):
    dest = os.path.abspath(args.dest)
    if os.path.isdir(os.path.join(dest, ".git")):
        sh(["git", "-C", dest, "fetch", "--depth", "1", "origin"])
        sh(["git", "-C", dest, "reset", "--hard", "origin/HEAD"], check=False)
        print("updated %s" % dest)
    else:
        sh(["git", "clone", "--depth", "1", EVAL_REPO, dest])
        print("cloned %s" % dest)
    tasks = os.path.join(dest, "tasks")
    print("%d tasks in %s" % (len(os.listdir(tasks)), tasks))
    return 0


def load(dest, name):
    with open(os.path.join(dest, "tasks", name, "task.toml"), "rb") as f:
        return tomllib.load(f)


def difficulty_map(dest):
    path = os.path.join(dest, "metadata", "difficulty.json")
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        data = json.load(f)
    out = {}
    for key in ("deep_swe", "terminal_bench"):
        for row in data.get(key, []) or []:
            out[row["task"]] = row
    return out


def cmd_list(args):
    dest = os.path.abspath(args.dest)
    diff = difficulty_map(dest)
    names = sorted(os.listdir(os.path.join(dest, "tasks")))
    print("%-46s %-12s %-8s %s" % ("task", "language", "hard", "steps"))
    for name in names:
        toml = load(dest, name)
        meta = toml.get("metadata", {})
        d = diff.get(name, {})
        if args.language and meta.get("language", "") != args.language:
            continue
        print("%-46s %-12s %-8s %s" % (
            name, meta.get("language", "?"),
            d.get("difficulty", "-"),
            d.get("median_agent_steps", "-")))
    return 0


def cmd_show(args):
    dest = os.path.abspath(args.dest)
    toml = load(dest, args.task)
    print(json.dumps(toml, indent=1, default=str))
    print("\n--- instruction.md ---")
    with open(os.path.join(dest, "tasks", args.task, "instruction.md")) as f:
        print(f.read())
    return 0


def cmd_images(args):
    dest = os.path.abspath(args.dest)
    names = sorted(os.listdir(os.path.join(dest, "tasks")))
    total = 0
    for name in names:
        image = load(dest, name).get("environment", {}).get("docker_image", "")
        if not image:
            print("%-46s (no image)" % name)
            continue
        # manifest inspect talks to the registry directly and needs no daemon.
        r = sh(["docker", "manifest", "inspect", image], check=False)
        if r.returncode != 0:
            print("%-46s unreachable" % name)
            continue
        size = sum(l["size"] for l in json.loads(r.stdout).get("layers", []))
        total += size
        print("%-46s %6.2f GB" % (name, size / 1e9))
    print("%-46s %6.2f GB compressed" % ("TOTAL", total / 1e9))
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--dest", default="frontier-eval-tasks",
                   help="where the eval repository lives")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("fetch"); s.set_defaults(fn=cmd_fetch)
    s = sub.add_parser("list")
    s.add_argument("--language")
    s.set_defaults(fn=cmd_list)
    s = sub.add_parser("show")
    s.add_argument("task")
    s.set_defaults(fn=cmd_show)
    s = sub.add_parser("images"); s.set_defaults(fn=cmd_images)

    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
