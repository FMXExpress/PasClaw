#!/usr/bin/env bash
# Oracle for fixture 02: confirm QuoteForCmd doubles internal quotes and
# returns "" (two chars) for an empty input.
#
# We can't compile/run Pascal portably in CI -- so the oracle is static:
# we look for the structural changes the fix requires.

set -u
src="src/cmd_quote.pas"

if [ ! -f "$src" ]; then
  echo "FAIL: $src missing"
  exit 2
fi

# Extract the function body (between begin..end; that follows
# "function QuoteForCmd").
body=$(awk '
  /^function QuoteForCmd/ { in_fn=1 }
  in_fn { print }
  in_fn && /^end;/ { exit }
' "$src")

if [ -z "$body" ]; then
  echo "FAIL: could not locate QuoteForCmd implementation"
  exit 1
fi

# (a) The body must mention StringReplace or equivalent doubling -- any
# fix that doesn't transform the input character-by-character is too
# narrow for the contract. We accept either StringReplace, a manual loop,
# or AdjustLineBreaks-style transforms.
if ! echo "$body" | grep -qE "StringReplace|ReplaceStr|for .*:=|while .*\b1\b"; then
  echo "FAIL: QuoteForCmd body doesn't transform the input -- still a thin wrap"
  echo "--- body ---"; echo "$body"
  exit 1
fi

# (b) Reject the obvious "just wrap in quotes" form: Result := '"' + Arg + '"'
# with no other statements before it.
if echo "$body" | grep -qE "Result[[:space:]]*:=[[:space:]]*'\"'[[:space:]]*\\+[[:space:]]*Arg[[:space:]]*\\+[[:space:]]*'\"'[[:space:]]*;"; then
  # Only fail if that's the ONLY assignment in the body.
  count=$(echo "$body" | grep -cE "Result[[:space:]]*:=")
  if [ "$count" = "1" ]; then
    echo "FAIL: body only wraps in quotes; internal quotes are not escaped"
    exit 1
  fi
fi

# (c) Some handling of the empty case must be present -- either an explicit
# Length(Arg) = 0 / Arg = '' check returning '""', OR the transform must
# naturally produce '""' for an empty input (which '"' + '' + '"' does).
# So (c) is informational only -- we don't fail on its absence.

echo "PASS"
exit 0
