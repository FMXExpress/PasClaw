#!/usr/bin/env python3
"""
tool_utilization.py - how many times is each tool actually USED?

The first-turn probe + per-tool cost give the supply side: how many
bytes each tool registration costs. This probe gives the demand side:
across N task trajectories, how often does the agent actually call
each tool?

A tool with zero calls across the fixture set is paying for itself
with literally nothing in return. The cost/use ratio (bytes-per-use,
or bytes-per-task) gives a Pareto cutoff for "which tools should
default-off."

Data sources:

  1. Bundled mock transcripts (`fixture/<name>/mock/*.jsonl`). These
     are the "ideal trajectory" -- what we believe a competent agent
     SHOULD call. Source of truth for ground-floor utilization.

  2. Live-driven run results (`results/run-*/result.json`). What real
     subagents / humans / proxied LLMs actually chose. Higher noise
     but reflects real model behaviour.

Output (results/tool_utilization.md): table sorted by calls-per-task
ascending, so the never-called tools are at the top of the cut list.
"""

from __future__ import annotations

import argparse
import collections
import json
import sys
import time
from pathlib import Path


BENCH_ROOT = Path(__file__).resolve().parents[1]


# Per-tool registration sizes from results/tool_cost_stock.md.
# Held inline so the report stays self-contained; refresh with tool_cost.py
# when stock's tool catalogue changes.
TOOL_COST = {
    "execute_code":     1078,
    "fs_edit_hashline":  982,
    "web_fetch":         954,
    "fs_grep":           926,
    "session_search":    786,
    "memory_search":     705,
    "vault_search":      634,
    "memory_fetch":      633,
    "vault_get":         479,
    "fs_read":           399,
    "fs_write":          342,
    "shell_exec":        313,
    "fs_list":           231,
    "tool_output_get":   552,
    "skills_list":       400,
    "skills_view":       452,
    "skills_manage":   1491,
}


def tally_mocks(fixture_dir: Path) -> tuple[int, collections.Counter]:
    n_fixtures = 0
    counter = collections.Counter()
    for sub in sorted(fixture_dir.iterdir()):
        mock = sub / "mock" / "default.jsonl"
        if not mock.exists(): continue
        n_fixtures += 1
        for line in mock.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line: continue
            try: obj = json.loads(line)
            except json.JSONDecodeError: continue
            msg = (obj.get("choices") or [{}])[0].get("message", {})
            for tc in msg.get("tool_calls") or []:
                name = (tc.get("function") or {}).get("name", "?")
                counter[name] += 1
    return n_fixtures, counter


