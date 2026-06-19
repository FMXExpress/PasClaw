#!/usr/bin/env bash
# Oracle for fixture 10-add-cloudflare-provider.
#
# (a) make must succeed -- the build is the first integrity check.
# (b) The compiled binary must surface the new provider somewhere visible
#     from the CLI (onboard / catalog dump / similar).
# (c) The new entry must reference cloudflare in the catalog source so
#     a casual grep finds it (caller may have used a hyphenated or
#     CamelCase name; we accept either).

set -u

if [ ! -f Makefile ]; then
  echo "FAIL: no Makefile at workspace root (workspace not staged?)"
  exit 1
fi

# ----- (a) build -----
BUILD_LOG=$(mktemp)
trap 'rm -f "$BUILD_LOG"' EXIT
if ! make >"$BUILD_LOG" 2>&1; then
  echo "FAIL: make exited non-zero"
  echo "--- last 25 lines of build output ---"
  tail -25 "$BUILD_LOG"
  exit 1
fi
echo "STATS build_passed=yes" >&2

# ----- (b) catalog source references cloudflare -----
# Be permissive about the exact identifier the agent chose; reject only if
# NOTHING cloudflare-shaped appears in providers/.
if ! grep -RiE "cloudflare" src/pkg/providers/ >/dev/null 2>&1; then
  echo "FAIL: no 'cloudflare' reference under src/pkg/providers/"
  exit 1
fi
hits=$(grep -RiE "cloudflare" src/pkg/providers/ | wc -l)
echo "STATS catalog_cloudflare_hits=$hits" >&2

# ----- (c) CLI visibility -----
# Probe the most likely surface in order: onboard help, profile list, model
# list, and a generic --help. At least one must mention cloudflare.
declare -a probes=(
  "build/pasclaw --no-color onboard"
  "build/pasclaw --no-color auth login cloudflare-ai-gateway"
)
found=no
for cmd in "${probes[@]}"; do
  out=$($cmd 2>&1 || true)
  if echo "$out" | grep -qi cloudflare; then
    found=yes
    matched=$(echo "$out" | grep -iE "cloudflare" | head -1)
    echo "STATS cli_match=\"$matched\"" >&2
    break
  fi
done
if [ "$found" = "no" ]; then
  # Fallback: dump the catalog via a build of pasclaw onboard's listing path
  out=$(build/pasclaw --no-color auth login 2>&1 || true)
  if echo "$out" | grep -qi cloudflare; then
    found=yes
    matched=$(echo "$out" | grep -iE "cloudflare" | head -1)
    echo "STATS cli_match_fallback=\"$matched\"" >&2
  fi
fi
if [ "$found" = "no" ]; then
  echo "FAIL: cloudflare reference present in source but not surfaced via the CLI"
  echo "(tried: ${probes[*]})"
  exit 1
fi

echo "PASS"
exit 0
