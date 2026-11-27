#!/usr/bin/env python3
"""A scripted MCP server for PasClaw's MCP client tests.

It speaks either protocol era, or both, over stdio or Streamable HTTP, and
logs every message it receives (with the HTTP headers) as one JSON object
per line, so a test can check what the client actually sent.

  --era modern   2026-07-28 only: server/discover, per-request _meta,
                 resultType, multi round-trip requests, the tasks
                 extension; `initialize` is refused with the supported
                 versions in the error.
  --era legacy   handshake only: initialize + notifications/initialized;
                 anything before initialize is "method not found" (stdio) or
                 a 400 without a session (HTTP); elicitation is a server
                 request (elicitation/create) sent while tools/call waits.
  --era both     dual-era: answers whichever way the client opens.

  --legacy-version V      what initialize answers (default: the version the
                          client offered)
  --discover-unsupported  server/discover gets UnsupportedProtocolVersionError
                          listing only --legacy-version (a modern server that
                          does not speak 2026-07-28)
  --silent-unknown        legacy: never answer a method it does not know
  --noisy                 stdio: print a line that is not JSON before anything
  --exit-on-unknown       legacy: exit on any request before initialize
  --transport http        listen on 127.0.0.1 (port written to --port-file)

Tools: echo, plain (no resultType), ask_form, ask_url, ask_forever,
slow_task, failing_task, input_task, regional (x-mcp-header), progress_echo
(an SSE response with a progress notification before the result).

usage: fake_mcp_server.py --era E [--transport stdio|http] [--log FILE] ...
"""
import argparse
import base64
import http.server
import json
import sys
import threading

MODERN = "2026-07-28"
TASKS = "io.modelcontextprotocol/tasks"
ARGS = None
LOG_LOCK = threading.Lock()
STATE = {"initialized": False, "elicit_cap": None, "tasks": {}, "session": "sess-123"}


def log(entry):
    if not ARGS.log:
        return
    with LOG_LOCK:
        with open(ARGS.log, "a") as f:
            f.write(json.dumps(entry) + "\n")


def legacy_version():
    return ARGS.legacy_version or "2025-06-18"


def result(rid, res):
    return {"jsonrpc": "2.0", "id": rid, "result": res}


def error(rid, code, message, data=None):
    e = {"code": code, "message": message}
    if data is not None:
        e["data"] = data
    return {"jsonrpc": "2.0", "id": rid, "error": e}


def text(t, modern):
    r = {"content": [{"type": "text", "text": t}]}
    if modern:
        r["resultType"] = "complete"
    return r


TOOLS = [
    {"name": "echo", "description": "echo text", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}},
    {"name": "plain", "description": "a result without resultType", "inputSchema": {"type": "object"}},
    {"name": "ask_form", "description": "asks the user for a profile", "inputSchema": {"type": "object"}},
    {"name": "ask_url", "description": "sends the user to a URL", "inputSchema": {"type": "object"}},
    {"name": "ask_forever", "description": "never satisfied", "inputSchema": {"type": "object"}},
    {"name": "slow_task", "description": "runs as a task", "inputSchema": {"type": "object"}},
    {"name": "failing_task", "description": "a task that fails", "inputSchema": {"type": "object"}},
    {"name": "input_task", "description": "a task that asks", "inputSchema": {"type": "object"}},
    {"name": "regional", "description": "routes on a header",
     "inputSchema": {"type": "object", "properties": {
         "region": {"type": "string", "x-mcp-header": "Region"},
         "query": {"type": "string"}}, "required": ["region"]}},
    {"name": "progress_echo", "description": "streams a progress notification", "inputSchema": {"type": "object"}},
]

FORM_SCHEMA = {
    "type": "object",
    "properties": {
        "name": {"type": "string", "title": "Your name", "minLength": 2},
        "age": {"type": "integer", "minimum": 18, "maximum": 130},
        "color": {"type": "string", "enum": ["red", "green", "blue"], "default": "green"},
        "subscribe": {"type": "boolean"},
        "tags": {"type": "array", "items": {"type": "string", "enum": ["a", "b", "c"]}},
    },
    "required": ["name", "age"],
}
URL = "https://auth.example.com/connect?flow=42"