def tally_live_results(results_dir: Path) -> tuple[int, collections.Counter]:
    """Walk every results/run-*/queue/req_N.json the bench may have left
    behind, plus the cached assistant tool_calls in each request's prior
    messages."""
    n_runs = 0
    counter = collections.Counter()
    for run_dir in sorted(results_dir.glob("run-*")):
        rp = run_dir / "result.json"
        if not rp.exists(): continue
        n_runs += 1
        # The result.json captures aggregate metrics but NOT the per-tool
        # call list. Walk the queue's req_N.json files to recover the
        # actual tool_call sequence from the conversation history.
        queue = run_dir / "queue"
        if not queue.exists(): continue
        # The last req_N.json has the longest history -- grab from there.
        req_files = sorted(queue.glob("req_*.json"),
                           key=lambda p: int(p.stem.split("_")[1]))
        if not req_files: continue
        last = json.loads(req_files[-1].read_text(encoding="utf-8"))
        for msg in last.get("messages") or []:
            for tc in msg.get("tool_calls") or []:
                name = (tc.get("function") or {}).get("name", "?")
                counter[name] += 1
    return n_runs, counter


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--fixture-dir", type=Path, default=BENCH_ROOT / "fixture")
    ap.add_argument("--results-dir", type=Path, default=BENCH_ROOT / "results")
    ap.add_argument("--out", type=Path,
                    default=BENCH_ROOT / "results" / "tool_utilization.md")
    args = ap.parse_args()

    n_mocks, mock_calls = tally_mocks(args.fixture_dir)
    n_live, live_calls = tally_live_results(args.results_dir)

    # Universe of tool names: stock catalog + anything we observed
    seen = set(TOOL_COST.keys()) | set(mock_calls.keys()) | set(live_calls.keys())

    rows = []
    for name in seen:
        cost = TOOL_COST.get(name)
        mock_n = mock_calls.get(name, 0)
        live_n = live_calls.get(name, 0)
        per_task_mock = (mock_n / n_mocks) if n_mocks else 0
        rows.append({
            "name":           name,
            "cost_bytes":     cost,
            "mock_calls":     mock_n,
            "live_calls":     live_n,
            "calls_per_task_mock": round(per_task_mock, 2),
            "bytes_per_use":  (cost / max(1, mock_n + live_n)) if cost else None,
        })
    # Sort: never-used tools first (those are the obvious cuts), then by
    # bytes_per_use descending (high cost / low use = high cut priority).
    rows.sort(key=lambda r: (
        (r["mock_calls"] + r["live_calls"]) > 0,
        -(r["bytes_per_use"] or 0),
    ))

    lines = []
    lines.append("# Tool utilization across PasClaw's bench fixtures")
    lines.append("")
    lines.append("Generated: " + time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    lines.append("Sources: %d mock transcripts + %d live-driven runs" %
                 (n_mocks, n_live))
    lines.append("")
    lines.append("`cost_bytes` is the on-the-wire size of the tool's")
    lines.append("registration in PasClaw's first /v1/chat/completions request")
    lines.append("(from `results/tool_cost_stock.md`). `mock_calls` is how")
    lines.append("often the bundled ideal-trajectory transcripts call it;")
    lines.append("`live_calls` is from the queue history of any live-driven")
    lines.append("runs left under `results/run-*/`.")
    lines.append("")
    lines.append("Rows above the divider were NEVER called -- those are the")
    lines.append("first candidates for default-off / opt-in registration.")
    lines.append("")
    lines.append("| tool | cost | mock | live | per-task | bytes/use |")
    lines.append("|---|---|---|---|---|---|")
    sep_emitted = False
    for r in rows:
        used = r["mock_calls"] + r["live_calls"]
        if used and not sep_emitted:
            lines.append("|   |   |   |   |   |   |")
            lines.append("| **USED ↓** |   |   |   |   |   |")
            sep_emitted = True
        bpu = "—" if not r["cost_bytes"] else (
            "∞" if used == 0 else "%d" % r["bytes_per_use"])
        cost = "—" if r["cost_bytes"] is None else str(r["cost_bytes"])
        lines.append("| `%s` | %s | %d | %d | %.2f | %s |" % (
            r["name"], cost, r["mock_calls"], r["live_calls"],
            r["calls_per_task_mock"], bpu))

    # Cumulative cost / savings
    never_called_cost = sum(
        r["cost_bytes"] or 0 for r in rows
        if (r["mock_calls"] + r["live_calls"]) == 0
    )
    total_cost = sum(r["cost_bytes"] or 0 for r in rows)
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append("- Total stock-catalog cost: **%d bytes**" % total_cost)
    lines.append("- Cost of NEVER-called tools: **%d bytes (%.1f%%)**" %
                 (never_called_cost, 100 * never_called_cost / max(1, total_cost)))
    lines.append("- Tools the bundled fixtures actually call: **%d / %d** (%.0f%%)" %
                 (sum(1 for r in rows if r["mock_calls"] > 0),
                  len([r for r in rows if r["cost_bytes"] is not None]),
                  100 * sum(1 for r in rows if r["mock_calls"] > 0) /
                  max(1, len([r for r in rows if r["cost_bytes"] is not None]))))
    lines.append("")
    lines.append("Caveats:")
    lines.append("")
    lines.append("- The bench fixtures are SMALL. Real coding tasks would")
    lines.append("  call `fs_grep` (find callers) and `fs_edit_hashline`")
    lines.append("  (surgical patches) far more often. The utilization")
    lines.append("  numbers here are a floor, not a ceiling.")
    lines.append("- Mock transcripts are author-curated; they reflect what I")
    lines.append("  THINK the agent should do, not what it actually does. The")
    lines.append("  `live` column corrects for that bias as it grows.")
    lines.append("- The 13-tool stock catalog plus the 4 max-build add-ons")
    lines.append("  are sized in `results/tool_cost_stock.md` -- refresh that")
    lines.append("  if a tool's description or schema changes.")

    args.out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    sys.stderr.write("wrote %s\n" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
