#!/bin/sh
# PasClaw container entrypoint.
#
# Used by the root Dockerfile for any container build (Docker Hub, DO
# App Platform, generic host). Responsibilities:
#
#   1. Ensure $PASCLAW_HOME exists and is writable.
#   2. Stamp the bundled config.template.json into $PASCLAW_HOME/config.json
#      on first boot. The template uses ${VAR_NAME} markers that PasClaw's
#      config loader resolves from environment variables (PR #247) -- so
#      secrets stay in env vars, never in the image.
#   3. exec `pasclaw $@` -- the Dockerfile's CMD passes
#      `gateway --addr 0.0.0.0 --port 8088` as the default args, but
#      operators running `docker run pasclaw version` / `agent -m "..."`
#      / etc. flow through verbatim.
#
# Operators who want a custom config can mount their own config.json
# into $PASCLAW_HOME/config.json BEFORE container start; we never
# clobber an existing file.

set -eu

: "${PASCLAW_HOME:=/home/pasclaw/.pasclaw}"

mkdir -p "$PASCLAW_HOME/workspace"

if [ ! -f "$PASCLAW_HOME/config.json" ]; then
  cp /etc/pasclaw/config.template.json "$PASCLAW_HOME/config.json"
  echo "[entrypoint] stamped $PASCLAW_HOME/config.json from template" >&2
fi

# Default to the gateway when no command is given; otherwise pass
# through whatever the Dockerfile's CMD (or `docker run` override) set.
if [ $# -eq 0 ]; then
  set -- gateway --addr 0.0.0.0 --port "${PORT:-8088}"
fi

exec pasclaw "$@"