def canon(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def meta_of(msg):
    return ((msg.get("params") or {}).get("_meta") or {})


def client_caps(msg):
    return meta_of(msg).get("io.modelcontextprotocol/clientCapabilities") or {}


class Server:
    """Era logic, shared by both transports. `ask_client` is the transport's
    way to send a legacy server->client request and wait for the answer."""

    def __init__(self, ask_client=None):
        self.ask_client = ask_client

    def handle(self, msg):
        """Returns (response or None, http_status)."""
        method = msg.get("method", "")
        rid = msg.get("id")
        if rid is None:
            return None, 202
        meta = meta_of(msg)
        declared = meta.get("io.modelcontextprotocol/protocolVersion")
        if declared is not None:
            return self.modern(msg, method, rid, declared)
        return self.legacy(msg, method, rid)

    # ---------------------------------------------------------- modern
    def modern(self, msg, method, rid, declared):
        if ARGS.era == "legacy" and ARGS.exit_on_unknown:
            sys.exit(3)
        if ARGS.era == "legacy":
            if ARGS.silent_unknown and method not in ("initialize",):
                return "SILENT", 0
            return error(rid, -32601, "Method not found: " + method), 400
        if method == "server/discover" and ARGS.discover_unsupported:
            return error(rid, -32022, "Unsupported protocol version",
                         {"supported": [legacy_version()], "requested": declared}), 400
        if declared != MODERN:
            return error(rid, -32022, "Unsupported protocol version",
                         {"supported": [MODERN], "requested": declared}), 400
        if "io.modelcontextprotocol/clientCapabilities" not in meta_of(msg):
            return error(rid, -32602, "missing clientCapabilities"), 400
        params = msg.get("params") or {}
        if method == "server/discover":
            vers = [MODERN] + ([legacy_version()] if ARGS.era == "both" else [])
            return result(rid, {"resultType": "complete", "supportedVersions": vers,
                                "capabilities": {"tools": {}, "extensions": {TASKS: {}}},
                                "_meta": {"io.modelcontextprotocol/serverInfo": {"name": "fake-mcp", "version": "9.9",
                                    "icons": [{"src": "data:image/svg+xml;base64,PHN2Zy8+"}]}},
                                "instructions": "a JSON reply may mention data: URIs\ndata: like this",
                                "ttlMs": 0, "cacheScope": "private"}), 200
        if method == "tools/list":
            return result(rid, {"resultType": "complete", "tools": TOOLS, "ttlMs": 0, "cacheScope": "private"}), 200
        if method == "tools/call":
            return self.modern_call(msg, rid, params), 200
        if method in ("tasks/get", "tasks/update", "tasks/cancel"):
            return self.task_op(rid, method, params), 200
        return error(rid, -32601, "Method not found: " + method), 404

    def modern_call(self, msg, rid, params):
        name = params.get("name")
        responses = params.get("inputResponses")
        state = params.get("requestState")
        if name == "echo":
            return result(rid, text("echo:" + (params.get("arguments") or {}).get("text", ""), True))
        if name == "plain":
            return result(rid, {"content": [{"type": "text", "text": "plain result"}]})
        if name == "regional":
            return result(rid, text("region:" + (params.get("arguments") or {}).get("region", ""), True))
        if name == "progress_echo":
            return result(rid, text("after progress", True))
        if name in ("ask_form", "ask_url"):
            key = "profile" if name == "ask_form" else "login"
            want_state = "state-%s-1" % name
            if responses is None:
                if name == "ask_form":
                    req = {"method": "elicitation/create", "params": {
                        "mode": "form", "message": "Tell me about yourself", "requestedSchema": FORM_SCHEMA}}
                else:
                    req = {"method": "elicitation/create", "params": {
                        "mode": "url", "message": "Sign in to Example", "url": URL}}
                return result(rid, {"resultType": "input_required", "inputRequests": {key: req},
                                    "requestState": want_state})
            if state != want_state:
                return result(rid, text("bad requestState %r" % state, True))
            ans = responses.get(key) or {}
            return result(rid, text("%s:%s:%s" % (name, ans.get("action"), canon(ans.get("content"))), True))
        if name == "ask_forever":
            n = int((state or "s0")[1:]) + 1
            return result(rid, {"resultType": "input_required", "requestState": "s%d" % n,
                                "inputRequests": {"again%d" % n: {"method": "elicitation/create", "params": {
                                    "mode": "form", "message": "once more",
                                    "requestedSchema": {"type": "object", "properties": {}}}}}})
        if name in ("slow_task", "failing_task", "input_task"):
            if TASKS not in (client_caps(msg).get("extensions") or {}):
                return error(rid, -32021, "Missing required client capability",
                             {"requiredCapabilities": {"extensions": {TASKS: {}}}})
            tid = "task-%s-%d" % (name, len(STATE["tasks"]) + 1)
            STATE["tasks"][tid] = {"kind": name, "polls": 0, "answer": None}
            return result(rid, {"resultType": "task", "taskId": tid, "status": "working",
                                "createdAt": "2026-11-25T10:00:00Z", "lastUpdatedAt": "2026-11-25T10:00:00Z",
                                "ttlMs": 60000, "pollIntervalMs": 50})
        return error(rid, -32602, "unknown tool " + str(name))

    def task_op(self, rid, method, params):
        tid = params.get("taskId")
        t = STATE["tasks"].get(tid)
        if t is None:
            return error(rid, -32602, "unknown task")
        if method == "tasks/cancel":
            t["cancelled"] = True
            return result(rid, {"resultType": "complete"})
        if method == "tasks/update":
            t["answer"] = (params.get("inputResponses") or {}).get("confirm")
            return result(rid, {"resultType": "complete"})
        t["polls"] += 1
        base = {"resultType": "complete", "taskId": tid, "createdAt": "2026-11-25T10:00:00Z",
                "lastUpdatedAt": "2026-11-25T10:00:01Z", "ttlMs": 60000, "pollIntervalMs": 50}
        if t["kind"] == "slow_task":
            if t["polls"] < 3:
                return result(rid, dict(base, status="working", statusMessage="poll %d" % t["polls"]))
            return result(rid, dict(base, status="completed",
                                    result={"content": [{"type": "text", "text": "task done after %d polls" % t["polls"]}]}))
        if t["kind"] == "failing_task":
            if t["polls"] < 2:
                return result(rid, dict(base, status="working"))
            return result(rid, dict(base, status="failed", error={"code": -32603, "message": "the job exploded"}))
        # input_task
        if t["answer"] is None:
            return result(rid, dict(base, status="input_required", inputRequests={"confirm": {
                "method": "elicitation/create", "params": {
                    "mode": "form", "message": "Proceed with the job?",
                    "requestedSchema": {"type": "object", "properties": {"proceed": {"type": "boolean"}},
                                        "required": ["proceed"]}}}}))
        a = t["answer"]
        return result(rid, dict(base, status="completed", result={"content": [{"type": "text",
            "text": "input_task:%s:%s" % (a.get("action"), canon(a.get("content")))}]}))

    # ---------------------------------------------------------- legacy
    def legacy(self, msg, method, rid):
        if ARGS.era == "modern":
            if method == "initialize":
                return error(rid, -32601, "initialize is not supported; this server speaks " + MODERN,
                             {"supported": [MODERN]}), 400
            return error(rid, -32602, "missing _meta protocol version"), 400
        params = msg.get("params") or {}
        if method == "initialize":
            STATE["initialized"] = True
            STATE["elicit_cap"] = (params.get("capabilities") or {}).get("elicitation")
            v = ARGS.legacy_version or params.get("protocolVersion") or legacy_version()
            return result(rid, {"protocolVersion": v, "capabilities": {"tools": {}},
                                "serverInfo": {"name": "fake-mcp-legacy", "version": "1.0"}}), 200
        if ARGS.exit_on_unknown and not STATE["initialized"]:
            sys.exit(3)
        if not STATE["initialized"] or method not in ("tools/list", "tools/call", "ping"):
            if ARGS.silent_unknown:
                return "SILENT", 0
            return error(rid, -32601, "Method not found: " + method), 200
        if method == "ping":
            return result(rid, {}), 200
        if method == "tools/list":
            return result(rid, {"tools": TOOLS}), 200
        name = params.get("name")
        if name == "echo":
            return result(rid, text("echo:" + (params.get("arguments") or {}).get("text", ""), False)), 200
        if name == "plain":
            return result(rid, text("plain result", False)), 200
        if name in ("ask_form", "ask_url"):
            if self.ask_client is None or STATE["elicit_cap"] is None:
                return result(rid, text("no-elicitation-capability", False)), 200
            if name == "ask_form":
                p = {"mode": "form", "message": "Tell me about yourself", "requestedSchema": FORM_SCHEMA}
            else:
                p = {"mode": "url", "message": "Sign in to Example", "url": URL, "elicitationId": "el-1"}
            ans = self.ask_client("elicitation/create", p)
            if "error" in ans:
                return result(rid, text("%s:error:%s" % (name, ans["error"].get("code")), False)), 200
            r = ans.get("result") or {}
            return result(rid, text("%s:%s:%s" % (name, r.get("action"), canon(r.get("content"))), False)), 200
        return error(rid, -32602, "unknown tool " + str(name)), 200


# ------------------------------------------------------------- stdio
def run_stdio():
    out = sys.stdout
    pending = {"n": 0}

    def write(obj):
        out.write(json.dumps(obj) + "\n")
        out.flush()

    def ask_client(method, params):
        pending["n"] += 1
        sid = "srv-%d" % pending["n"]
        write({"jsonrpc": "2.0", "id": sid, "method": method, "params": params})
        while True:
            line = sys.stdin.readline()
            if not line:
                return {"error": {"code": -1}}
            line = line.strip()
            if not line:
                continue
            m = json.loads(line)
            log({"t": "stdio", "msg": m})
            if m.get("id") == sid and "method" not in m:
                return m

    srv = Server(ask_client)
    if ARGS.noisy:
        # a server that logs to stdout before it gets going
        out.write("fake MCP server starting (this line is not JSON)" + chr(10))
        out.flush()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        log({"t": "stdio", "msg": msg})
        resp, _ = srv.handle(msg)
        if resp is None or resp == "SILENT":
            continue
        write(resp)


# -------------------------------------------------------------- http
def b64_header(v):
    if v and v.startswith("=?base64?") and v.endswith("?="):
        return base64.b64decode(v[len("=?base64?"):-2]).decode("utf-8")
    return v


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    srv = Server(None)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0)
        msg = json.loads(body or b"{}")
        hdrs = {k.lower(): v for k, v in self.headers.items()}
        log({"t": "http", "msg": msg, "headers": hdrs})
        rid = msg.get("id")
        modern = meta_of(msg).get("io.modelcontextprotocol/protocolVersion") is not None
        if modern and ARGS.era != "legacy":
            bad = self.check_modern_headers(msg, hdrs)
            if bad:
                return self.send(400, error(rid, -32020, bad))
        elif not modern and msg.get("method") != "initialize" and rid is not None:
            if hdrs.get("mcp-session-id") != STATE["session"]:
                return self.send(400, error(None, -32000, "Bad Request: No valid session ID provided"))
        resp, status = self.srv.handle(msg)
        if resp is None:
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        extra = {}
        if msg.get("method") == "initialize" and "result" in resp:
            extra["Mcp-Session-Id"] = STATE["session"]
        if modern and (msg.get("params") or {}).get("name") == "progress_echo" and "result" in resp:
            return self.send_sse(resp, rid)
        self.send(status if status >= 200 else 200, resp, extra)

    def check_modern_headers(self, msg, hdrs):
        method = msg.get("method")
        params = msg.get("params") or {}
        if hdrs.get("mcp-protocol-version") != meta_of(msg).get("io.modelcontextprotocol/protocolVersion"):
            return "Header mismatch: MCP-Protocol-Version"
        if hdrs.get("mcp-method") != method:
            return "Header mismatch: Mcp-Method %r vs %r" % (hdrs.get("mcp-method"), method)
        want = None
        if method == "tools/call":
            want = params.get("name")
        elif method in ("tasks/get", "tasks/update", "tasks/cancel"):
            want = params.get("taskId")
        if want is not None and b64_header(hdrs.get("mcp-name")) != want:
            return "Header mismatch: Mcp-Name %r vs %r" % (hdrs.get("mcp-name"), want)
        if method == "tools/call" and params.get("name") == "regional":
            region = (params.get("arguments") or {}).get("region")
            if b64_header(hdrs.get("mcp-param-region")) != region:
                return "Header mismatch: Mcp-Param-Region %r vs %r" % (hdrs.get("mcp-param-region"), region)
        return None

    def send(self, status, obj, extra=None):
        out = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(out)

    def send_sse(self, resp, rid):
        note = {"jsonrpc": "2.0", "method": "notifications/progress",
                "params": {"progressToken": rid, "progress": 1, "total": 2}}
        out = ("event: message\ndata: %s\n\n: keep-alive\n\nevent: message\ndata: %s\n\n"
               % (json.dumps(note), json.dumps(resp))).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def run_http():
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    if ARGS.port_file:
        with open(ARGS.port_file + ".tmp", "w") as f:
            f.write(str(httpd.server_address[1]))
        import os
        os.replace(ARGS.port_file + ".tmp", ARGS.port_file)
    httpd.serve_forever()


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--era", choices=["modern", "legacy", "both"], required=True)
    ap.add_argument("--transport", choices=["stdio", "http"], default="stdio")
    ap.add_argument("--log", default="")
    ap.add_argument("--legacy-version", default="")
    ap.add_argument("--discover-unsupported", action="store_true")
    ap.add_argument("--silent-unknown", action="store_true")
    ap.add_argument("--noisy", action="store_true")
    ap.add_argument("--exit-on-unknown", action="store_true")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--port-file", default="")
    ap.add_argument("--start-delay", type=float, default=0,
                    help="seconds to wait before serving, like a server slow to start")
    ARGS = ap.parse_args()
    if ARGS.start_delay > 0:
        import time
        time.sleep(ARGS.start_delay)
    if ARGS.transport == "http":
        run_http()
    else:
        run_stdio()


if __name__ == "__main__":
    main()
