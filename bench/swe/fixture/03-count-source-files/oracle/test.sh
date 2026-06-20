#!/usr/bin/env bash
# Oracle for fixture 03: report.json must contain {"count": 4}.

set -u

if [ ! -f report.json ]; then
  echo "FAIL: report.json missing"
  exit 1
fi

# Use python3 because it's universally available and gives a precise
# parse + key check. jq isn't guaranteed.
python3 - <<'PY' || exit 1
import json, sys
try:
    with open("report.json") as fh:
        obj = json.load(fh)
except Exception as e:
    print("FAIL: report.json not valid JSON:", e)
    sys.exit(1)
if not isinstance(obj, dict):
    print("FAIL: top-level not a JSON object")
    sys.exit(1)
if list(obj.keys()) != ["count"]:
    print("FAIL: expected exactly one field 'count', got:", list(obj.keys()))
    sys.exit(1)
if obj["count"] != 4:
    print("FAIL: count =", obj["count"], "; expected 4")
    sys.exit(1)
print("PASS")
PY
