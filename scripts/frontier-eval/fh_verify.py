#!/usr/bin/env python3
"""Locally-authored acceptance checks for a FrontierHarness Eval run.

FrontierHarness withholds its verifiers and reference solutions on purpose, so
nothing here can produce a benchmark score.  What it can do is answer the two
questions the artifact alone does not:

    build   does the repository still compile after the agent's change?
    tests   does the repository's own suite still pass?

Both run inside the task container, on the tree the agent left behind, using
the toolchain the image ships.  A green result is evidence the change is not
broken; it is not evidence the change is correct, because the tests that would
decide correctness are the ones the benchmark keeps private.  Report it as
"build and existing tests pass", never as a pass rate.

The command for each language comes from `[metadata].language` in task.toml.
Override with --build/--test when a task needs something else.
"""

import argparse
import json
import os
import subprocess
import sys
import time

LANG_COMMANDS = {
    "go": {"build": "go build ./...", "test": "go test ./..."},
    "python": {"build": "python -m compileall -q .", "test": "python -m pytest -q"},
    "javascript": {"build": "npm run build --if-present", "test": "npm test"},
    "typescript": {"build": "npm run build --if-present", "test": "npm test"},
    "rust": {"build": "cargo build", "test": "cargo test"},
    "c": {"build": "make", "test": "make test"},
}


def run_in(container, workdir, cmd, timeout):
    started = time.time()
    try:
        r = subprocess.run(
            ["docker", "exec", "-w", workdir, container, "sh", "-lc", cmd],
            capture_output=True, text=True, timeout=timeout,
        )
        out, code = (r.stdout or "") + (r.stderr or ""), r.returncode
    except subprocess.TimeoutExpired:
        out, code = "timed out after %ss" % timeout, 124
    return {
        "command": cmd,
        "exit": code,
        "seconds": round(time.time() - started, 1),
        # Tails, not heads: a failing build reports its errors last.
        "output_tail": out[-4000:],
    }


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--run-dir", required=True)
    p.add_argument("--tasks-dir", help="eval repo tasks/, to read the language")
    p.add_argument("--workdir", default="/app")
    p.add_argument("--build", help="override the build command")
    p.add_argument("--test", help="override the test command")
    p.add_argument("--timeout", type=int, default=1800)
    args = p.parse_args(argv)

    run_dir = os.path.abspath(args.run_dir)
    with open(os.path.join(run_dir, "run.json")) as f:
        state = json.load(f)
    container = state["container"]

    language = ""
    if args.tasks_dir:
        import tomllib
        toml_path = os.path.join(args.tasks_dir, state["task"], "task.toml")
        with open(toml_path, "rb") as f:
            language = tomllib.load(f).get("metadata", {}).get("language", "")

    defaults = LANG_COMMANDS.get(language.lower(), {})
    build_cmd = args.build or defaults.get("build")
    test_cmd = args.test or defaults.get("test")
    if not build_cmd and not test_cmd:
        raise SystemExit(
            "no commands for language %r; pass --build and/or --test" % language)

    result = {
        "task": state["task"],
        "language": language,
        "scored_by_benchmark": False,
        "note": "FrontierHarness withholds its verifiers. These are local "
                "build and regression checks, not a benchmark score.",
        "checks": {},
    }
    for name, cmd in (("build", build_cmd), ("tests", test_cmd)):
        if not cmd:
            continue
        print("running %s: %s" % (name, cmd))
        result["checks"][name] = run_in(container, args.workdir, cmd, args.timeout)
        print("  exit=%d in %ss" % (result["checks"][name]["exit"],
                                    result["checks"][name]["seconds"]))

    result["all_passed"] = all(c["exit"] == 0 for c in result["checks"].values())
    with open(os.path.join(run_dir, "verify.json"), "w") as f:
        json.dump(result, f, indent=1)
    print(json.dumps({k: v for k, v in result.items() if k != "checks"}, indent=1))
    return 0 if result["all_passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
