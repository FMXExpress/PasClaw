#!/bin/bash
# One benchmark run: scratch home + empty project dir, gateway with the relay
# provider, the playbook worker as the model, one /v1/chat task. Prints the
# worker's size table and the session's token stats.
# usage: run.sh <label> [pasclaw-binary]
set -u
LABEL=${1:-run}
BIN=${2:-$(cd "$(dirname "$0")/../.." && pwd)/build/pasclaw}
SCRATCH=$(cd "$(dirname "$0")" && pwd)
PORT=18990
H=$(mktemp -d)
PROJ=$(mktemp -d)
OUT=$SCRATCH/out-$LABEL
rm -rf "$OUT"; mkdir -p "$OUT" "$H/workspace"
if curl -s -m 2 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1; then
  echo "port $PORT already answers -- a previous gateway is still running; stop it first" >&2; exit 2
fi
cat > "$H/config.json" <<EOF
{"providers":[{"name":"relay","kind":"relay","api_base":"","api_key":"","model":"claude-router"}],
 "default_provider":"relay","default_model":"claude-router",
 "relay_wait_timeout_ms":600000,"stats_collection_enabled":true,
 "sandbox":{"workspace":"$PROJ"},
 "gateway":{"port":$PORT,"bind_addr":"127.0.0.1"}}
EOF
export PASCLAW_HOME=$H
setsid "$BIN" gateway --port $PORT --addr 127.0.0.1 ${NOMCP:-} > "$OUT/gw.log" 2>&1 < /dev/null &
for i in $(seq 1 15); do sleep 1; curl -s http://127.0.0.1:$PORT/v1/health >/dev/null && break; done
RTOK=$(curl -s http://127.0.0.1:$PORT/v1/relay/worker-token | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("token") or d.get("worker_token") or list(d.values())[0])')
echo "relay token: $RTOK"
python3 "$SCRATCH/worker.py" "http://127.0.0.1:$PORT" "$RTOK" "$OUT" > "$OUT/worker.txt" 2>&1 &
WPID=$!
sleep 1
T0=$(date +%s.%N)
curl -s -X POST "http://127.0.0.1:$PORT/v1/chat" -H 'Content-Type: application/json' -H "X-PasClaw-Session: ragbench-$LABEL" \
  -d '{"message":"Build a Python RAG pipeline from scratch in this directory: ingest .txt/.md files from docs/, chunk them, build a local TF-IDF index (no network, standard library only), and answer a query with retrieved context. Provide a CLI (rag.py ingest <dir> | query <question>), a small test under tests/, a sample doc under docs/, and run the test plus one ingest+query to prove it works."}' \
  > "$OUT/chat.json"
T1=$(date +%s.%N)
wait $WPID
echo "wall: $(python3 -c "print(round($T1-$T0,1))")s"
cat "$OUT/worker.txt"
echo "--- session stats:"
python3 - "$H/workspace/sessions/ragbench-$LABEL.json" <<'EOF'
import json,sys
try:
    m=json.load(open(sys.argv[1]))["meta"]; s=m.get("stats",{})
    print({k:s.get(k) for k in ("input_tokens","output_tokens","turns","tool_calls")})
except Exception as e:
    print("no session stats:", e)
EOF
echo "--- project tree:"; (cd "$PROJ" && find . -type f | sort)
echo "--- chat reply:"; python3 -c "import json;print(json.load(open('$OUT/chat.json')).get('reply') or json.load(open('$OUT/chat.json')))" | cut -c1-300
GPID=$(python3 -c "import json;print(json.load(open('$H/run/gateway.json'))['pid'])" 2>/dev/null)
[ -z "$GPID" ] && GPID=$(pgrep -f "pasclaw gatewa[y] --port $PORT" | head -1)   # builds without run/gateway.json
if [ -n "$GPID" ]; then
  # Stop politely, then insist: builds without the stop-signal handler ignore SIGINT.
  kill -INT "$GPID" 2>/dev/null
  for i in 1 2 3 4 5; do sleep 1; kill -0 "$GPID" 2>/dev/null || break; done
  kill -0 "$GPID" 2>/dev/null && { kill -TERM "$GPID"; sleep 2; }
  kill -0 "$GPID" 2>/dev/null && kill -KILL "$GPID"
fi
cp -r "$PROJ" "$OUT/project"
rm -rf "$H" "$PROJ"
