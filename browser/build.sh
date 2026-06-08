#!/usr/bin/env bash
#
# Build a static, manually-deployable "PasClaw in the browser" bundle using
# container2wasm's emscripten pipeline. Output: browser/site/ — a folder of
# static files (index.html + webpack dist/ + the c2w wasm + the in-browser
# network stack) you upload to any static host. No backend/relay: the agent's
# HTTPS rides the browser's own fetch() via c2w-net-proxy.
#
# RUN THIS ON A REAL MACHINE — not a TLS-intercepting sandbox. Needs:
#   - docker (daemon running)
#   - the `c2w` CLI on PATH  (https://github.com/container2wasm/container2wasm/releases)
#   - node + npm (npx)       (webpack bundles the xterm harness)
#   - git, curl, gzip
#
# Heavy + slow the first time (c2w compiles its emulator from source; the
# output .wasm is ~100 MB+). Env overrides: IMAGE, C2W, C2W_VERSION.
#
# Mirrors the upstream "on browser" quickstart, pointed at the pasclaw image:
#   https://github.com/container2wasm/container2wasm  (examples/emscripten)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

IMAGE="${IMAGE:-pasclaw:c2w}"
C2W="${C2W:-}"
C2W_VERSION="${C2W_VERSION:-v0.8.4}"
OUT="browser/site"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v docker >/dev/null || { echo "need docker on PATH"; exit 1; }
command -v npx    >/dev/null || { echo "need node + npm (npx) for the webpack bundle"; exit 1; }
command -v git    >/dev/null || { echo "need git on PATH"; exit 1; }
command -v curl   >/dev/null || { echo "need curl on PATH"; exit 1; }
command -v gzip   >/dev/null || { echo "need gzip on PATH"; exit 1; }

# Resolve a c2w CLI: honour $C2W / PATH, else auto-download the pinned release
# into browser/.bin (git-ignored) so this stays a true one-shot.
ensure_c2w() {
  if [ -n "$C2W" ] && command -v "$C2W" >/dev/null 2>&1; then return; fi
  if command -v c2w >/dev/null 2>&1; then C2W=c2w; return; fi
  if [ -x "$REPO_ROOT/browser/.bin/c2w" ]; then C2W="$REPO_ROOT/browser/.bin/c2w"; return; fi
  local arch
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "unsupported arch $(uname -m); install c2w manually and re-run with C2W=/path/to/c2w"; exit 1 ;;
  esac
  echo "    c2w not found — downloading ${C2W_VERSION} (linux-${arch})"
  mkdir -p "$REPO_ROOT/browser/.bin"
  curl -fsSL "https://github.com/container2wasm/container2wasm/releases/download/${C2W_VERSION}/container2wasm-${C2W_VERSION}-linux-${arch}.tar.gz" \
    | tar xz -C "$REPO_ROOT/browser/.bin" c2w
  chmod +x "$REPO_ROOT/browser/.bin/c2w"
  C2W="$REPO_ROOT/browser/.bin/c2w"
}
ensure_c2w
echo "    using c2w: $C2W"

echo "==> 1/6  build the image with browser networking compiled in (C2W=1)"
docker build -f docker/Dockerfile --build-arg C2W=1 -t "$IMAGE" .

echo "==> 2/6  c2w --to-js : emscripten wasm + js into $OUT/"
rm -rf "$OUT"; mkdir -p "$OUT"
"$C2W" --to-js "$IMAGE" "$OUT/"

echo "==> 3/6  fetch the container2wasm example harness ($C2W_VERSION)"
git clone --depth 1 -b "$C2W_VERSION" \
  https://github.com/container2wasm/container2wasm.git "$WORK/c2w" 2>/dev/null \
  || git clone --depth 1 https://github.com/container2wasm/container2wasm.git "$WORK/c2w"
HT="$WORK/c2w/examples/emscripten/htdocs"
[ -d "$HT" ] || { echo "ERROR: examples/emscripten/htdocs missing in container2wasm $C2W_VERSION"; exit 1; }

echo "==> 4/6  webpack the harness and copy index.html + dist + xterm.css into $OUT/"
( cd "$HT" && { npm ci >/dev/null 2>&1 || npm install >/dev/null 2>&1; } && npx webpack )
cp "$HT/index.html" "$OUT/"
cp -R "$HT/dist" "$OUT/"
mkdir -p "$OUT/vendor"; cp "$HT/vendor/xterm.css" "$OUT/vendor/" 2>/dev/null || true

echo "==> 5/6  in-browser fetch() network stack (gzip'd next to the page)"
curl -fsSL -o "$WORK/np.wasm" \
  "https://github.com/container2wasm/container2wasm/releases/download/${C2W_VERSION}/c2w-net-proxy.wasm"
gzip -c "$WORK/np.wasm" > "$OUT/c2w-net-proxy.wasm.gzip"

echo "==> 6/6  enable cross-origin isolation on header-less static hosts"
cp browser/coi-serviceworker.js "$OUT/"
if ! grep -q coi-serviceworker "$OUT/index.html"; then
  sed -i 's#<head>#<head><script src="coi-serviceworker.js"></script>#' "$OUT/index.html"
fi

echo
echo "Done -> $OUT/   (static, manually deployable)"
echo "Local : python3 browser/serve.py $OUT     # open the printed http://localhost URL"
echo "Deploy: upload the CONTENTS of $OUT/ to any static host (keep the .wasm next to index.html)"
