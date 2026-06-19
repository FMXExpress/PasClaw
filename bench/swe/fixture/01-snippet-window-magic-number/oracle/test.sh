#!/usr/bin/env bash
# Oracle for fixture 01: confirm the magic number has been lifted to a
# named const and both SQL strings now reference it.
#
# Exit 0 = passed, non-zero = failed. The harness only inspects the exit
# code -- stdout/stderr are captured into result.json for debugging.

set -u
src="src/index.pas"

if [ ! -f "$src" ]; then
  echo "FAIL: $src missing (agent deleted or moved the file)"
  exit 2
fi

# (a) FTS5_SNIPPET_TOKENS = 60 declared in the interface section.
# We check the const declaration appears BEFORE the `implementation`
# keyword. Using awk to extract just the interface portion.
interface_block=$(awk '
  /^[[:space:]]*implementation[[:space:]]*$/ { exit }
  { print }
' "$src")

if ! echo "$interface_block" | grep -qE 'FTS5_SNIPPET_TOKENS[[:space:]]*=[[:space:]]*60[[:space:]]*;'; then
  echo "FAIL: FTS5_SNIPPET_TOKENS = 60 not found in interface section"
  exit 1
fi

# (b) Neither SQL string contains the literal 24 anymore.
if grep -qE "''…''[^)]*,[[:space:]]*24\)|'\\.\\.\\.''[^)]*,[[:space:]]*24\)" "$src"; then
  echo "FAIL: literal 24 still present in a snippet() SQL call"
  exit 1
fi
# Also accept the explicit ASCII three-dot form the fixture ships with.
if grep -qE "''\\.\\.\\.''[^)]*,[[:space:]]*24\\)" "$src"; then
  echo "FAIL: literal 24 still present in a snippet() SQL call"
  exit 1
fi

# (c) Both SQL strings reference IntToStr(FTS5_SNIPPET_TOKENS).
ref_count=$(grep -cE 'IntToStr\([[:space:]]*FTS5_SNIPPET_TOKENS[[:space:]]*\)' "$src" || true)
if [ "$ref_count" -lt 2 ]; then
  echo "FAIL: expected 2 references to IntToStr(FTS5_SNIPPET_TOKENS), found $ref_count"
  exit 1
fi

echo "PASS"
exit 0
