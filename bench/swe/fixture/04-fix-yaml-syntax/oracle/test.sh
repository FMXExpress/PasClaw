#!/usr/bin/env bash
# Oracle for fixture 04: config.yaml must parse AND retain every original
# key with its original value (except the typo'd one's key name).

set -u

if [ ! -f config.yaml ]; then
  echo "FAIL: config.yaml missing"
  exit 1
fi

python3 - <<'PY' || exit 1
import sys
try:
    import yaml
except ImportError:
    print("FAIL: oracle requires PyYAML (pip install pyyaml)")
    sys.exit(2)
try:
    with open("config.yaml") as fh:
        obj = yaml.safe_load(fh)
except yaml.YAMLError as e:
    print("FAIL: YAML still doesn't parse:", e)
    sys.exit(1)
if not isinstance(obj, dict):
    print("FAIL: top-level not a mapping")
    sys.exit(1)

expected = {
    "service": "pasclaw",
    "version": "1.0.0",
    "provider": "openai",
    "model": "gpt-4o-mini",
    "max_tokens": 4096,
    "timeout_seconds": 60,
    "features": ["skills", "cron", "kb"],
}
for k, v in expected.items():
    if k not in obj:
        print("FAIL: missing key", repr(k))
        sys.exit(1)
    if obj[k] != v:
        print("FAIL: key", repr(k), "is", repr(obj[k]), "expected", repr(v))
        sys.exit(1)
extras = set(obj) - set(expected)
if extras:
    print("FAIL: unexpected extra keys:", extras)
    sys.exit(1)
print("PASS")
PY
