#!/usr/bin/env python3
"""
turn_growth.py - measure per-turn request growth across variants.

The first-turn probe shows how big the prompt+tools are. This script
shows how the WHOLE conversation grows turn-by-turn — message
accumulation, tool-result blobs, etc. — which is where condenser /
output cap pay off (or don't).

Method:

  1. Run a fixture with the standard mock transcript (read, write, done).
  2. Stub logs per-turn metrics including req_bytes (added in this commit).
  3. For each variant, tabulate req_bytes[1..N] and compute growth slope.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


HARNESS_DIR = Path(__file__).resolve().parent
BENCH_ROOT = HARNESS_DIR.parent
REPO_ROOT = BENCH_ROOT.parent.parent
PASCLAW_BIN = REPO_ROOT / "build" / "pasclaw"


def run_variant(fixture_dir: Path, variant: dict, mock_path: Path,
                timeout_s: int = 60) -> dict:
    """Run one fixture x variant with the mock transcript. Return per-turn
    growth data parsed from the stub's event log."""
    work = Path(tempfile.mkdtemp(prefix="growth-"))
    try:
        home = work / "home"; home.mkdir()
        ws = work / "ws";   ws.mkdir()
        # Stage fixture
        pre = fixture_dir / "pre-fix"
        if pre.exists():
            for src in pre.rglob("*"):
                if src.is_dir(): continue
                rel = src.relative_to(pre)
                dst = ws / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)

        # Start stub in mock mode
        stub_log = work / "stub.log"
        stub = subprocess.Popen(
            [sys.executable, str(HARNESS_DIR / "provider_stub.py"),
             "--mock", str(mock_path.resolve())],
            stdout=subprocess.PIPE,
            stderr=open(stub_log, "wb"),
            text=True,
        )
        line = stub.stdout.readline().strip()
        port = int(line.split("=", 1)[1])

        cfg = {
            "providers": [{
                "name": "stub", "kind": "openai",
                "api_key": "sk-bench-stub",
                "api_base": "http://127.0.0.1:%d" % port,
                "model": "stub",
            }],
            "default_provider": "stub",
        }
        cfg.update(variant.get("config_overrides", {}))
        (home / "config.json").write_text(json.dumps(cfg))

        fixture = json.loads((fixture_dir / "manifest.json").read_text())
        argv = [
            str(PASCLAW_BIN), "--no-color", "build",
            "-d", fixture["prompt"],
            "--cwd", str(ws),
            "--provider", "stub", "--model", "stub",
            "--max-iters", str(variant.get("max_iters", 20)),
        ]
        if variant.get("profile"): argv += ["--profile", variant["profile"]]
        if variant.get("mode"):    argv += ["--mode",    variant["mode"]]

        env = os.environ.copy()
        env["PASCLAW_HOME"] = str(home); env["NO_COLOR"] = "1"
        completed = subprocess.run(argv, env=env,
            capture_output=True, text=True, timeout=timeout_s)

        stub.terminate()
        try: stub.wait(timeout=2)
        except subprocess.TimeoutExpired: stub.kill()

        turns = []
        for ln in stub_log.read_text(encoding="utf-8", errors="replace").splitlines():
            ln = ln.strip()
            if not ln: continue
            try: obj = json.loads(ln)
            except json.JSONDecodeError: continue
            if obj.get("event") == "turn":
                turns.append({
                    "turn": obj["turn"],
                    "req_bytes": obj.get("req_bytes", 0),
                    "resp_bytes": obj.get("resp_bytes", 0),
                    "tool_calls": obj.get("tool_calls", 0),
                })
        return {
            "variant_id": variant.get("id", "?"),
            "turns": turns,
            "n_turns": len(turns),
            "pasclaw_rc": completed.returncode,
        }
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--fixture", type=Path,
        default=BENCH_ROOT / "fixture" / "01-snippet-window-magic-number")
    ap.add_argument("--mock", type=Path, default=None,
        help="mock transcript path; default: <fixture>/mock/default.jsonl")
    ap.add_argument("--variants", type=Path,
        default=BENCH_ROOT / "ablation.json")
    ap.add_argument("--ids", nargs="*",
        help="restrict to these variant ids (default: all)")
    ap.add_argument("--out", type=Path,
        default=BENCH_ROOT / "results" / "turn_growth.md")
    args = ap.parse_args()

    mock = args.mock or (args.fixture / "mock" / "default.jsonl")
    variants = json.loads(args.variants.read_text(encoding="utf-8"))
    if args.ids:
        variants = [v for v in variants if v.get("id") in args.ids]
    if not variants:
        sys.exit("no variants matched")

    all_runs = []
    for v in variants:
        sys.stderr.write("running %s ... " % v["id"])
        sys.stderr.flush()
        r = run_variant(args.fixture, v, mock)
        all_runs.append(r)
        sys.stderr.write("%d turns\n" % r["n_turns"])

    lines = []
    lines.append("# Per-turn request growth")
    lines.append("")
    lines.append("Generated: " + time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    lines.append("Fixture: `%s`" % args.fixture.name)
    lines.append("Mock transcript: `%s`" % mock.relative_to(BENCH_ROOT))
    lines.append("")
    lines.append("`req_bytes[N]` is the byte size of the Nth /v1/chat/completions")
    lines.append("request body. Growth between turns shows how the conversation")
    lines.append("accumulates: each turn adds the prior assistant message + the")
    lines.append("tool result. Condenser / `tool_output_cap` clip the tool-result")
    lines.append("side of that growth.")
    lines.append("")
    lines.append("| variant | turn 1 | turn 2 | turn 3 | Δ2→3 | total |")
    lines.append("|---|---|---|---|---|---|")

    for r in all_runs:
        ts = r["turns"]
        cells = []
        for i in range(3):
            if i < len(ts):
                cells.append(str(ts[i]["req_bytes"]))
            else:
                cells.append("—")
        d23 = ((ts[2]["req_bytes"] - ts[1]["req_bytes"]) if len(ts) >= 3 else 0)
        total = sum(t["req_bytes"] for t in ts)
        lines.append("| `%s` | %s | %s | %s | %+d | %d |"
                     % (r["variant_id"], cells[0], cells[1], cells[2], d23, total))

    lines.append("")
    lines.append("## Reading the table")
    lines.append("")
    lines.append("- **turn 1** = first-turn prompt size (what `probe_first_turn.py` measured).")
    lines.append("- **turn 2** = turn 1 + the assistant's tool_call + the tool result.")
    lines.append("- **turn 3** = turn 2 + the assistant's next tool_call + result.")
    lines.append("- **Δ2→3** is the size of one round (assistant turn + tool result). A flat slope means tool-result blobs aren't dominating; a steep one means they are.")
    lines.append("- **total** is the sum of req_bytes across all turns: the actual model token cost for the whole task (each turn re-sends the conversation).")
    args.out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    sys.stderr.write("wrote %s\n" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
