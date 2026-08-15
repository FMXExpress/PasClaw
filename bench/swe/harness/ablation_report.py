#!/usr/bin/env python3
"""
ablation_report.py - turn results/probe.json into a markdown report.

Reads the JSON dump produced by running probe_first_turn.py over
ablation.json, ranks variants by first-turn prompt cost, and computes
each candidate's delta against a baseline (stock by default).
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path


def main() -> int:
    bench_root = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--probe", type=Path,
                    default=bench_root / "results" / "probe.json")
    ap.add_argument("--baseline-id", default="stock")
    ap.add_argument("--out", type=Path,
                    default=bench_root / "results" / "ablation.md")
    args = ap.parse_args()

    rows = json.loads(args.probe.read_text(encoding="utf-8"))
    rows = [r for r in rows if "req_bytes" in r]
    by_id = {r["variant_id"]: r for r in rows}

    base = by_id.get(args.baseline_id)
    if base is None:
        sys.exit("baseline variant_id %r not in probe" % args.baseline_id)

    base_bytes = base["req_bytes"]
    base_tools = base["n_tools"]
    base_toolset = set(base["tool_names"])

    rows.sort(key=lambda r: r["req_bytes"])

    lines = []
    lines.append("# Ablation: first-turn prompt cost by setting")
    lines.append("")
    lines.append("Generated: " + time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    lines.append("")
    lines.append("Each row is one variant of PasClaw's configuration. `req_bytes`")
    lines.append("is the size of the FIRST `/v1/chat/completions` request body --")
    lines.append("the system prompt + tools schema + user task. Larger = more")
    lines.append("tokens spent on every turn before any agent reasoning.")
    lines.append("")
    lines.append("Δ columns are vs `%s` (req_bytes=%d, tools=%d)."
                 % (args.baseline_id, base_bytes, base_tools))
    lines.append("")
    lines.append("| variant | req_bytes | Δbytes | tools | Δtools | tool diff |")
    lines.append("|---|---|---|---|---|---|")

    for r in rows:
        vid = r["variant_id"]
        rb = r["req_bytes"]
        nt = r["n_tools"]
        d_b = rb - base_bytes
        d_t = nt - base_tools
        cur = set(r["tool_names"])
        added = sorted(cur - base_toolset)
        removed = sorted(base_toolset - cur)
        diff_parts = []
        if added:   diff_parts.append("+ " + " ".join(added))
        if removed: diff_parts.append("− " + " ".join(removed))
        diff = " ".join(diff_parts) or "—"
        lines.append("| `%s` | %d | %+d | %d | %+d | %s |"
                     % (vid, rb, d_b, nt, d_t, diff))

    lines.append("")
    lines.append("## Interpretation")
    lines.append("")
    lines.append("- **Zero-byte toggles** (Δbytes = 0): pure behavior, no prompt cost. Default candidates for a 'free upgrade' composite over stock.")
    lines.append("- **+552 / +1 tool**: registers `tool_output_get`, triggered by `condense_reversible` OR a non-zero `tool_output_cap`. Pay for this when your tool outputs are large enough to hit the cap.")
    lines.append("- **+852 / +2 tools**: `progressive_disclosure` registers `skills_list` + `skills_view`. Pay for this only if you have skills installed and want the agent to discover them on demand.")
    lines.append("- **+1491 / +1 tool**: `self_manage` registers `skills_manage`. The single most expensive registration. Pay for this only if the agent should be authoring skills mid-session.")
    lines.append("")
    lines.append("`baseline` and `security` strip web_fetch / vault entirely -- useful in sandboxed deployments where outbound HTTP is explicitly off.")
    return args.out.write_text("\n".join(lines) + "\n", encoding="utf-8") or 0


if __name__ == "__main__":
    sys.exit(main())
