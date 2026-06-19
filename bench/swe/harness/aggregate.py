#!/usr/bin/env python3
"""
aggregate.py - turn a directory of per-cell result.json files into a frontier.

Used to score live-driven runs (those produced by start_cell.sh /
finalize_cell.sh, not by score.py). Same Pareto-frontier logic as score.py
so live + mock + proxy results sit alongside each other.

    aggregate.py [--results-dir DIR] [--out frontier.md]
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

# Reuse score.py's aggregate / frontier helpers.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from score import aggregate, pareto_frontier, write_frontier_md  # noqa: E402


def load_results(results_dir: Path) -> list[dict]:
    out = []
    for run_dir in sorted(results_dir.glob("run-*")):
        rp = run_dir / "result.json"
        if not rp.exists():
            continue
        try:
            out.append(json.loads(rp.read_text(encoding="utf-8")))
        except json.JSONDecodeError as e:
            sys.stderr.write("skipping %s: %s\n" % (rp, e))
    return out


def main() -> int:
    bench_root = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--results-dir", type=Path, default=bench_root / "results")
    ap.add_argument("--out", type=Path, default=None,
                    help="output markdown (default: <results-dir>/frontier.md)")
    args = ap.parse_args()

    results = load_results(args.results_dir)
    if not results:
        sys.stderr.write("no result.json files under %s\n" % args.results_dir)
        return 1

    rows = aggregate(results)
    front = pareto_frontier(rows)
    front_ids = {r["variant_id"] for r in front}
    out_path = args.out or (args.results_dir / "frontier.md")
    write_frontier_md(out_path, rows, front_ids)

    sys.stderr.write("aggregated %d cells across %d variants -> %s\n"
                     % (len(results), len(rows), out_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
