#!/usr/bin/env python3
"""
provider_stub.py - localhost OpenAI-compatible HTTP server for the SWE bench.

PasClaw's OpenAI provider speaks the standard /v1/chat/completions wire shape
and lets the operator override api_base. Point PasClaw at this stub
(api_base = http://127.0.0.1:<port>) and the agent loop runs against a
provider we fully control: we can serve canned responses for unit testing
the harness, proxy to a real upstream (Anthropic / OpenAI / Groq / Ollama)
for the actual sweep, or do both at once (proxy + record, so a successful
run becomes a reusable mock transcript).

Three modes (one per process):

    --mock <transcript.jsonl>
        Replay an offline transcript. Each line is one assistant turn
        (full /v1/chat/completions response body). The Nth incoming
        request gets the Nth line. Useful for harness self-tests and
        for paid-CI runs where you don't want to burn API tokens.

    --proxy <base_url>
        Forward every request to <base_url>/v1/chat/completions (with
        bearer auth from $PROVIDER_STUB_UPSTREAM_KEY). The response is
        returned unmodified. This is the normal sweep mode.

    --proxy <base_url> --record <transcript.jsonl>
        Proxy AND append each (request, response) pair to the transcript
        for later --mock replay.

Metrics are written to stderr as one JSON line per request:

    {"event":"turn","turn":N,"tokens_in":..,"tokens_out":..,
     "tool_calls":..,"elapsed_ms":..}

run.py reads these to build the per-task metric record.

stdlib-only: no Flask, no aiohttp. CI runs without `pip install`.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Iterator, Optional


# --------------------------------------------------------------------------- #
# Transcript playback                                                         #
# --------------------------------------------------------------------------- #


class Transcript:
    """Iterator over assistant-turn responses loaded from a JSONL file."""

    def __init__(self, path: str) -> None:
        with open(path, "r", encoding="utf-8") as fh:
            self.turns = [json.loads(line) for line in fh if line.strip()]
        self.idx = 0

    def next_response(self) -> dict:
        if self.idx >= len(self.turns):
            # Out-of-transcript: synthesize a "I'm done" final turn so the
            # agent loop terminates cleanly instead of hanging.
            return _final_message(
                "Transcript exhausted at turn %d. Stopping." % self.idx
            )
        resp = self.turns[self.idx]
        self.idx += 1
        return resp


def _final_message(text: str) -> dict:
    """Build a minimal OpenAI chat-completion response with a terminal
    assistant message (no tool_calls => agent loop ends)."""
    return {
        "id": "stub-" + uuid.uuid4().hex[:12],
        "object": "chat.completion",
        "created": int(time.time()),
        "model": "stub",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": text},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


# --------------------------------------------------------------------------- #
# Upstream proxy                                                              #
# --------------------------------------------------------------------------- #


class Upstream:
    def __init__(self, base_url: str, api_key: Optional[str]) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key

    def forward(self, body: bytes, content_type: str) -> tuple[int, bytes, str]:
        url = self.base_url + "/v1/chat/completions"
        headers = {"Content-Type": content_type}
        if self.api_key:
            headers["Authorization"] = "Bearer " + self.api_key
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                return (
                    resp.status,
                    resp.read(),
                    resp.headers.get("Content-Type", "application/json"),
                )
        except urllib.error.HTTPError as e:
            return e.code, e.read(), e.headers.get("Content-Type", "application/json")


# --------------------------------------------------------------------------- #
# Metric extraction                                                           #
# --------------------------------------------------------------------------- #


def _rough_token_count(s: str) -> int:
    """Approximate token count: one token per 4 chars, the OpenAI rule of
    thumb. Off by ~10-20% for English prose; off more for code-heavy text.
    Used as a fallback when the live-driven provider doesn't supply honest
    usage numbers."""
    return max(1, len(s) // 4)


def metrics_from_response(
    resp_body: bytes,
    req_body: bytes = b"",
    estimate_if_missing: bool = False,
) -> dict:
    """Parse a chat-completion response body and return a metric record.
    Tolerates non-JSON bodies (upstream errors etc.) by returning zeros.

    When estimate_if_missing is True, a zero/missing usage block is
    replaced by a rough char-count estimate from req_body and resp_body.
    Use this for live-driven runs where the LLM author (a human or a
    subagent) may not bother filling in honest usage numbers; leave it
    off for proxy runs where the upstream provider's count is real."""
    try:
        obj = json.loads(resp_body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        obj = {}
    usage = obj.get("usage") or {}
    choice = (obj.get("choices") or [{}])[0]
    msg = choice.get("message") or {}
    tool_calls = msg.get("tool_calls") or []
    tokens_in = int(usage.get("prompt_tokens") or 0)
    tokens_out = int(usage.get("completion_tokens") or 0)
    if estimate_if_missing and (tokens_in == 0 or tokens_in == 1):
        tokens_in = _rough_token_count(req_body.decode("utf-8", "replace"))
    if estimate_if_missing and (tokens_out == 0 or tokens_out == 1):
        # Estimate from the assistant message content + tool-call argument blobs.
        out_str = msg.get("content") or ""
        for tc in tool_calls:
            out_str += (tc.get("function") or {}).get("arguments", "")
        tokens_out = _rough_token_count(out_str)
    return {
        "tokens_in": tokens_in,
        "tokens_out": tokens_out,
        "tool_calls": len(tool_calls),
    }


# --------------------------------------------------------------------------- #
# HTTP handler                                                                #
# --------------------------------------------------------------------------- #


class _State:
    transcript: Optional[Transcript] = None
    upstream: Optional[Upstream] = None
    blocking_queue: Optional[str] = None  # dir; req_N.json / resp_N.json files
    blocking_timeout_s: int = 600
    record_fh = None  # open file handle for --record
    turn_count = 0

    @classmethod
    def emit_event(cls, event: dict) -> None:
        sys.stderr.write(json.dumps(event) + "\n")
        sys.stderr.flush()


class StubHandler(BaseHTTPRequestHandler):
    # Silence the default per-request access log; we emit our own structured
    # events on stderr instead.
    def log_message(self, fmt: str, *args) -> None:
        return

    def do_GET(self):
        # /v1/models is sometimes probed by the OpenAI provider on startup;
        # answer with a single dummy model so the probe succeeds.
        if self.path.startswith("/v1/models"):
            body = json.dumps(
                {"object": "list", "data": [{"id": "stub", "object": "model"}]}
            ).encode()
            self._send(200, body, "application/json")
            return
        if self.path == "/healthz":
            self._send(200, b"ok", "text/plain")
            return
        self._send(404, b"not found", "text/plain")

    def do_POST(self):
        if not self.path.startswith("/v1/chat/completions"):
            self._send(404, b"not found", "text/plain")
            return

        length = int(self.headers.get("Content-Length") or 0)
        req_body = self.rfile.read(length) if length else b""
        content_type = self.headers.get("Content-Type") or "application/json"

        t0 = time.monotonic()

        if _State.upstream:
            status, resp_body, resp_ct = _State.upstream.forward(req_body, content_type)
        elif _State.blocking_queue:
            status, resp_body, resp_ct = self._blocking_serve(req_body)
        else:
            assert _State.transcript is not None, "no mode configured"
            resp_body = json.dumps(_State.transcript.next_response()).encode()
            status, resp_ct = 200, "application/json"

        elapsed_ms = int((time.monotonic() - t0) * 1000)

        if _State.record_fh is not None and status == 200:
            try:
                resp_obj = json.loads(resp_body)
            except json.JSONDecodeError:
                resp_obj = None
            if resp_obj is not None:
                _State.record_fh.write(json.dumps(resp_obj, separators=(",", ":")) + "\n")
                _State.record_fh.flush()

        _State.turn_count += 1
        # In --blocking mode the "provider" is a Claude (this session or a
        # subagent) authoring responses by hand -- it rarely fills honest
        # usage numbers. Fall back to a char-count estimate so the bench's
        # token metric remains comparable across cells. Proxy / mock modes
        # trust the response's usage field verbatim.
        estimate = _State.blocking_queue is not None
        m = metrics_from_response(resp_body, req_body, estimate_if_missing=estimate)
        # Track the per-turn request size too -- exposes how the conversation
        # grows over time (message accumulation, tool-result bloat). Stock
        # vs. lean-build vs. max-build will differ in turn-1 size; condenser
        # / output-cap differences show up as turn-N growth slopes.
        m["req_bytes"] = len(req_body)
        m["resp_bytes"] = len(resp_body)
        _State.emit_event({
            "event": "turn",
            "turn": _State.turn_count,
            "status": status,
            "elapsed_ms": elapsed_ms,
            **m,
        })

        self._send(status, resp_body, resp_ct)

    def _blocking_serve(self, req_body: bytes) -> tuple[int, bytes, str]:
        """File-FIFO mode: write req_N.json, poll for resp_N.json.

        Atomic publication: write req_N.json.tmp first, then rename to
        req_N.json so the driver never sees a half-written file. Same for
        the response side -- the driver writes resp_N.json.tmp and renames.
        Two-end file handshake stays correct even with concurrent IO."""
        seq = _State.turn_count + 1  # 1-based; _State.turn_count bumps after
        q = _State.blocking_queue
        req_tmp = os.path.join(q, "req_%d.json.tmp" % seq)
        req_final = os.path.join(q, "req_%d.json" % seq)
        resp_path = os.path.join(q, "resp_%d.json" % seq)

        with open(req_tmp, "wb") as fh:
            fh.write(req_body)
        os.rename(req_tmp, req_final)

        # Poll for the response. Driver MUST write resp_N.json.tmp then
        # rename, so we only see it once it's complete.
        deadline = time.monotonic() + _State.blocking_timeout_s
        while time.monotonic() < deadline:
            if os.path.exists(resp_path):
                with open(resp_path, "rb") as fh:
                    body = fh.read()
                return 200, body, "application/json"
            time.sleep(0.5)
        # Timeout: synthesize a terminal "I gave up" response so the agent
        # loop exits instead of retrying forever.
        body = json.dumps(
            _final_message("Provider timeout: no response after %ds." %
                            _State.blocking_timeout_s)
        ).encode()
        return 200, body, "application/json"

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


# --------------------------------------------------------------------------- #
# Entry point                                                                 #
# --------------------------------------------------------------------------- #


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument(
        "--port", type=int, default=0,
        help="bind port (0 = pick a free port; printed on stdout as PORT=N)",
    )
    ap.add_argument("--host", default="127.0.0.1")

    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--mock", metavar="TRANSCRIPT_JSONL",
                      help="replay each line as the next assistant response")
    mode.add_argument("--proxy", metavar="BASE_URL",
                      help="forward to <BASE_URL>/v1/chat/completions")
    mode.add_argument("--blocking", metavar="QUEUE_DIR",
                      help="write each request to QUEUE_DIR/req_N.json and "
                           "poll QUEUE_DIR/resp_N.json for the reply. Used "
                           "when a Claude subagent (or human) is the live "
                           "provider in the loop.")
    ap.add_argument("--blocking-timeout-s", type=int, default=600,
                    help="max seconds to wait for each response (default 600)")

    ap.add_argument("--record", metavar="TRANSCRIPT_JSONL",
                    help="append each response to a JSONL transcript (proxy mode)")
    ap.add_argument("--upstream-key-env", default="PROVIDER_STUB_UPSTREAM_KEY",
                    help="env var holding the bearer token forwarded to --proxy")

    args = ap.parse_args()

    if args.mock:
        _State.transcript = Transcript(args.mock)
    elif args.blocking:
        os.makedirs(args.blocking, exist_ok=True)
        _State.blocking_queue = os.path.abspath(args.blocking)
        _State.blocking_timeout_s = args.blocking_timeout_s
    else:
        _State.upstream = Upstream(args.proxy, os.environ.get(args.upstream_key_env))

    if args.record:
        if not args.proxy:
            ap.error("--record only makes sense with --proxy")
        _State.record_fh = open(args.record, "a", encoding="utf-8")

    server = ThreadingHTTPServer((args.host, args.port), StubHandler)
    actual_port = server.server_address[1]
    sys.stdout.write("PORT=%d\n" % actual_port)
    sys.stdout.flush()

    if args.mock:
        mode = "mock"
    elif args.blocking:
        mode = "blocking"
    else:
        mode = "proxy"
    _State.emit_event({
        "event": "ready",
        "host": args.host, "port": actual_port, "mode": mode,
    })

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if _State.record_fh is not None:
            _State.record_fh.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
