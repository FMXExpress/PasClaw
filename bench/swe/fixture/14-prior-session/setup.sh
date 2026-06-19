#!/usr/bin/env bash
# Setup hook for fixture 14-prior-session.
# Pre-populates PASCLAW_HOME/workspace/memory/ with a 32-entry NDJSON log
# that simulates a prior conversation. The correct answer ("cbor") appears
# in exactly one entry, buried among distractors.
set -euo pipefail

MEM_DIR="$PASCLAW_HOME/workspace/memory"
mkdir -p "$MEM_DIR"

# A 32-entry conversation log. The KEY entry is the one announcing the
# decision; surrounding entries are distractors discussing OTHER topics
# (auth scheme, retry policy, color palette, etc.). To distinguish the
# fixture from "model just guesses cbor", we use cbor specifically
# because it's plausible but uncommon enough that the right answer
# requires reading the log.

LOG="$MEM_DIR/20260101T120000-prev.ndjson"
python3 - "$LOG" <<'PY'
import json, sys, time

path = sys.argv[1]
turns = [
    ("user", "hey, picking back up on the note-storage layer from yesterday"),
    ("assistant", "right -- the indexing question, or the serialization format?"),
    ("user", "the serialization. you'd benchmarked three options"),
    ("assistant",
     "yep. quick recap: JSON was the baseline at ~38 MB/s on the 1M-record bench, "
     "msgpack landed ~92 MB/s but the python parser added a noticeable dep, and "
     "cbor came in at ~80 MB/s with zero external deps (cbor2 in the stdlib path). "
     "given we want pure-stdlib for the runtime, cbor wins."),
    ("user", "ok so we go with cbor. write that down as the decision"),
    ("assistant",
     "noted. final call for storage layer: cbor. trade-offs: 13% slower than msgpack, "
     "10% bigger on disk than protobuf, but zero new deps and self-describing."),
    # distractors
    ("user", "while you're at it -- what about the retry policy"),
    ("assistant",
     "we sketched three: exponential backoff capped at 30s, fixed 5s, and "
     "jittered exponential. picked jittered exponential with base=200ms, max=30s, "
     "factor=2.0, jitter range 0-100ms."),
    ("user", "and the auth header scheme"),
    ("assistant",
     "bearer token in Authorization header, refreshed via /v1/auth/refresh. "
     "401 responses trigger one silent refresh then propagate the error if it "
     "fails again."),
    ("user", "color palette for the TUI -- we said dim primary or saturated?"),
    ("assistant",
     "dim primary. specifically the dim cyan/dim magenta pair for fg/accent so "
     "we stay readable on both dark and light terminals."),
    ("user", "log retention?"),
    ("assistant",
     "30 days hot, archived to cold storage after that. compress with zstd -19 "
     "during the transition."),
    ("user", "rate-limit window"),
    ("assistant",
     "sliding window 60s, default 100 req/window per session, configurable in "
     "config.json under rate_limit.requests_per_window."),
    ("user", "scrollback buffer size for the agent's view"),
    ("assistant",
     "we landed on 1MB lines worth. enough to keep the last 2-3 tool outputs "
     "in active scroll without paging."),
    ("user", "version-bump policy"),
    ("assistant",
     "semver, with the catch that 0.x can break minor. promote to 1.0 only when "
     "we ship the migration command for config.json."),
    ("user", "let's lock in the test framework choice for the runtime"),
    ("assistant",
     "vitest. mocha was tempting but vitest's snapshot-on-first-run + lazy "
     "in-source tests fit our trajectory better."),
    ("user", "ok last one -- bench harness for the agent loop"),
    ("assistant",
     "custom python harness backed by a localhost openai-compatible stub. "
     "lets us inject canned responses without burning model tokens."),
]
with open(path, "w") as fh:
    base_ts = int(time.time())
    for i, (role, content) in enumerate(turns):
        rec = {
            "ts": base_ts + i,
            "role": role,
            "content": content,
            "session": "20260101T120000-prev",
        }
        fh.write(json.dumps(rec) + "\n")
PY

echo "setup complete -- prior-session log written ($(wc -l < "$LOG") entries)"
