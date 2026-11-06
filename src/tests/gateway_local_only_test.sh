#!/bin/sh
# Live check of the gateway's guard for a token-less listener, through real
# HTTP: what a browser on another site sends is refused, what a local client
# sends is not, and an unset ${PASCLAW_GATEWAY_TOKEN} marker is no token.
# gateway_token_tests pins the decision function; this pins its wiring.
#
#   gateway_local_only_test.sh <pasclaw binary> <scratch dir>
#
# Two gateways on ports unlikely to clash:
#   A (8796) -- config token "${PASCLAW_GATEWAY_TOKEN}", variable unset, and
#               gateway.allowed_hosts ["proxy.example"]
#   B (8797) -- a real token from the environment
set -u
BIN=$1
WORK=$2
fails=0
pids=""

cleanup() { for p in $pids; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT INT TERM

# check NAME WANT CURL-ARGS... -- the status code must be WANT
check() {
  name=$1; want=$2; shift 2
  got=$(curl -s -o /dev/null -w '%{http_code}' "$@")
  if [ "$got" = "$want" ]; then echo "  ok: $name ($got)"
  else echo "FAIL: $name: got $got, want $want"; fails=$((fails+1)); fi
}
# check_not NAME BAD CURL-ARGS... -- anything but BAD
check_not() {
  name=$1; bad=$2; shift 2
  got=$(curl -s -o /dev/null -w '%{http_code}' "$@")
  if [ "$got" != "$bad" ]; then echo "  ok: $name ($got)"
  else echo "FAIL: $name: got $got"; fails=$((fails+1)); fi
}
wait_up() {
  i=0
  until curl -sf -o /dev/null "http://127.0.0.1:$1/v1/health" || [ $i -ge 40 ]; do
    i=$((i+1)); sleep 0.25
  done
}

rm -rf "$WORK"; mkdir -p "$WORK/a" "$WORK/b"
printf '{ "gateway": { "bind_addr": "127.0.0.1", "port": 8796,\n  "token": "${PASCLAW_GATEWAY_TOKEN}", "allowed_hosts": ["proxy.example"] } }\n' \
  > "$WORK/a/config.json"
PASCLAW_HOME="$WORK/a" env -u PASCLAW_GATEWAY_TOKEN -u OPENCLAW_GATEWAY_TOKEN \
  "$BIN" gateway --port 8796 > "$WORK/a/gateway.log" 2>&1 &
pids="$pids $!"
PASCLAW_HOME="$WORK/b" PASCLAW_GATEWAY_TOKEN=real-token-0123456789abcdef \
  "$BIN" gateway --port 8797 > "$WORK/b/gateway.log" 2>&1 &
pids="$pids $!"
wait_up 8796; wait_up 8797

A=http://127.0.0.1:8796
B=http://127.0.0.1:8797
echo "-- no token (an unset \${PASCLAW_GATEWAY_TOKEN}):"
check "a local client" 200 "$A/v1/config"
check "the web UI (same origin)" 200 -H "Origin: http://127.0.0.1:8796" "$A/v1/config"
check "a cross-site text/plain POST" 403 -X POST -H "Origin: https://evil.example" \
  -H "Content-Type: text/plain" --data '{"text":"planted"}' "$A/v1/memory/facts"
check "an opaque Origin" 403 -X POST -H "Origin: null" \
  -H "Content-Type: text/plain" --data '{"text":"planted"}' "$A/v1/memory/facts"
check "another local port (the apps origin)" 403 -X POST -H "Origin: http://127.0.0.1:8798" \
  -H "Content-Type: text/plain" --data '{"text":"planted"}' "$A/v1/memory/facts"
check "a cross-site GET" 403 -H "Sec-Fetch-Site: cross-site" "$A/v1/config"
check "a same-site GET (the apps origin's iframe)" 200 -H "Sec-Fetch-Site: same-site" "$A/v1/config"
check "a rebound name" 403 -H "Host: attacker.example:8796" "$A/v1/config"
check "health under a rebound name (exempt)" 200 -H "Host: attacker.example:8796" "$A/v1/health"
check "an allowed name, from its own page" 200 -H "Host: proxy.example" \
  -H "Origin: https://proxy.example" "$A/v1/config"
RELAY=$(curl -s "$A/v1/relay/worker-token" | sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')
check_not "the relay surface with its token, from an opaque origin" 403 \
  -H "Origin: null" -H "Authorization: Bearer $RELAY" "$A/v1/relay/status"
check_not "the relay surface's CORS preflight" 403 -X OPTIONS -H "Origin: https://worker.example" \
  -H "Access-Control-Request-Method: GET" "$A/v1/relay/poll"
if curl -s "$A/v1/memory/facts" | grep -q planted; then
  echo "FAIL: a refused request planted a fact"; fails=$((fails+1))
else echo "  ok: nothing refused was planted"; fi

echo "-- a real token:"
check "the marker's text is no credential" 401 \
  -H 'Authorization: Bearer ${PASCLAW_GATEWAY_TOKEN}' "$B/v1/config"
check "the token works from anywhere (it is the gate)" 200 \
  -H "Authorization: Bearer real-token-0123456789abcdef" \
  -H "Origin: https://app.example" -H "Host: app.example" "$B/v1/config"

[ $fails -eq 0 ] && echo "PASS" || exit 1
