#!/usr/bin/env bash
# Oracle for fixture 07: result.txt must contain exactly the 3 paths of
# files that actually CALL OldRoutine -- src/legacy.pas, src/loader.pas,
# src/sub/queue.pas -- and nothing else.

set -u

if [ ! -f result.txt ]; then
  echo "FAIL: result.txt missing"
  exit 1
fi

expected="src/legacy.pas
src/loader.pas
src/sub/queue.pas"

# Trim, dedupe, sort the agent's output for comparison.
got=$(grep -v "^[[:space:]]*$" result.txt | sed 's|^\./||' | sort -u)
want=$(printf '%s' "$expected" | sort -u)

if [ "$got" = "$want" ]; then
  echo "PASS"
  exit 0
fi

echo "FAIL: result.txt does not match expected"
echo "--- want ---"
echo "$want"
echo "--- got ---"
echo "$got"
exit 1
