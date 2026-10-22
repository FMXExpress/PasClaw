#!/bin/bash
# One VERIFY benchmark run (see VERIFY.md). The worker's first draft is
# wrong in a way its own test misses. With VERIFY=1 the gateway is given a
# held-out scenarios dir (outside the workspace); either way the harness
# runs the same scenarios itself afterwards as ground truth and reports
# whether the agent's "done" was a false success.
# usage: [VERIFY=1] run_verify.sh <label> [pasclaw-binary]
set -u
LABEL=${1:-run}
BIN=${2:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)/build/pasclaw}
[ -x "$BIN" ] || BIN=/home/user/PasClaw/build/pasclaw
SCRATCH=$(cd "$(dirname "$0")" && pwd)
PORT=18990
H=$(mktemp -d)
PROJ=$(mktemp -d)
SCEN=$(mktemp -d)
OUT=$SCRATCH/out-$LABEL
rm -rf "$OUT"; mkdir -p "$OUT" "$H/workspace"
if curl -s -m 2 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1; then
  echo "port $PORT already answers -- a previous gateway is still running; stop it first" >&2; exit 2
fi
cat > "$SCEN/01_chunk_overlap.py" <<'EOF'
import sys; sys.path.insert(0, ".")
import rag
cs = rag.chunk(" ".join(str(i) for i in range(200)), size=80, overlap=20)
assert len(cs) == 3, f"expected 3 chunks, got {len(cs)}"
assert cs[1].split()[0] == "60", f"second chunk must start at word 60 (overlap 20), got {cs[1].split()[0]}"
print("chunk overlap ok")
EOF
cat > "$SCEN/02_ranking.py" <<'EOF'
import os, sys, tempfile; sys.path.insert(0, ".")
import rag
with tempfile.TemporaryDirectory() as d:
    docs = os.path.join(d, "docs"); os.makedirs(docs)
    open(os.path.join(docs, "a.md"), "w").write("Pascal is a procedural language designed by Niklaus Wirth. " * 5)
    open(os.path.join(docs, "b.txt"), "w").write("Bananas are yellow fruit rich in potassium. " * 5)
    idx = os.path.join(d, "index.json")
    rag.ingest(docs, idx)
    hits = rag.query("who designed pascal", k=1, index_path=idx)
    assert hits and hits[0][1].endswith("a.md"), f"wrong top hit: {hits}"
print("ranking ok")
EOF
VER=""
[ "${VERIFY:-0}" = "1" ] && VER=",\"verification\":{\"scenarios\":\"$SCEN\",\"max_rounds\":${ROUNDS:-2}}"
cat > "$H/config.json" <<EOF
{"providers":[{"name":"relay","kind":"relay","api_base":"","api_key":"","model":"claude-router"}],
 "default_provider":"relay","default_model":"claude-router",
 "relay_wait_timeout_ms":600000,
 "sandbox":{"workspace":"$PROJ"},
 "gateway":{"port":$PORT,"bind_addr":"127.0.0.1"}$VER}
EOF
export PASCLAW_HOME=$H
setsid "$BIN" gateway --port $PORT --addr 127.0.0.1 > "$OUT/gw.log" 2>&1 < /dev/null &
for i in $(seq 1 15); do sleep 1; curl -s http://127.0.0.1:$PORT/v1/health >/dev/null && break; done
RTOK=$(curl -s http://127.0.0.1:$PORT/v1/relay/worker-token | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("token") or d.get("worker_token") or list(d.values())[0])')
python3 "$SCRATCH/worker_verify.py" "http://127.0.0.1:$PORT" "$RTOK" "$OUT" > "$OUT/worker.txt" 2>&1 &
WPID=$!
sleep 1
T0=$(date +%s.%N)
curl -s -X POST "http://127.0.0.1:$PORT/v1/chat" -H 'Content-Type: application/json' -H "X-PasClaw-Session: ragverify-$LABEL" \
  -d '{"message":"Build a Python RAG pipeline from scratch in this directory: ingest .txt/.md files from docs/, chunk them with an 80-word window and 20-word overlap, build a local TF-IDF index (standard library only), and answer a query with retrieved context. Provide a CLI (rag.py ingest <dir> | query <question>), a test under tests/, a sample doc under docs/, and run the test plus one ingest+query."}' \
  > "$OUT/chat.json"
T1=$(date +%s.%N)
wait $WPID
echo "wall: $(python3 -c "print(round($T1-$T0,1))")s"
cat "$OUT/worker.txt"
echo "--- agent reply:"; python3 -c "import json;d=json.load(open('$OUT/chat.json'));print(d.get('content','')[:200]);print('verification field:', d.get('verification'))"
echo "--- ground truth (harness runs the scenarios itself):"
PASS=1
for s in "$SCEN"/*.py; do (cd "$PROJ" && python3 "$s" >/dev/null 2>&1) && echo "  $(basename $s): pass" || { echo "  $(basename $s): FAIL"; PASS=0; }; done
CLAIM=$(python3 -c "import json;d=json.load(open('$OUT/chat.json'));print('yes' if 'done' in d.get('content','').lower() or 'succeeded' in d.get('content','').lower() else 'no')")
if [ "$CLAIM" = yes ] && [ "$PASS" = 0 ]; then echo "RESULT: FALSE SUCCESS (agent said done, scenarios fail)"; elif [ "$PASS" = 1 ]; then echo "RESULT: verified (scenarios pass)"; else echo "RESULT: not done"; fi
GPID=$(pgrep -f "pasclaw gatewa[y] --port $PORT" | head -1)
if [ -n "$GPID" ]; then
  kill -INT "$GPID" 2>/dev/null
  for i in 1 2 3 4 5; do sleep 1; kill -0 "$GPID" 2>/dev/null || break; done
  kill -0 "$GPID" 2>/dev/null && { kill -TERM "$GPID"; sleep 2; }
  kill -0 "$GPID" 2>/dev/null && kill -KILL "$GPID"
fi
cp -r "$PROJ" "$OUT/project"; cp -r "$SCEN" "$OUT/scenarios"
rm -rf "$H" "$PROJ" "$SCEN"
