#!/usr/bin/env bash
# Stage a (fixture x variant) cell for live driving, leaving the stub + pasclaw
# running in the background. Prints a JSON manifest with all the paths the
# driver needs.
#
# Usage:
#   start_cell.sh <fixture_dir> <variant_json> <run_id>
#
# After this returns, the driver should:
#   1. Poll <queue>/req_N.json via driver_helper.py next-request
#   2. Author an OpenAI chat-completion response, publish via send-reply
#   3. Repeat until pasclaw exits (poll <run_dir>/pasclaw.pid)
#   4. Call finalize_cell.sh <run_dir>

set -euo pipefail
FIXTURE_DIR="${1:?fixture dir required}"
VARIANT_JSON="${2:?variant JSON required}"
RUN_ID="${3:?run id required}"

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_SWE_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BENCH_SWE_ROOT/../.." && pwd)"
PASCLAW_BIN="$REPO_ROOT/build/pasclaw"
BENCH_ROOT="$BENCH_SWE_ROOT"

RUN_DIR="$BENCH_ROOT/results/run-$RUN_ID"
mkdir -p "$RUN_DIR"/{pasclaw-home,workspace,queue}
echo "$RUN_ID"  > "$RUN_DIR/run-id"
echo "$FIXTURE_DIR" > "$RUN_DIR/fixture-dir"
echo "$VARIANT_JSON" > "$RUN_DIR/variant.json"

# Stage fixture pre-fix tree into the workspace
if [ -d "$FIXTURE_DIR/pre-fix" ]; then
  cp -r "$FIXTURE_DIR/pre-fix/." "$RUN_DIR/workspace/"
fi

# Start the blocking stub
python3 "$HARNESS_DIR/provider_stub.py" \
    --blocking "$RUN_DIR/queue" \
    --blocking-timeout-s 900 \
    > "$RUN_DIR/stub.stdout" 2> "$RUN_DIR/stub.log" &
STUB_PID=$!
echo "$STUB_PID" > "$RUN_DIR/stub.pid"

# Wait for PORT=N line (max 10s)
for i in $(seq 1 20); do
  if grep -q "^PORT=" "$RUN_DIR/stub.stdout" 2>/dev/null; then break; fi
  sleep 0.5
done
PORT=$(grep -oE "^PORT=[0-9]+" "$RUN_DIR/stub.stdout" | head -1 | cut -d= -f2)
if [ -z "${PORT:-}" ]; then
  echo "stub failed to bind" >&2
  cat "$RUN_DIR/stub.log" >&2
  exit 1
fi

# Build the config.json pointing pasclaw at the stub
python3 - "$RUN_DIR/pasclaw-home/config.json" "$PORT" "$VARIANT_JSON" <<'PY'
import json, sys
out_path, port, variant_json = sys.argv[1], int(sys.argv[2]), sys.argv[3]
variant = json.loads(variant_json)
cfg = {
    "providers": [{
        "name": "stub",
        "kind": "openai",
        "api_key": "sk-bench-stub",
        "api_base": "http://127.0.0.1:%d" % port,
        "model": "stub",
    }],
    "default_provider": "stub",
}
cfg.update(variant.get("config_overrides", {}))
with open(out_path, "w") as fh:
    json.dump(cfg, fh, indent=2)
PY

# Build pasclaw argv from the variant
python3 - "$RUN_DIR/argv.json" "$VARIANT_JSON" "$PASCLAW_BIN" \
        "$RUN_DIR/workspace" "$FIXTURE_DIR/manifest.json" <<'PY'
import json, sys
out_path, variant_json, pasclaw_bin, workspace, manifest_path = sys.argv[1:6]
variant = json.loads(variant_json)
manifest = json.load(open(manifest_path))
argv = [
    pasclaw_bin, "--no-color", "build",
    "-d", manifest["prompt"],
    "--cwd", workspace,
    "--provider", "stub", "--model", "stub",
    "--max-iters", str(variant.get("max_iters", 20)),
]
if variant.get("profile"):    argv += ["--profile",    variant["profile"]]
if variant.get("mode"):       argv += ["--mode",       variant["mode"]]
if variant.get("no_tools"):   argv += ["--no-tools"]
if variant.get("no_mcp"):     argv += ["--no-mcp"]
if variant.get("system_prompt"): argv += ["--system", variant["system_prompt"]]
with open(out_path, "w") as fh:
    json.dump(argv, fh, indent=2)
PY

# Start pasclaw in background, argv loaded from argv.json
PASCLAW_PID=$(python3 - "$RUN_DIR" <<'PY'
import json, os, subprocess, sys
run_dir = sys.argv[1]
argv = json.load(open(os.path.join(run_dir, "argv.json")))
env = os.environ.copy()
env["PASCLAW_HOME"] = os.path.join(run_dir, "pasclaw-home")
env["NO_COLOR"] = "1"
with open(os.path.join(run_dir, "pasclaw.stdout"), "wb") as out, \
     open(os.path.join(run_dir, "pasclaw.stderr"), "wb") as err:
    p = subprocess.Popen(argv, env=env, stdout=out, stderr=err,
                         stdin=subprocess.DEVNULL, start_new_session=True)
print(p.pid)
PY
)
echo "$PASCLAW_PID" > "$RUN_DIR/pasclaw.pid"
date +%s > "$RUN_DIR/t-start"

# Emit a JSON manifest with everything the driver needs
python3 - "$RUN_DIR" "$PORT" "$STUB_PID" "$PASCLAW_PID" <<'PY'
import json, sys
run_dir, port, stub_pid, pasclaw_pid = sys.argv[1:5]
print(json.dumps({
    "run_dir":     run_dir,
    "queue":       run_dir + "/queue",
    "workspace":   run_dir + "/workspace",
    "port":        int(port),
    "stub_pid":    int(stub_pid),
    "pasclaw_pid": int(pasclaw_pid),
}, indent=2))
PY
