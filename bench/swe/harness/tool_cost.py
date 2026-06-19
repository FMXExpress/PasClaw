#!/usr/bin/env python3
"""
tool_cost.py - measure the per-tool size cost in PasClaw's request body.

Each entry in the OpenAI `tools` array on /v1/chat/completions has a
JSON-encoded shape of:

    {"type":"function","function":{
        "name": "<short>",
        "description": "<one-liner>",
        "parameters": {<JSON schema>}
    }}

The wrapper overhead is ~30 bytes; the rest is name + description +
parameters. A 4-line description schema costs ~250 bytes; a fully-
specified one (fs_read with its hashline disclaimer, shell_exec with
backend notes, skills_manage with the create/install/remove sub-modes)
runs 500-1500.

This script reads a probe.json that includes the full per-variant
tool_names list, fetches each variant's actual tools[] array, and
tabulates which tools dominate the byte count.
"""

from __future__ import annotations

import argparse
import json
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


HARNESS_DIR = Path(__file__).resolve().parent
BENCH_ROOT = HARNESS_DIR.parent
REPO_ROOT = BENCH_ROOT.parent.parent
PASCLAW_BIN = REPO_ROOT / "build" / "pasclaw"


def stage_workspace(fixture_dir: Path, workspace: Path) -> None:
    pre = fixture_dir / "pre-fix"
    if not pre.exists(): return
    for src in pre.rglob("*"):
        if src.is_dir(): continue
        rel = src.relative_to(pre)
        dst = workspace / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


def capture_first_request(fixture_dir: Path, variant: dict) -> dict:
    work = Path(tempfile.mkdtemp(prefix="toolcost-"))
    try:
        home = work / "home"; home.mkdir()
        ws = work / "ws";   ws.mkdir()
        q = work / "q";     q.mkdir()
        stage_workspace(fixture_dir, ws)

        stub = subprocess.Popen(
            [sys.executable, str(HARNESS_DIR / "provider_stub.py"),
             "--blocking", str(q), "--blocking-timeout-s", "60"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
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
        if variant.get("no_tools"): argv += ["--no-tools"]
        if variant.get("no_mcp"):   argv += ["--no-mcp"]

        import os
        env = os.environ.copy()
        env["PASCLAW_HOME"] = str(home); env["NO_COLOR"] = "1"
        pasclaw = subprocess.Popen(argv, env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True)

        req_path = q / "req_1.json"
        t0 = time.monotonic()
        while time.monotonic() - t0 < 15:
            if req_path.exists(): break
            if pasclaw.poll() is not None:
                stub.terminate()
                raise RuntimeError("pasclaw exited before first turn")
            time.sleep(0.1)

        req = json.loads(req_path.read_bytes())
        pasclaw.send_signal(signal.SIGTERM)
        try: pasclaw.wait(timeout=2)
        except subprocess.TimeoutExpired: pasclaw.kill()
        stub.terminate()
        try: stub.wait(timeout=2)
        except subprocess.TimeoutExpired: stub.kill()
        return req
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--fixture", type=Path,
                    default=BENCH_ROOT / "fixture" / "01-snippet-window-magic-number")
    ap.add_argument("--variant", default='{"id":"max-build","profile":"max-build"}',
                    help="variant whose tool[] array to dissect (default: max-build)")
    ap.add_argument("--out", type=Path,
                    default=BENCH_ROOT / "results" / "tool_cost.md")
    args = ap.parse_args()

    variant = json.loads(args.variant)
    req = capture_first_request(args.fixture, variant)
    tools = req.get("tools") or []

    rows = []
    total = 0
    for t in tools:
        fn = (t.get("function") or {})
        name = fn.get("name", "?")
        desc = fn.get("description", "")
        params = fn.get("parameters", {})
        params_str = json.dumps(params, separators=(",", ":"))
        # Re-encode the full tool entry to get the on-the-wire size.
        encoded = json.dumps(t, separators=(",", ":"))
        rows.append({
            "name": name,
            "total_bytes": len(encoded),
            "name_bytes": len(name),
            "desc_chars": len(desc),
            "schema_bytes": len(params_str),
            "wrapper_overhead": len(encoded) - len(name) - len(desc) - len(params_str),
        })
        total += len(encoded)
    rows.sort(key=lambda r: -r["total_bytes"])

    lines = []
    lines.append("# Per-tool size — `%s` variant" % variant.get("id", "?"))
    lines.append("")
    lines.append("Generated: " + time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    lines.append("")
    lines.append("Each row is one tool registration. `total_bytes` is the")
    lines.append("on-the-wire byte size of that tool's entry in the `tools[]`")
    lines.append("array of the first /v1/chat/completions request. `desc_chars`")
    lines.append("is the description string length; `schema_bytes` is the")
    lines.append("compact JSON of the parameters schema.")
    lines.append("")
    lines.append("| tool | total | desc | schema | %  |")
    lines.append("|---|---|---|---|---|")
    for r in rows:
        pct = (r["total_bytes"] / total * 100) if total else 0
        lines.append("| `%s` | %d | %d | %d | %.1f%% |"
                     % (r["name"], r["total_bytes"], r["desc_chars"],
                        r["schema_bytes"], pct))
    lines.append("| **TOTAL** | **%d** |   |   | 100%% |" % total)
    lines.append("")
    lines.append("## What to look at")
    lines.append("")
    lines.append("- **Long descriptions on rarely-explained tools** — fs_read, fs_write, shell_exec are universally understood; their multi-line descriptions in PasClaw.Tools.* may pay for themselves with a small subset of users.")
    lines.append("- **Verbose schema strings** — JSON Schema's `description` fields inside parameters compound: each property gets one.")
    lines.append("- **Tool name length** — `fs_edit_hashline` is 16 chars × 4 mentions per call (name, in the schema, in the description) — minor but multiplies across runs.")
    args.out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    sys.stderr.write("wrote %s -- %d tools / %d total bytes\n"
                     % (args.out, len(rows), total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
