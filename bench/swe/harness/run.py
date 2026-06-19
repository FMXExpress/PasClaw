#!/usr/bin/env python3
"""
run.py - drive one (task x variant) through PasClaw and score the result.

The full sweep is just `score.py` calling this for every cell. See README.

Each run goes through five phases:

  1. Materialise a fresh PASCLAW_HOME tempdir + workspace cwd, copying the
     fixture's pre-fix tree into the workspace.
  2. Build a one-shot PasClaw config.json that pins the OpenAI-shaped
     provider at our localhost stub, applies the variant's profile, and
     leaves every other field at TConfig defaults.
  3. Spawn provider_stub.py in the background. It binds to a random port
     and prints PORT=N on stdout; we wait for that line then patch the
     config with the port. The stub's stderr is captured for metrics.
  4. Run `pasclaw build -d <prompt> --max-iters N --provider stub ...`
     against the workspace, with a hard wall-clock timeout. Save stdout
     (the final assistant reply), session log path, and exit code.
  5. Run the fixture's oracle command in the workspace. Pass/fail is the
     exit code. Combine with per-turn metrics from the stub log into a
     single result.json under results/run-<id>/.

The harness is provider-agnostic at the metric level: as long as
provider_stub.py emits one `{"event":"turn",...}` line per call (it does
for both --mock and --proxy modes), the result is comparable across
sweep cells.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Optional


REPO_ROOT = Path(__file__).resolve().parents[2].parent
BENCH_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PASCLAW_BIN = REPO_ROOT / "build" / "pasclaw"


# --------------------------------------------------------------------------- #
# Fixture                                                                     #
# --------------------------------------------------------------------------- #


def load_fixture(path: Path) -> dict:
    """Read a fixture's manifest.json and return it with `path` resolved
    to an absolute string -- the oracle runs from a different cwd."""
    manifest_path = path / "manifest.json"
    with open(manifest_path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)
    manifest["__fixture_dir"] = str(path.resolve())
    return manifest


def stage_workspace(fixture: dict, workspace: Path) -> None:
    """Copy fixture/pre-fix/** into the workspace cwd.

    The pre-fix tree mirrors the layout the agent should see at task start.
    Files NOT under pre-fix/ are not staged -- the agent only sees what the
    fixture explicitly provides, which keeps the experiment deterministic
    even when the surrounding bench/ source tree evolves."""
    pre = Path(fixture["__fixture_dir"]) / "pre-fix"
    if not pre.exists():
        return
    for src in pre.rglob("*"):
        if src.is_dir():
            continue
        rel = src.relative_to(pre)
        dst = workspace / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


# --------------------------------------------------------------------------- #
# Provider stub lifecycle                                                     #
# --------------------------------------------------------------------------- #


def start_stub(mode_args: list[str], log_path: Path) -> tuple[subprocess.Popen, int]:
    """Spawn provider_stub.py, return (process, bound_port).

    Stderr -> log_path so run.py can parse the per-turn events after
    pasclaw exits."""
    stub = Path(__file__).with_name("provider_stub.py")
    cmd = [sys.executable, str(stub), *mode_args]
    log_fh = open(log_path, "wb")
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=log_fh,
        bufsize=1,
        text=True,
    )
    # First line on stdout is "PORT=N\n".
    line = proc.stdout.readline().strip()
    if not line.startswith("PORT="):
        proc.terminate()
        raise RuntimeError("provider_stub did not announce port: " + repr(line))
    port = int(line.split("=", 1)[1])
    # We're done reading stdout; the stub doesn't print anything else there.
    return proc, port


def stop_stub(proc: subprocess.Popen) -> None:
    if proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2)


# --------------------------------------------------------------------------- #
# PasClaw config + invocation                                                 #
# --------------------------------------------------------------------------- #


def write_pasclaw_config(home: Path, port: int, variant: dict) -> None:
    """Write a config.json that points PasClaw's OpenAI provider at the
    localhost stub. Profile is left blank; --profile on the CLI handles it
    (avoids accidentally inheriting an operator-side default)."""
    cfg = {
        "providers": [{
            "name": "stub",
            "kind": "openai",
            "api_key": "sk-bench-stub",
            "api_base": "http://127.0.0.1:%d" % port,
            "model": "stub",
        }],
        "default_provider": "stub",
    }
    # Variant-specific overrides applied as a shallow merge so a sweep cell
    # can toggle any TConfig field directly without going through a profile.
    cfg.update(variant.get("config_overrides", {}))
    home.mkdir(parents=True, exist_ok=True)
    (home / "config.json").write_text(json.dumps(cfg, indent=2), encoding="utf-8")


def build_pasclaw_argv(
    pasclaw_bin: Path,
    task_prompt: str,
    workspace: Path,
    variant: dict,
) -> list[str]:
    argv = [
        str(pasclaw_bin),
        "--no-color",
        "build",
        "-d", task_prompt,
        "--cwd", str(workspace),
        "--provider", "stub",
        "--model", "stub",
        "--max-iters", str(variant.get("max_iters", 20)),
    ]
    if variant.get("profile"):
        argv += ["--profile", variant["profile"]]
    if variant.get("mode"):
        argv += ["--mode", variant["mode"]]
    if variant.get("no_tools"):
        argv += ["--no-tools"]
    if variant.get("no_mcp"):
        argv += ["--no-mcp"]
    if variant.get("system_prompt"):
        argv += ["--system", variant["system_prompt"]]
    return argv


def run_pasclaw(
    argv: list[str],
    home: Path,
    timeout_s: int,
) -> tuple[int, str, str]:
    env = os.environ.copy()
    env["PASCLAW_HOME"] = str(home)
    # Disable colored output everywhere -- nicer in result.json logs.
    env["NO_COLOR"] = "1"
    try:
        completed = subprocess.run(
            argv, env=env,
            capture_output=True, text=True,
            timeout=timeout_s,
        )
        return completed.returncode, completed.stdout, completed.stderr
    except subprocess.TimeoutExpired as e:
        return 124, e.stdout or "", (e.stderr or "") + "\n[harness] TIMEOUT after %ds" % timeout_s


# --------------------------------------------------------------------------- #
# Oracle                                                                      #
# --------------------------------------------------------------------------- #


def run_oracle(fixture: dict, workspace: Path, timeout_s: int) -> dict:
    """Run the fixture's oracle command, return {passed, exit_code, stdout, stderr}.

    The oracle runs from the workspace cwd (so its checks resolve against
    files the agent actually edited). The oracle.cmd string can reference
    $FIXTURE_DIR for paths into the fixture tree (e.g. the test.sh script
    itself lives there, not in the workspace where the agent could see it
    and contaminate the trajectory)."""
    oracle = fixture.get("oracle") or {}
    cmd = oracle.get("cmd")
    if not cmd:
        return {"passed": None, "exit_code": None,
                "stdout": "", "stderr": "fixture has no oracle.cmd"}
    env = os.environ.copy()
    env["FIXTURE_DIR"] = fixture["__fixture_dir"]
    env["WORKSPACE"] = str(workspace)
    try:
        completed = subprocess.run(
            cmd, shell=True, cwd=str(workspace),
            env=env,
            capture_output=True, text=True, timeout=timeout_s,
        )
        return {
            "passed": completed.returncode == 0,
            "exit_code": completed.returncode,
            "stdout": completed.stdout[-2000:],
            "stderr": completed.stderr[-2000:],
        }
    except subprocess.TimeoutExpired as e:
        return {
            "passed": False, "exit_code": 124,
            "stdout": (e.stdout or "")[-2000:],
            "stderr": ((e.stderr or "") + "\n[harness] oracle TIMEOUT")[-2000:],
        }


# --------------------------------------------------------------------------- #
# Stub log -> metrics                                                         #
# --------------------------------------------------------------------------- #


def parse_stub_log(log_path: Path) -> dict:
    turns = []
    if log_path.exists():
        for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("event") == "turn":
                turns.append(obj)
    return {
        "turn_count": len(turns),
        "tokens_in": sum(t.get("tokens_in", 0) for t in turns),
        "tokens_out": sum(t.get("tokens_out", 0) for t in turns),
        "tool_calls": sum(t.get("tool_calls", 0) for t in turns),
        "total_elapsed_ms": sum(t.get("elapsed_ms", 0) for t in turns),
    }


# --------------------------------------------------------------------------- #
# Out-of-scope edits                                                          #
# --------------------------------------------------------------------------- #


def count_oos_edits(fixture: dict, workspace: Path) -> int:
    """Files the agent wrote that fall OUTSIDE the fixture's scope_paths
    allowlist. Reported as a soft metric; the harness never blocks on it."""
    scope = fixture.get("scope_paths") or []
    if not scope:
        return 0
    pre = Path(fixture["__fixture_dir"]) / "pre-fix"
    pre_files = {
        str(p.relative_to(pre)) for p in pre.rglob("*") if p.is_file()
    } if pre.exists() else set()
    in_scope_prefixes = tuple(scope)
    oos = 0
    for p in workspace.rglob("*"):
        if not p.is_file():
            continue
        rel = str(p.relative_to(workspace))
        if rel in pre_files:
            continue  # the agent edited an existing in-scope file
        if rel.startswith(in_scope_prefixes):
            continue
        oos += 1
    return oos


# --------------------------------------------------------------------------- #
# Main                                                                        #
# --------------------------------------------------------------------------- #


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--fixture", required=True, type=Path)
    ap.add_argument("--variant", required=True,
                    help="variant JSON (string) or @path/to/variant.json")
    ap.add_argument("--pasclaw-bin", type=Path, default=DEFAULT_PASCLAW_BIN)
    ap.add_argument("--results-dir", type=Path,
                    default=BENCH_ROOT / "results")
    ap.add_argument("--run-id", default=None,
                    help="override the auto-generated run id")
    ap.add_argument("--timeout-pasclaw", type=int, default=300)
    ap.add_argument("--timeout-oracle", type=int, default=60)

    stub_mode = ap.add_mutually_exclusive_group(required=True)
    stub_mode.add_argument("--mock", metavar="TRANSCRIPT_JSONL",
                           help="provider stub replays from this file")
    stub_mode.add_argument("--proxy", metavar="BASE_URL",
                           help="provider stub forwards to this upstream")
    stub_mode.add_argument("--blocking", metavar="QUEUE_DIR",
                           help="file-FIFO mode for live driving")
    ap.add_argument("--record", metavar="TRANSCRIPT_JSONL",
                    help="record the proxied transcript (proxy mode only)")
    args = ap.parse_args()

    # Variant payload
    if args.variant.startswith("@"):
        variant = json.loads(Path(args.variant[1:]).read_text(encoding="utf-8"))
    else:
        variant = json.loads(args.variant)

    fixture = load_fixture(args.fixture)

    run_id = args.run_id or "%s-%s" % (
        time.strftime("%Y%m%dT%H%M%S"), uuid.uuid4().hex[:6])
    run_dir = args.results_dir / ("run-" + run_id)
    run_dir.mkdir(parents=True, exist_ok=True)

    pasclaw_home = run_dir / "pasclaw-home"
    workspace = run_dir / "workspace"
    workspace.mkdir(parents=True, exist_ok=True)
    stub_log = run_dir / "stub.log"

    stage_workspace(fixture, workspace)

    # Build stub argv
    stub_args = []
    if args.mock:
        stub_args = ["--mock", str(Path(args.mock).resolve())]
    elif args.blocking:
        stub_args = ["--blocking", str(Path(args.blocking).resolve())]
    else:
        stub_args = ["--proxy", args.proxy]
    if args.record:
        stub_args += ["--record", str(Path(args.record).resolve())]

    stub_proc, port = start_stub(stub_args, stub_log)
    write_pasclaw_config(pasclaw_home, port, variant)

    try:
        argv = build_pasclaw_argv(
            pasclaw_bin=args.pasclaw_bin,
            task_prompt=fixture["prompt"],
            workspace=workspace,
            variant=variant,
        )
        t0 = time.monotonic()
        rc, stdout, stderr = run_pasclaw(argv, pasclaw_home, args.timeout_pasclaw)
        wall_s = time.monotonic() - t0
    finally:
        stop_stub(stub_proc)

    (run_dir / "pasclaw.stdout").write_text(stdout, encoding="utf-8")
    (run_dir / "pasclaw.stderr").write_text(stderr, encoding="utf-8")
    (run_dir / "argv.json").write_text(json.dumps(argv, indent=2), encoding="utf-8")

    metrics = parse_stub_log(stub_log)
    oracle = run_oracle(fixture, workspace, args.timeout_oracle)
    oos = count_oos_edits(fixture, workspace)

    result = {
        "run_id": run_id,
        "fixture": fixture["name"],
        "variant": variant,
        "passed": oracle["passed"],
        "pasclaw_exit_code": rc,
        "wall_clock_s": round(wall_s, 2),
        "metrics": metrics,
        "oos_edits": oos,
        "oracle": oracle,
    }
    (run_dir / "result.json").write_text(json.dumps(result, indent=2),
                                          encoding="utf-8")
    # Echo to stdout for `score.py` to slurp.
    sys.stdout.write(json.dumps(result) + "\n")
    return 0 if oracle["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
