#!/usr/bin/env bash
# Setup hook for fixture 14-prior-session.
#
# Stages a prior-session memory file as MARKDOWN under
# PASCLAW_HOME/workspace/memory/. memory_search's underlying SyncDir
# only indexes *.md files (per PasClaw.Memory.Index.pas), so an
# .ndjson file is invisible to FTS5. SyncDir runs lazily on the first
# search call, so no explicit provisioning is needed -- as long as the
# file extension is .md.
#
# The file contains nine unrelated decisions plus one about the
# note-storage serialization format (cbor). memory_search "serialization
# format storage" should rank the cbor section highest by BM25.
set -euo pipefail

MEM_DIR="$PASCLAW_HOME/workspace/memory"
mkdir -p "$MEM_DIR"

cat > "$MEM_DIR/2026-01-01.md" <<'MEM'
# 2026-01-01 — Storage architecture session

Working session on the new note-storage layer plus assorted runtime
decisions we'd been deferring.

## Note-storage serialization format

Benchmarked three options on the 1M-record bench:
- JSON: baseline at ~38 MB/s. Familiar but slowest.
- msgpack: ~92 MB/s but the python parser adds an external dep.
- cbor: ~80 MB/s with zero external dependencies (stdlib path works
  cleanly), self-describing format.

**Final decision: cbor for the note-storage layer.** Trade-offs:
13% slower than msgpack, 10% bigger on disk than protobuf, but zero
new deps and self-describing makes the migration story easier.

## Retry policy

Picked jittered exponential. base=200ms, max=30s, factor=2.0,
jitter range 0-100ms. Reject the constant-5s alternative — too
hostile to overloaded upstreams.

## Auth header scheme

Bearer token in Authorization header, refreshed via
`/v1/auth/refresh`. 401 triggers one silent refresh attempt; if THAT
also returns 401, propagate the error to the caller.

## Color palette for the TUI

Dim cyan / dim magenta pair for fg/accent. Stays readable on both
dark and light terminals. Reject the saturated-primary alternative —
clashes with terminal themes that already use bright colors.

## Log retention

30 days hot, archived to cold storage after that. Compress with
zstd -19 during the transition. Cold storage costs ~10x less per GB
at the volumes we project.

## Rate-limit window

Sliding window 60s, default 100 req/window per session, configurable
via `rate_limit.requests_per_window` in config.json.

## Scrollback buffer size

1MB worth of lines. Enough to keep the last 2-3 tool outputs in
active scroll without paging — verified against the largest fs_read
+ fs_grep combo we've seen in production.

## Version-bump policy

Semver, with the carve-out that 0.x can break minor (we're explicit
about it in the release notes). Promote to 1.0 only when we ship the
migration command for config.json.

## Test framework for the runtime

vitest. mocha was tempting but vitest's snapshot-on-first-run plus
the lazy in-source tests fit our trajectory better. The watch mode is
also a real productivity win during refactors.

## Bench harness for the agent loop

Custom python harness backed by a localhost OpenAI-compatible stub.
Lets us inject canned responses without burning model tokens during
iteration.
MEM

echo "setup complete -- memory file written ($(wc -l < "$MEM_DIR/2026-01-01.md") lines)"
