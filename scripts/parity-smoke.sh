#!/usr/bin/env bash
# Live parity smoke test against a running PasClaw gateway.
#
# Exercises the gateway-side contracts the FMX Studio client depends on, so a
# regression shows up here instead of as a mystery in the UI. Everything below
# is API-level; the checks that need eyes on the app are listed at the end.
#
#   usage: scripts/parity-smoke.sh [BASE_URL] [TOKEN]
#          BASE_URL defaults to $PASCLAW_BASE or http://127.0.0.1:8080
#          TOKEN    defaults to $PASCLAW_GATEWAY_TOKEN (may be empty)
#
#   e.g.   scripts/parity-smoke.sh http://127.0.0.1:8088 "$PASCLAW_GATEWAY_TOKEN"
#
# Exit code is the number of failed checks (0 = all good).

set -uo pipefail

BASE="${1:-${PASCLAW_BASE:-http://127.0.0.1:8080}}"
TOKEN="${2:-${PASCLAW_GATEWAY_TOKEN:-}}"
BASE="${BASE%/}"

PASS=0
FAIL=0
SESSION=""
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -n "$TOKEN" ]; then AUTH=(-H "Authorization: Bearer $TOKEN"); else AUTH=(); fi

# Per-request ceiling. Without it a single blocking endpoint (e.g. a log
# follow/stream route answering a plain GET) stalls the whole run and the
# script prints nothing at all -- which is exactly what happened the first
# time this was pointed at a live gateway.
MAXT="${PASCLAW_SMOKE_TIMEOUT:-8}"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
note() { printf '  \033[2m%s\033[0m\n' "$*"; }

# check <description> <condition-string-found> <haystack>
has() { case "$3" in *"$2"*) ok "$1";; *) bad "$1 (missing: $2)";; esac; }

api() { # api METHOD PATH [BODY]
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS --max-time "$MAXT" -X "$m" "${AUTH[@]}" -H 'Content-Type: application/json' \
         --data-binary "$b" "$BASE$p"
  else
    curl -sS --max-time "$MAXT" -X "$m" "${AUTH[@]}" "$BASE$p"
  fi
}
code() { # code METHOD PATH [BODY]  -> http status only
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS --max-time "$MAXT" -o /dev/null -w '%{http_code}' -X "$m" "${AUTH[@]}" \
         -H 'Content-Type: application/json' --data-binary "$b" "$BASE$p"
  else
    curl -sS --max-time "$MAXT" -o /dev/null -w '%{http_code}' -X "$m" "${AUTH[@]}" "$BASE$p"
  fi
}

say "0. reachability + auth posture   ($BASE)"
H="$(code GET /v1/health)"
[ "$H" = "200" ] && ok "/v1/health -> 200" || bad "/v1/health -> $H (gateway up?)"
if [ -n "$TOKEN" ]; then
  U="$(curl -sS --max-time "$MAXT" -o /dev/null -w '%{http_code}' "$BASE/v1/models")"
  [ "$U" = "401" ] && ok "no-token request -> 401 (gateway is secured)" \
                   || bad "no-token request -> $U (expected 401; token not enforced)"
  A="$(code GET /v1/models)"
  [ "$A" = "200" ] && ok "token accepted -> 200" || bad "token rejected -> $A"
else
  note "no token supplied; skipping the auth checks"
fi

say "1. sessions: create -> list -> read"
SESSION="smoke-$(date +%s)"
R="$(api PUT "/v1/sessions/$SESSION" \
  '{"title":"parity smoke","messages":[{"role":"user","content":"hello"},{"role":"assistant","content":"hi"}]}')"
has "PUT /v1/sessions/<id> stores the session" '"id"' "$R"
R="$(api GET /v1/sessions)"
has "the new session appears in the list" "$SESSION" "$R"
R="$(api GET "/v1/sessions/$SESSION")"
has "GET returns the transcript" 'hello' "$R"

say "2. tool_details round-trip  (the card-alignment risk)"
api PUT "/v1/sessions/$SESSION" \
  '{"title":"parity smoke","messages":[{"role":"user","content":"run a tool"},{"role":"assistant","content":"done"}],"tool_details":[null,[{"kind":"call","name":"smoke_tool","args":"{}"}]]}' >/dev/null
R="$(api GET "/v1/sessions/$SESSION")"
has "tool_details survives PUT -> GET" 'smoke_tool' "$R"
note "index-alignment (card lands on the right turn) is a UI check -- see below"

