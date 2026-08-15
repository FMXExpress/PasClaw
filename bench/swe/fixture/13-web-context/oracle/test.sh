#!/usr/bin/env bash
# Oracle for fixture 13-web-context.
# Runs the agent's transform.py against the spec contract.

set -u

if [ ! -f transform.py ]; then
  echo "FAIL: transform.py missing"
  exit 1
fi

python3 - <<'PY' || exit 1
import sys, hashlib

# Import without polluting cwd state
sys.path.insert(0, ".")
try:
    from transform import transform
except Exception as e:
    print(f"FAIL: transform.py does not import: {e}")
    sys.exit(1)

# Happy path
got = transform([(1, "Foo"), (2, "bAr"), (3, "BAZ")])
def fp(i, lbl):
    return hashlib.sha256(f"{i}:{lbl}".encode()).hexdigest()
want = [
    {"id": 1, "label": "foo", "fingerprint": fp(1, "foo")},
    {"id": 2, "label": "bar", "fingerprint": fp(2, "bar")},
    {"id": 3, "label": "baz", "fingerprint": fp(3, "baz")},
]
if got != want:
    print("FAIL: transform output mismatch")
    print("want:", want)
    print("got: ", got)
    sys.exit(1)

# Empty
if transform([]) != []:
    print("FAIL: transform([]) should be []")
    sys.exit(1)

# Error: None label
try:
    transform([(1, None)])
    print("FAIL: transform should raise ValueError on None label")
    sys.exit(1)
except ValueError as e:
    if str(e) != "label cannot be None":
        print(f"FAIL: wrong error message: {e!r}")
        sys.exit(1)

# Ensure no extra keys -- if any output dict has more than 3 keys, that's a fail
got_keys = set(got[0].keys())
if got_keys != {"id", "label", "fingerprint"}:
    print(f"FAIL: unexpected keys: {got_keys}")
    sys.exit(1)

print("STATS contract_match=yes rows=3 error_path=ok", file=sys.stderr)
print("PASS")
PY
