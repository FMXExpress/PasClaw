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
#   - node + npm (npx)       (webpack bundles the xterm harness)
#   - git, curl, gzip
# The `c2w` CLI is auto-downloaded into browser/.bin if not on PATH (set C2W=).
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

echo "==> 1/7  build the image with browser networking compiled in (C2W=1)"
# Dockerfile lives at the repo root (`./Dockerfile`), not under docker/ --
# docker/ holds the README only. Omit `-f` so docker picks up the
# default ./Dockerfile under our build context.
docker build --build-arg C2W=1 -t "$IMAGE" .

echo "==> 2/7  derive a browser image: onboard (BYO API key) then run the agent"
# The normal image runs the gateway SERVER (no use in a single-user tab). For
# the browser, prompt for the provider + API key on first launch, then drop
# into the interactive chat agent. Both read the xterm's stdin. Override the
# command per-image here so docker/Dockerfile's default stays gateway.
BROWSER_IMAGE="${IMAGE}-browser"
docker build -t "$BROWSER_IMAGE" -f - . <<DOCKERFILE
FROM $IMAGE
ENTRYPOINT []
# Use a non-login shell + absolute paths: a login shell (sh -l) re-reads
# /etc/profile and resets PATH, dropping /opt/pasclaw, so bare "pasclaw"
# would be "not found".
CMD ["/bin/sh", "-c", "/opt/pasclaw/pasclaw onboard && exec /opt/pasclaw/pasclaw agent"]
DOCKERFILE

echo "==> 3/7  c2w --to-js : emscripten wasm + js into $OUT/"
rm -rf "$OUT"; mkdir -p "$OUT"
# c2w v0.8.4's internal Dockerfile clones ${SOURCE_REPO} (default
# https://github.com/ktock/container2wasm) at the pinned
# ${SOURCE_REPO_VERSION} for build assets. ktock's repo no longer
# carries tags (the project moved to its own org), so the default
# clone now 500's with `Remote branch v0.8.4 not found in upstream
# origin`. Forward a docker --build-arg through c2w's --build-arg
# passthrough so the assets stage clones the still-tagged
# container2wasm/container2wasm fork instead. Override via the
# C2W_SOURCE_REPO env if a future upstream move breaks this again.
C2W_SOURCE_REPO="${C2W_SOURCE_REPO:-https://github.com/container2wasm/container2wasm}"
"$C2W" --to-js \
  --build-arg "SOURCE_REPO=$C2W_SOURCE_REPO" \
  "$BROWSER_IMAGE" "$OUT/"

echo "==> 4/7  fetch the container2wasm example harness ($C2W_VERSION)"
git clone --depth 1 -b "$C2W_VERSION" \
  https://github.com/container2wasm/container2wasm.git "$WORK/c2w" 2>/dev/null \
  || git clone --depth 1 https://github.com/container2wasm/container2wasm.git "$WORK/c2w"
HT="$WORK/c2w/examples/emscripten/htdocs"
[ -d "$HT" ] || { echo "ERROR: examples/emscripten/htdocs missing in container2wasm $C2W_VERSION"; exit 1; }

echo "==> 5/7  webpack the harness and copy index.html + dist + xterm.css into $OUT/"
( cd "$HT" && { npm ci >/dev/null 2>&1 || npm install >/dev/null 2>&1; } && npx webpack )
cp "$HT/index.html" "$OUT/"
cp -R "$HT/dist" "$OUT/"
mkdir -p "$OUT/vendor"; cp "$HT/vendor/xterm.css" "$OUT/vendor/" 2>/dev/null || true

echo "==> 6/7  in-browser fetch() network stack (gzip'd next to the page)"
curl -fsSL -o "$WORK/np.wasm" \
  "https://github.com/container2wasm/container2wasm/releases/download/${C2W_VERSION}/c2w-net-proxy.wasm"
gzip -c "$WORK/np.wasm" > "$OUT/c2w-net-proxy.wasm.gzip"

echo "==> 7/7  cross-origin isolation shim + PasClaw UI chrome"
cp browser/coi-serviceworker.js "$OUT/"
if ! grep -q coi-serviceworker "$OUT/index.html"; then
  sed -i 's#<head>#<head><script src="coi-serviceworker.js"></script>#' "$OUT/index.html"
fi
# PasClaw page chrome (branding, boot screen, auto ?net=browser). Additive —
# the upstream terminal still boots if these are removed.
cp browser/web/pasclaw.css browser/web/pasclaw.js "$OUT/"
if ! grep -q pasclaw.js "$OUT/index.html"; then
  sed -i 's#<head>#<head>\n  <link rel="stylesheet" href="pasclaw.css">\n  <script src="pasclaw.js"></script>#' "$OUT/index.html"
fi

echo
echo "Done -> $OUT/   (static, manually deployable)"
echo "Local : npx http-server $OUT -p 8080   # then open  http://localhost:8080/?net=browser"
echo "Deploy: upload the CONTENTS of $OUT/ to any static host (keep the .wasm next to index.html)"
echo
echo "IMPORTANT: open the page with the  ?net=browser  query — it activates the"
echo "in-browser fetch() proxy that sets HTTP_PROXY/HTTPS_PROXY in the guest."
echo "Without it the agent's Anthropic calls have no network egress."