say "3. export / import round-trip"
api GET "/v1/sessions/$SESSION/export" > "$TMP/exp.json"
if [ -s "$TMP/exp.json" ]; then ok "export returned a non-empty body"
else bad "export returned nothing"; fi
R="$(curl -sS --max-time "$MAXT" -X POST "${AUTH[@]}" -H 'Content-Type: application/json' \
      --data-binary @"$TMP/exp.json" "$BASE/v1/sessions/import")"
has "re-import of our own export succeeds" '"imported"' "$R"

CG='[{"title":"cg smoke","create_time":1700000000,"current_node":"a1","mapping":{"r":{"id":"r","message":null,"parent":null,"children":["u1"]},"u1":{"id":"u1","message":{"author":{"role":"user"},"content":{"content_type":"text","parts":["from chatgpt"]}},"parent":"r","children":["a1"]},"a1":{"id":"a1","message":{"author":{"role":"assistant"},"content":{"content_type":"text","parts":["reply"]}},"parent":"u1","children":[]}}}]'
R="$(api POST /v1/sessions/import "$CG")"
has "ChatGPT conversations.json imports" '"imported"' "$R"

printf '%s\n' \
  '{"type":"summary","summary":"claude smoke","leafUuid":"x"}' \
  '{"type":"user","uuid":"u1","message":{"role":"user","content":"from claude code"}}' \
  '{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"reply"}]}}' \
  > "$TMP/cc.jsonl"
R="$(curl -sS --max-time "$MAXT" -X POST "${AUTH[@]}" -H 'Content-Type: application/json' \
      --data-binary @"$TMP/cc.jsonl" "$BASE/v1/sessions/import")"
has "Claude Code .jsonl imports" '"imported"' "$R"

R="$(api POST /v1/sessions/import 'not a chat export at all')"
has "garbage import is refused with a clear error" 'unrecognized' "$R"

say "4. steering"
C="$(code POST /v1/steer '{"session":"'"$SESSION"'","text":"steer smoke"}')"
[ "$C" = "200" ] && ok "POST /v1/steer accepted" || bad "POST /v1/steer -> $C"
C="$(code POST /v1/steer '{"session":"'"$SESSION"'"}')"
[ "$C" = "400" ] && ok "steer without text -> 400" || bad "steer without text -> $C (expected 400)"

say "5. MCP dual-era"
R="$(api POST /mcp '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}')"
has "server/discover returns a DiscoverResult" 'supportedVersions' "$R"
has "discover carries cache directives"        'cacheScope'        "$R"
R="$(api POST /mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}')"
has "modern tools/list works with no handshake" 'resultType' "$R"
R="$(api POST /mcp '{"jsonrpc":"2.0","id":3,"method":"tools/list"}')"
has "legacy tools/list still served" '"tools"' "$R"
C="$(code POST /mcp '{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01"}}}')"
[ "$C" = "400" ] && ok "unsupported version -> HTTP 400" || bad "unsupported version -> $C (expected 400)"

say "6. tool surface the Studio tabs rely on"
for ep in /v1/models /v1/skills /v1/mcp/tools /v1/cron /v1/memory /v1/kb; do
  C="$(code GET "$ep")"
  case "$C" in 200|404) ok "GET $ep -> $C";; *) bad "GET $ep -> $C";; esac
done
# /v1/logs streams (a plain GET follows the log and never closes), so a short
# cap that returns nothing is the CORRECT outcome here, not a failure.
L="$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "${AUTH[@]}" "$BASE/v1/logs" 2>/dev/null)"
case "$L" in 200|000) ok "GET /v1/logs responds (streaming route)";; *) bad "GET /v1/logs -> $L";; esac

say "7. cleanup"
C="$(code DELETE "/v1/sessions/$SESSION")"
[ "$C" = "200" ] && ok "smoke session deleted" || note "delete -> $C (clean up $SESSION by hand)"
note "imported smoke sessions were left in place; remove them from the UI if unwanted"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"

cat <<'MANUAL'

Still needs eyes on the running Studio app (cannot be automated):
  - expand the tool sidecars on a turn with several tool calls: no bubble
    should paint over another  (the bug fixed in #485)
  - reload a session that has tool cards: each card must land on the turn it
    belongs to, not shifted by one
  - send a message mid-turn while streaming: it should STEER (not abort);
    Send with an empty composer should still abort
  - a reply containing a table / nested list / numbered list past item 1 /
    fenced code: all should render as blocks, not raw markdown
  - light/dark style switch, then restart: settings and the tool-card
    expand state should come back as you left them
MANUAL

exit "$FAIL"
