#!/usr/bin/env python3
"""
score.py - sweep the variants x fixtures grid and emit a Pareto frontier.

Usage:
    score.py --mock                       # offline, replays bundled mock transcripts
    score.py --proxy <upstream_base_url>  # forward to a real provider
    score.py --variants variants.json --fixtures fixture/01-* fixture/02-*

Output goes to results/frontier.md (markdown table) and results/sweep.json
(raw per-cell records, machine-readable for follow-up analysis).

The frontier reports Pareto-optimal variants across the three axes the
Perplexity research called out: pass-rate, tokens-per-solved-task, and
out-of-scope-edit rate. Wall-clock and turn count are tracked but not
used to define the frontier -- they're informational, since they vary
with provider latency rather than with PasClaw settings.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path


BENCH_ROOT = Path(__file__).resolve().parents[1]
RUN_PY = Path(__file__).with_name("run.py")


def load_variants(path: Path) -> list[dict]:
    return json.loads(path.read_text(encoding="utf-8"))


def expand_fixtures(specs: list[str]) -> list[Path]:
    out = []
    for s in specs:
        p = Path(s)
        if not p.is_absolute():
            p = BENCH_ROOT / p
        if p.is_dir() and (p / "manifest.json").exists():
            out.append(p)
        elif "*" in s:
            base = (BENCH_ROOT / "fixture") if not p.parent.parts else p.parent
            for cand in sorted(base.glob(p.name)):
                if (cand / "manifest.json").exists():
                    out.append(cand)
        else:
            sys.exit("not a fixture: " + str(p))
    return out


def run_cell(variant: dict, fixture: Path, args, run_id: str) -> dict:
    cmd = [
        sys.executable, str(RUN_PY),
        "--fixture", str(fixture),
        "--variant", json.dumps(variant),
        "--results-dir", str(args.results_dir),
        "--run-id", run_id,
        "--timeout-pasclaw", str(args.timeout_pasclaw),
        "--timeout-oracle", str(args.timeout_oracle),
    ]
    if args.mock:
        # Each fixture x variant cell needs its own mock transcript. The
        # convention: fixture/<name>/mock/<variant-id>.jsonl, falling back
        # to fixture/<name>/mock/default.jsonl.
        vid = variant.get("id", "default")
        mock_path = fixture / "mock" / (vid + ".jsonl")
        if not mock_path.exists():
            mock_path = fixture / "mock" / "default.jsonl"
        if not mock_path.exists():
            return {
                "fixture": fixture.name, "variant": variant,
                "passed": None,
                "error": "no mock transcript at %s" % mock_path,
            }
        cmd += ["--mock", str(mock_path)]
    else:
        cmd += ["--proxy", args.proxy]

    completed = subprocess.run(cmd, capture_output=True, text=True)
    out = completed.stdout.strip().splitlines()
    if not out:
        return {
            "fixture": fixture.name, "variant": variant,
            "passed": None,
            "error": "run.py emitted no result; stderr: " + completed.stderr[-500:],
        }
    try:
        return json.loads(out[-1])
    except json.JSONDecodeError as e:
        return {
            "fixture": fixture.name, "variant": variant,
            "passed": None, "error": "result JSON parse failed: " + str(e),
        }


def aggregate(results: list[dict]) -> list[dict]:
    """Group per-cell records by variant id and compute pass-rate +
    tokens/solved + oos-rate. Variant id is the variant.id field, or
    a hash of the variant body when id is missing."""
    from collections import defaultdict
    by_id: dict[str, list[dict]] = defaultdict(list)
    for r in results:
        vid = (r.get("variant") or {}).get("id") or "anon"
        by_id[vid].append(r)
    rows = []
    for vid, cells in by_id.items():
        n = len(cells)
        passed = sum(1 for c in cells if c.get("passed") is True)
        tok_out_solved = sum(
            (c.get("metrics") or {}).get("tokens_out", 0)
            for c in cells if c.get("passed") is True
        )
        tok_in_solved = sum(
            (c.get("metrics") or {}).get("tokens_in", 0)
            for c in cells if c.get("passed") is True
        )
        oos_total = sum(c.get("oos_edits", 0) for c in cells)
        turns_total = sum(
            (c.get("metrics") or {}).get("turn_count", 0) for c in cells
        )
        rows.append({
            "variant_id": vid,
            "n": n,
            "passed": passed,
            "pass_rate": passed / n if n else 0.0,
            "tokens_per_solved": (tok_in_solved + tok_out_solved) / passed if passed else None,
            "oos_per_run": oos_total / n if n else 0.0,
            "turns_per_run": turns_total / n if n else 0.0,
        })
    return rows


def pareto_frontier(rows: list[dict]) -> list[dict]:
    """Pareto-optimal: no other row dominates on all three axes
    (pass-rate higher, tokens/solved lower, oos lower)."""
    def dominated(r, other):
        if other["pass_rate"] < r["pass_rate"]:
            return False
        if other["oos_per_run"] > r["oos_per_run"]:
            return False
        # tokens_per_solved is None when nothing passed -- treat as infinite.
        rt = r["tokens_per_solved"] or float("inf")
        ot = other["tokens_per_solved"] or float("inf")
        if ot > rt:
            return False
        return (other["pass_rate"], -ot, -other["oos_per_run"]) > \
               (r["pass_rate"], -rt, -r["oos_per_run"])
    frontier = []
    for r in rows:
        if r["passed"] == 0:
            continue  # never on the frontier
        if not any(dominated(r, o) for o in rows if o is not r):
            frontier.append(r)
    return frontier


def write_frontier_md(path: Path, rows: list[dict], frontier_ids: set) -> None:
    lines = ["# SWE bench sweep results", ""]
    lines.append("Generated: " + time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    lines.append("")
    lines.append("| variant | n | pass | pass-rate | tok/solved | oos/run | turns/run | frontier |")
    lines.append("|---|---|---|---|---|---|---|---|")
    rows_sorted = sorted(rows, key=lambda r: (-r["pass_rate"], r["tokens_per_solved"] or 1e18))
    for r in rows_sorted:
        on_front = "yes" if r["variant_id"] in frontier_ids else ""
        tok = "-" if r["tokens_per_solved"] is None else "%.0f" % r["tokens_per_solved"]
        lines.append("| `%s` | %d | %d | %.2f | %s | %.2f | %.1f | %s |" % (
            r["variant_id"], r["n"], r["passed"], r["pass_rate"],
            tok, r["oos_per_run"], r["turns_per_run"], on_front,
        ))
    lines.append("")
    lines.append("`frontier=yes` means no other variant strictly dominates on")
    lines.append("(pass-rate higher, tokens-per-solved lower, oos lower). Pick")
    lines.append("the frontier row whose tradeoff matches your deployment.")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--variants", type=Path,
                    default=BENCH_ROOT / "variants.json")
    ap.add_argument("--fixtures", nargs="*",
                    default=["fixture/*"])
    ap.add_argument("--results-dir", type=Path,
                    default=BENCH_ROOT / "results")
    ap.add_argument("--timeout-pasclaw", type=int, default=300)
    ap.add_argument("--timeout-oracle", type=int, default=60)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--mock", action="store_true",
                      help="use bundled mock transcripts (no upstream call)")
    mode.add_argument("--proxy", metavar="BASE_URL",
                      help="proxy each request to <BASE_URL>")
    args = ap.parse_args()

    variants = load_variants(args.variants)
    fixtures = expand_fixtures(args.fixtures)
    if not fixtures:
        sys.exit("no fixtures matched")
    sys.stderr.write("variants=%d fixtures=%d -> %d cells\n" % (
        len(variants), len(fixtures), len(variants) * len(fixtures)))

    args.results_dir.mkdir(parents=True, exist_ok=True)
    sweep_id = time.strftime("sweep-%Y%m%dT%H%M%S")

    results = []
    for vi, v in enumerate(variants):
        for fi, f in enumerate(fixtures):
            run_id = "%s-v%02d-%s" % (sweep_id, vi, f.name)
            sys.stderr.write("[%d/%d] %s x %s ... " % (
                vi * len(fixtures) + fi + 1, len(variants) * len(fixtures),
                v.get("id", "anon"), f.name))
            sys.stderr.flush()
            r = run_cell(v, f, args, run_id)
            results.append(r)
            mark = "PASS" if r.get("passed") else ("FAIL" if r.get("passed") is False else "ERR")
            sys.stderr.write(mark + "\n")

    (args.results_dir / (sweep_id + ".json")).write_text(
        json.dumps(results, indent=2), encoding="utf-8")

    rows = aggregate(results)
    front = pareto_frontier(rows)
    front_ids = {r["variant_id"] for r in front}
    write_frontier_md(args.results_dir / "frontier.md", rows, front_ids)
    sys.stderr.write("wrote %s and %s\n" % (
        args.results_dir / "frontier.md",
        args.results_dir / (sweep_id + ".json"),
    ))
    return 0


if __name__ == "__main__":
    sys.exit(main())
