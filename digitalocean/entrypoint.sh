#!/bin/sh
# PasClaw container entrypoint for DigitalOcean App Platform.
#
# Responsibilities (in order):
#   1. Ensure $PASCLAW_HOME exists and is writable.
#   2. Stamp the bundled config.template.json into $PASCLAW_HOME/config.json
#      on first boot. The template uses ${VAR_NAME} markers that PasClaw's
#      config loader resolves from environment variables (PR #247) -- so
#      secrets stay in env vars, never in the image.
#   3. exec `pasclaw gateway` bound to 0.0.0.0:$PORT.
#
# Operators who want a custom config can mount their own config.json into
# $PASCLAW_HOME/config.json BEFORE container start; we never clobber an
# existing file.

set -eu

: "${PASCLAW_HOME:=/data/pasclaw}"
: "${PORT:=8088}"

mkdir -p "$PASCLAW_HOME/workspace"

if [ ! -f "$PASCLAW_HOME/config.json" ]; then
  cp /etc/pasclaw/config.template.json "$PASCLAW_HOME/config.json"
  echo "[entrypoint] stamped $PASCLAW_HOME/config.json from template" >&2
fi

# Bind to all interfaces -- DO App Platform routes external traffic to the
# container's listening port. --port overrides whatever's in config.json so
# operators can change the port via the App Spec without editing the
# template.
exec pasclaw gateway --addr 0.0.0.0 --port "$PORT" "$@"
