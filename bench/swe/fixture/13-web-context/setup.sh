#!/usr/bin/env bash
# Setup hook for fixture 13-web-context.
# Starts a tiny localhost HTTP server that serves a spec at /spec.txt. Writes
# the URL to spec_url.txt in the workspace so the agent can find it.
#
# The server PID is saved to $RUN_DIR/web_server.pid so finalize_cell.sh can
# kill it cleanly. (finalize doesn't know about it explicitly, but trap on
# pasclaw.pid exiting will leave the process running; that's fine -- the
# workspace is torn down at the end of the bench.)
set -euo pipefail

SPEC_DIR="$RUN_DIR/web_spec"
mkdir -p "$SPEC_DIR"

cat > "$SPEC_DIR/spec.txt" <<'SPEC'
TRANSFORM SPEC v1
=================

Implement a function `transform(rows)` in Python with this exact contract:

INPUT
  rows: an iterable of (int, str) 2-tuples. Example: [(1, "foo"), (2, "bar")].

OUTPUT
  A list of dicts, one per input row, in input order. Each dict has THREE
  keys (and only these three):

    "id"        -- the int from the tuple
    "label"     -- the str from the tuple, lowercased
    "fingerprint" -- the SHA-256 hex digest (lowercase) of the bytes
                     formed by concatenating str(id) + ":" + label_lowercased,
                     UTF-8 encoded. EXAMPLE: id=1, label="foo" produces
                     "1:foo" -> sha256 -> "e1d2dcdcbbe8a09ba00d2ab92f8f56...".

ERROR HANDLING
  - If the input is empty, return an empty list.
  - If any row's second element is None, raise ValueError with the message
    "label cannot be None".

NO OTHER KEYS, NO EXTRA OUTPUT. Match the contract exactly or the test fails.
SPEC

# Start the server in the background. Bind to 0 to pick a free port.
# We need the chosen port back, so use a tiny Python wrapper that prints it.
python3 - "$SPEC_DIR" > "$RUN_DIR/web_server.out" 2>&1 <<'PY' &
import sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
spec_dir = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): return
    def do_GET(self):
        if self.path != "/spec.txt":
            self.send_response(404); self.end_headers(); return
        with open(spec_dir + "/spec.txt", "rb") as fh:
            body = fh.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
print("PORT=%d" % srv.server_address[1], flush=True)
srv.serve_forever()
PY
echo "$!" > "$RUN_DIR/web_server.pid"

# Wait for the PORT line
for i in $(seq 1 20); do
  if grep -q "^PORT=" "$RUN_DIR/web_server.out" 2>/dev/null; then break; fi
  sleep 0.2
done
PORT=$(grep -oE "^PORT=[0-9]+" "$RUN_DIR/web_server.out" | head -1 | cut -d= -f2)
if [ -z "${PORT:-}" ]; then
  echo "web server failed to bind" >&2
  exit 1
fi

echo "http://127.0.0.1:$PORT/spec.txt" > "$WORKSPACE/spec_url.txt"
echo "setup complete -- web server on port $PORT, url written to spec_url.txt"
