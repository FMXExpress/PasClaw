#!/usr/bin/env bash
# Oracle for fixture 08-cli-centipede.
#
# Scoring is binary (pass/fail) but it captures a rich set of stats on stderr
# for the report. PASS requires every must-have; HINT lines record nice-to-haves
# for the analysis but do not gate the pass.

set -u
PY=python3

if [ ! -f game.py ]; then
  echo "FAIL: game.py missing"
  exit 1
fi

# ----- (a) syntactic validity -----
if ! $PY - <<'PY' 2>/dev/null
import ast, sys
src = open("game.py").read()
ast.parse(src)
sys.exit(0)
PY
then
  echo "FAIL: game.py does not parse as Python"
  exit 1
fi

# ----- (b) structural checks -----
$PY - <<'PY' || exit 1
import ast, sys, re
src = open("game.py").read()
tree = ast.parse(src)

# Symbol survey
funcs = {n.name for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
classes = {n.name for n in ast.walk(tree) if isinstance(n, ast.ClassDef)}
loc = sum(1 for line in src.splitlines()
          if line.strip() and not line.strip().startswith('#'))

print(f"STATS classes={len(classes)} funcs={len(funcs)} loc={loc}", file=sys.stderr)
print(f"STATS class_names={sorted(classes)}", file=sys.stderr)

problems = []

# must-have: a curses import OR equivalent TUI usage
if 'curses' not in src and 'blessed' not in src and 'rich.live' not in src:
    problems.append("no curses/blessed/rich.live import (TUI library required)")

# must-have: --self-test flag handling
if '--self-test' not in src:
    problems.append("missing --self-test flag handling")

# must-have: line count
if loc < 100:
    problems.append(f"too few lines of code ({loc} < 100)")
if loc > 800:
    problems.append(f"too many lines of code ({loc} > 800)")

# must-have: some notion of player, centipede, and bullet
text_lower = src.lower()
for needle in ['player', 'centipede', 'bullet']:
    if text_lower.count(needle) < 2:
        problems.append(f"insufficient references to '{needle}' (need >= 2)")

if problems:
    for p in problems:
        print(f"FAIL: {p}", file=sys.stderr)
    sys.exit(1)
PY

# ----- (c) self-test invocation -----
# Run with a strict timeout. The agent's --self-test must NOT touch curses
# (we have no TTY); if it does, it'll error out and we'll fail here.
OUT=$($PY game.py --self-test 2>&1)
RC=$?
echo "STATS self_test_rc=$RC" >&2
echo "$OUT" >&2

if [ "$RC" -ne 0 ]; then
  echo "FAIL: --self-test exited with rc=$RC"
  exit 1
fi
if ! echo "$OUT" | grep -q "SELF_TEST_OK"; then
  echo "FAIL: --self-test ran but did not print SELF_TEST_OK"
  exit 1
fi

echo "PASS"
exit 0
