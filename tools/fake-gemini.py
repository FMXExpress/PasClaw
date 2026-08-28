#!/usr/bin/env python3
"""A stand-in for Google's generativeLanguage API.

The relay provider was the wrong harness for these bugs: it replaces the
provider, so anything provider-SHAPED -- a schema Google rejects, a 400
only flash-lite returns, a response field only Gemini emits -- is
invisible to it. This speaks Gemini's wire format instead, and is
deliberately as PICKY as Google is.

Every request is recorded to fg-req/NNN.json so a probe can assert on
what actually went on the wire.
"""
import json, os, re, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 19500
DIR = os.path.dirname(os.path.abspath(__file__))
REQ = os.path.join(DIR, "fg-req")
os.makedirs(REQ, exist_ok=True)
LOCK = threading.Lock()
N = [0]

# Models that reject Grounding with Google Search, per Google's current
# matrix (ai.google.dev/gemini-api/docs/google-search). 3.5 Flash-Lite
# and 2.5 Flash-Lite are both listed as SUPPORTED; 3.1 Flash-Lite is
# not. That distinction is the whole point -- a fake that refused every
# flash-lite would "prove" a fix that only worked because the fake was
# wrong. Google's matrix moves, which is why the product matches on the
# provider's words rather than on a list like this one.
NO_SEARCH = re.compile(r"gemini-3\.1-flash-lite", re.I)

BODY = ("<h2>Answer</h2><p>A short grounded answer to the question, "
        "written as a page.</p>")


def page_reply(query, grounded):
    """A grounded answer cites; an ungrounded one has nothing to cite.

    That is the whole point of the distinction the Browser badges, so
    the fake has to honour it or the probe proves nothing."""
    out = BODY
    if grounded:
        out += ('\nSOURCES: [{"title":"Example","url":"https://example.com"},'
                '{"title":"Second","url":"https://example.org"}]')
    return out


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        # model listing, used by discovery
        if "/models" in self.path:
            return self._send(200, {"models": [
                {"name": "models/gemini-3.5-flash-lite"},
                {"name": "models/gemini-3.1-flash-lite"},
                {"name": "models/gemini-2.5-flash-lite"},
                {"name": "models/gemini-2.5-pro"}]})
        self._send(404, {"error": {"message": "not found"}})

    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(n).decode("utf-8", "replace")
        try:
            body = json.loads(raw)
        except Exception:
            # Google answers malformed JSON with a 400, and so do we --
            # this is the shape a bad tool schema would take on the wire.
            return self._send(400, {"error": {
                "code": 400, "status": "INVALID_ARGUMENT",
                "message": "Invalid JSON payload received."}})

        m = re.search(r"/models/([^:]+):", self.path)
        model = m.group(1) if m else "?"
        with LOCK:
            N[0] += 1
            i = N[0]
        with open(os.path.join(REQ, "%03d.json" % i), "w") as f:
            json.dump({"path": self.path, "model": model, "body": body},
                      f, indent=1)

        tools = body.get("tools") or []
        has_search = any("google_search" in t for t in tools)
        has_funcs = any("functionDeclarations" in t for t in tools)

        # 1. Grounding on a model that does not have it.
        if has_search and NO_SEARCH.search(model):
            return self._send(400, {"error": {
                "code": 400, "status": "INVALID_ARGUMENT",
                "message": "Search Grounding is not supported for model "
                           + model + "."}})

        # 2. The combo restriction on pre-3 models.
        if has_search and has_funcs and not re.search(r"gemini-[3-9]", model):
            return self._send(400, {"error": {
                "code": 400, "status": "INVALID_ARGUMENT",
                "message": "Tool use with function calling and google_search "
                           "is unsupported in this model."}})

        # 3. Google validates every function declaration's schema. An
        #    empty parameters object is accepted; a malformed one is not.
        for t in tools:
            for fd in (t.get("functionDeclarations") or []):
                p = fd.get("parameters")
                if p is not None and not isinstance(p, dict):
                    return self._send(400, {"error": {
                        "code": 400, "status": "INVALID_ARGUMENT",
                        "message": "Invalid JSON payload received. Unknown "
                                   "name \"parameters\" at 'tools[0]"
                                   ".function_declarations[0]'"}})

        # Stand in for Google's real 400 on a model without grounding,
        # reachable without having to win the suppression argument first.
        blob = json.dumps(body)
        if True:
            if "BOOM" in blob:
                    return self._send(400, {"error": {
                        "code": 400, "status": "INVALID_ARGUMENT",
                        "message": "Search Grounding is not supported for "
                                   "model " + model + "."}})

        q = ""
        for c in (body.get("contents") or []):
            for part in (c.get("parts") or []):
                if part.get("text"):
                    q = part["text"]
        return self._send(200, {
            "candidates": [{
                "content": {"role": "model",
                            "parts": [{"text": page_reply(q, has_search)}]},
                "finishReason": "STOP"}],
            "usageMetadata": {"promptTokenCount": 10,
                              "candidatesTokenCount": 20,
                              "totalTokenCount": 30}})


print("fake gemini on %d" % PORT, flush=True)
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
