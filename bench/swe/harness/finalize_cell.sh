#!/usr/bin/env bash
# Wait for pasclaw to exit, then run the oracle and emit result.json.
#
# Usage:
#   finalize_cell.sh <run_dir> [wait_seconds]
#
# Idempotent -- safe to call after pasclaw has already exited.

set -euo pipefail
RUN_DIR="${1:?run dir required}"
WAIT_S="${2:-300}"

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"

if [ ! -f "$RUN_DIR/pasclaw.pid" ]; then
  echo "no pasclaw.pid in $RUN_DIR" >&2
  exit 1
fi
PASCLAW_PID="$(cat "$RUN_DIR/pasclaw.pid")"
STUB_PID="$(cat "$RUN_DIR/stub.pid")"

# Wait for pasclaw to exit (bounded). 0 = clean exit, non-zero = error / timeout
deadline=$(($(date +%s) + WAIT_S))
while kill -0 "$PASCLAW_PID" 2>/dev/null; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "[finalize] pasclaw still running after ${WAIT_S}s, killing" >&2
    kill -TERM "$PASCLAW_PID" 2>/dev/null || true
    sleep 2
    kill -KILL "$PASCLAW_PID" 2>/dev/null || true
    break
  fi
  sleep 1
done
PASCLAW_RC=$?  # unreliable since the loop guard, recompute below

# Real exit code: pasclaw is detached from us, so we can't `wait`. Read it from
# pasclaw.stderr (PasClaw doesn't emit a marker, so fall back to "0 if exited,
# else 124 timeout").
if kill -0 "$PASCLAW_PID" 2>/dev/null; then
  PASCLAW_RC=124
else
  PASCLAW_RC=0
fi

# Stop the stub
kill -TERM "$STUB_PID" 2>/dev/null || true
sleep 1
kill -KILL "$STUB_PID" 2>/dev/null || true

T_START=$(cat "$RUN_DIR/t-start")
WALL_S=$(( $(date +%s) - T_START ))
FIXTURE_DIR="$(cat "$RUN_DIR/fixture-dir")"
VARIANT_JSON="$(cat "$RUN_DIR/variant.json")"

# Run the oracle
ORACLE_CMD=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["oracle"]["cmd"])' "$FIXTURE_DIR/manifest.json")
ORACLE_OUT="$RUN_DIR/oracle.stdout"
ORACLE_ERR="$RUN_DIR/oracle.stderr"
ORACLE_RC=0
( cd "$RUN_DIR/workspace" && FIXTURE_DIR="$FIXTURE_DIR" WORKSPACE="$RUN_DIR/workspace" bash -c "$ORACLE_CMD" ) > "$ORACLE_OUT" 2> "$ORACLE_ERR" || ORACLE_RC=$?

# Compute metrics + write result.json
python3 - "$RUN_DIR" "$FIXTURE_DIR" "$VARIANT_JSON" "$WALL_S" "$PASCLAW_RC" "$ORACLE_RC" <<'PY'
import json, os, sys
run_dir, fixture_dir, variant_json, wall_s, pasclaw_rc, oracle_rc = sys.argv[1:7]
fixture = json.load(open(os.path.join(fixture_dir, "manifest.json")))
variant = json.loads(variant_json)

# Parse stub.log for per-turn events
turns = []
log_path = os.path.join(run_dir, "stub.log")
if os.path.exists(log_path):
    for line in open(log_path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line: continue
        try: obj = json.loads(line)
        except json.JSONDecodeError: continue
        if obj.get("event") == "turn": turns.append(obj)
metrics = {
    "turn_count":       len(turns),
    "tokens_in":        sum(t.get("tokens_in", 0) for t in turns),
    "tokens_out":       sum(t.get("tokens_out", 0) for t in turns),
    "tool_calls":       sum(t.get("tool_calls", 0) for t in turns),
    "total_elapsed_ms": sum(t.get("elapsed_ms", 0) for t in turns),
}

# Out-of-scope edits (compare workspace to scope_paths from manifest)
scope = fixture.get("scope_paths") or []
pre = os.path.join(fixture_dir, "pre-fix")
pre_files = set()
if os.path.isdir(pre):
    for root, _, files in os.walk(pre):
        for fn in files:
            full = os.path.join(root, fn)
            pre_files.add(os.path.relpath(full, pre))
ws = os.path.join(run_dir, "workspace")
oos = 0
prefixes = tuple(scope)
for root, _, files in os.walk(ws):
    for fn in files:
        full = os.path.join(root, fn)
        rel = os.path.relpath(full, ws)
        if rel in pre_files: continue
        if prefixes and rel.startswith(prefixes): continue
        oos += 1

passed = (oracle_rc == "0")
oracle_stdout = open(os.path.join(run_dir, "oracle.stdout")).read()[-2000:]
oracle_stderr = open(os.path.join(run_dir, "oracle.stderr")).read()[-2000:]

result = {
    "run_id": open(os.path.join(run_dir, "run-id")).read().strip(),
    "fixture": fixture["name"],
    "variant": variant,
    "passed": passed,
    "pasclaw_exit_code": int(pasclaw_rc),
    "wall_clock_s": int(wall_s),
    "metrics": metrics,
    "oos_edits": oos,
    "oracle": {
        "passed": passed,
        "exit_code": int(oracle_rc),
        "stdout": oracle_stdout,
        "stderr": oracle_stderr,
    },
}
with open(os.path.join(run_dir, "result.json"), "w") as fh:
    json.dump(result, fh, indent=2)
print(json.dumps(result))
PY
