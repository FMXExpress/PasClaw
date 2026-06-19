#!/usr/bin/env python3
"""
probe_first_turn.py - measure PasClaw's first-turn request shape.

Most of the deltas between `stock` and `max-build` toggle prompt-side
state -- they register more tools, lengthen the system prompt, expand
the per-turn payload. Those changes are observable on the VERY FIRST
request PasClaw makes, before any agent reasoning happens. We don't
need to drive the loop to measure them.

This probe:

  1. Stages a fixture into a fresh workspace.
  2. Starts the stub in --blocking mode.
  3. Starts `pasclaw build` with the variant's profile / overrides.
  4. Waits for req_1.json to appear (the first /v1/chat/completions
     call), captures size + tool count + system-prompt length.
  5. Kills pasclaw and the stub, cleans up.

Output (one line of JSON on stdout):

    {
      "variant_id": "...",
      "req_bytes": 18432,
      "n_messages": 2,
      "n_tools": 13,
      "tool_names": ["fs_read", "fs_write", ...],
      "system_chars": 4920,
      "system_tokens_est": 1230,
      "user_chars": 480,
      "elapsed_s": 1.4
    }

Per-cell cost: ~2-3 seconds. Run dozens of variants in a minute.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import shutil
from pathlib import Path


HARNESS_DIR = Path(__file__).resolve().parent
BENCH_ROOT = HARNESS_DIR.parent
REPO_ROOT = BENCH_ROOT.parent.parent
PASCLAW_BIN = REPO_ROOT / "build" / "pasclaw"


def stage_workspace(fixture_dir: Path, workspace: Path) -> None:
    pre = fixture_dir / "pre-fix"
    if not pre.exists():
        return
    for src in pre.rglob("*"):
        if src.is_dir():
            continue
        rel = src.relative_to(pre)
        dst = workspace / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


def write_config(home: Path, port: int, variant: dict) -> None:
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
    cfg.update(variant.get("config_overrides", {}))
    home.mkdir(parents=True, exist_ok=True)
    (home / "config.json").write_text(json.dumps(cfg, indent=2), encoding="utf-8")


def build_argv(variant: dict, prompt: str, workspace: Path) -> list[str]:
    argv = [
        str(PASCLAW_BIN), "--no-color", "build",
        "-d", prompt,
        "--cwd", str(workspace),
        "--provider", "stub", "--model", "stub",
        "--max-iters", str(variant.get("max_iters", 20)),
    ]
    if variant.get("profile"): argv += ["--profile", variant["profile"]]
    if variant.get("mode"):    argv += ["--mode",    variant["mode"]]
    if variant.get("no_tools"): argv += ["--no-tools"]
    if variant.get("no_mcp"):   argv += ["--no-mcp"]
    if variant.get("system_prompt"):
        argv += ["--system", variant["system_prompt"]]
    return argv


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--fixture", required=True, type=Path)
    ap.add_argument("--variant", required=True,
                    help="variant JSON or @path/to/variant.json")
    ap.add_argument("--timeout-s", type=int, default=15)
    args = ap.parse_args()

    if args.variant.startswith("@"):
        variant = json.loads(Path(args.variant[1:]).read_text(encoding="utf-8"))
    else:
        variant = json.loads(args.variant)
    fixture = json.loads((args.fixture / "manifest.json").read_text(encoding="utf-8"))

    work_root = Path(tempfile.mkdtemp(prefix="probe-"))
    try:
        home = work_root / "home"
        workspace = work_root / "ws"
        queue = work_root / "queue"
        queue.mkdir(parents=True)
        workspace.mkdir(parents=True)
        stage_workspace(args.fixture, workspace)

        # Start the blocking stub
        stub = subprocess.Popen(
            [sys.executable, str(HARNESS_DIR / "provider_stub.py"),
             "--blocking", str(queue), "--blocking-timeout-s", "60"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True,
        )
        line = stub.stdout.readline().strip()
        if not line.startswith("PORT="):
            stub.terminate()
            sys.exit("stub failed to bind: " + line)
        port = int(line.split("=", 1)[1])

        write_config(home, port, variant)
        argv = build_argv(variant, fixture["prompt"], workspace)
        env = os.environ.copy()
        env["PASCLAW_HOME"] = str(home)
        env["NO_COLOR"] = "1"
        pasclaw = subprocess.Popen(
            argv, env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )

        t0 = time.monotonic()
        req_path = queue / "req_1.json"
        while time.monotonic() - t0 < args.timeout_s:
            if req_path.exists():
                break
            if pasclaw.poll() is not None:
                # Pasclaw exited without ever sending a request (likely an
                # error during config / profile / provider lookup).
                stub.terminate()
                sys.exit("pasclaw exited before first turn (rc=%d)"
                         % pasclaw.returncode)
            time.sleep(0.1)
        elapsed = time.monotonic() - t0

        if not req_path.exists():
            pasclaw.send_signal(signal.SIGTERM)
            stub.terminate()
            sys.exit("timeout: no first request after %ds" % args.timeout_s)

        req_body = req_path.read_bytes()
        req = json.loads(req_body)
        msgs = req.get("messages") or []
        tools = req.get("tools") or []
        sys_msg = next((m for m in msgs if m.get("role") == "system"), None)
        user_msg = next((m for m in msgs if m.get("role") == "user"), None)
        sys_str = (sys_msg or {}).get("content") or ""
        user_str = (user_msg or {}).get("content") or ""

        pasclaw.send_signal(signal.SIGTERM)
        try: pasclaw.wait(timeout=2)
        except subprocess.TimeoutExpired: pasclaw.kill()
        stub.terminate()
        try: stub.wait(timeout=2)
        except subprocess.TimeoutExpired: stub.kill()

        out = {
            "variant_id": variant.get("id", "anon"),
            "fixture": fixture["name"],
            "req_bytes": len(req_body),
            "n_messages": len(msgs),
            "n_tools": len(tools),
            "tool_names": sorted(
                [(t.get("function") or {}).get("name", "?") for t in tools]
            ),
            "system_chars": len(sys_str),
            "system_tokens_est": max(1, len(sys_str) // 4),
            "user_chars": len(user_str),
            "elapsed_s": round(elapsed, 2),
        }
        sys.stdout.write(json.dumps(out) + "\n")
        return 0
    finally:
        shutil.rmtree(work_root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
