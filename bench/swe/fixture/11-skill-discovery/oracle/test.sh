#!/usr/bin/env bash
# Oracle for fixture 11-skill-discovery.
# Verifies result.csv exactly matches the spec the skill defines.

set -u

if [ ! -f result.csv ]; then
  echo "FAIL: result.csv missing"
  exit 1
fi

expected="1,20,ALPHA
2,40,GAMMA
3,60,BETA
4,80,DELTA"

got=$(cat result.csv)

# strip trailing newline from got for comparison
got=$(printf '%s' "$got")

if [ "$got" = "$expected" ]; then
  echo "STATS rows=4 used_skill=yes" >&2
  echo "PASS"
  exit 0
fi

echo "FAIL: result.csv does not match the spec"
echo "--- want ---"
echo "$expected"
echo "--- got ---"
echo "$got"
exit 1
