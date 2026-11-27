#!/usr/bin/env python3
"""`pasclaw mcp auth` against a fake authorization server, per MCP 2026-07-28.

The fake serves protected-resource metadata, authorization-server metadata,
a registration endpoint and a token endpoint; this script plays the browser
by calling the loopback redirect itself. Checked:

  - RFC 9207: a redirect whose `iss` is not the recorded issuer is refused
    before any code reaches the token endpoint, and its error text is not
    shown; with authorization_response_iss_parameter_supported, a redirect
    without `iss` is refused too;
  - dynamic client registration declares application_type "native";
  - the registration is stored with its issuer and reused with that issuer
    (same redirect port, no new registration);
  - when the protected resource names another authorization server, the old
    client is not used and a new one is registered;
  - a Client ID Metadata Document is used when the server supports one and
    mcp_oauth_client_metadata_url is set: the URL is the client_id and
    nothing is registered.

A no-op xdg-open shadows any real one, so no browser is ever started.

usage: mcp_oauth_e2e.py <pasclaw-binary>
"""
import http.server
import json
import os
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request

CIMD_URL = "https://client.example.com/pasclaw-client.json"


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class AS(http.server.BaseHTTPRequestHandler):
    base = ""
    current = "as1"        # which authorization server the resource names
    cimd = False           # client_id_metadata_document_supported
    registrations = []     # (as, body)
    tokens = []            # (as, form)

    def send_json(self, obj, status=200):
        out = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path.startswith("/.well-known/oauth-protected-resource"):
            return self.send_json({"resource": AS.base + "/mcp",
                                   "authorization_servers": [AS.base + "/" + AS.current]})
        for name in ("as1", "as2"):
            if path == "/%s/.well-known/oauth-authorization-server" % name:
                iss = AS.base + "/" + name
                return self.send_json({
                    "issuer": iss,
                    "authorization_endpoint": iss + "/authorize",
                    "token_endpoint": iss + "/token",
                    "registration_endpoint": iss + "/register",
                    "authorization_response_iss_parameter_supported": True,
                    "client_id_metadata_document_supported": AS.cimd})
        self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        name = path.split("/")[1]
        if path.endswith("/register"):
            AS.registrations.append((name, json.loads(body)))
            return self.send_json({"client_id": "client-%s-%d" % (name, len(AS.registrations))}, 201)
        if path.endswith("/token"):
            AS.tokens.append((name, urllib.parse.parse_qs(body)))
            return self.send_json({"access_token": "at-%d" % len(AS.tokens), "token_type": "Bearer",
                                   "expires_in": 3600, "refresh_token": "rt"})
        self.send_json({"error": "not found"}, 404)

    def log_message(self, *a):
        pass


def run_auth(binary, env, home, iss_of=None, error=None, error_code="access_denied", forge_state=False):
    """Run `pasclaw mcp auth srv`, answer the redirect, return (exit, output,
    authorize-url params). iss_of(params) gives the iss to send back (None
    = leave it out)."""
    p = subprocess.Popen([binary, "mcp", "auth", "srv"], env=env, cwd=home, stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    lines = queue.Queue()
    out = []

    def reader():
        for line in p.stdout:
            out.append(line)
            lines.put(line)
        lines.put(None)

    threading.Thread(target=reader, daemon=True).start()
    params = None
    while True:
        try:
            line = lines.get(timeout=30)
        except queue.Empty:
            p.kill()
            fail("no authorize URL printed:\n" + "".join(out))
        if line is None:
            break
        if "/authorize?" in line:
            q = urllib.parse.urlparse(line.strip())
            params = {k: v[0] for k, v in urllib.parse.parse_qs(q.query).items()}
            break
    if params is not None:
        cb = {"state": "forged-" + params["state"] if forge_state else params["state"]}
        if error:
            cb["error"] = error_code
            cb["error_description"] = error
        else:
            cb["code"] = "the-code"
        iss = iss_of(params) if iss_of else None
        if iss is not None:
            cb["iss"] = iss
        try:
            urllib.request.urlopen(params["redirect_uri"] + "?" + urllib.parse.urlencode(cb), timeout=10).read()
        except urllib.error.HTTPError:
            pass
    try:
        p.wait(timeout=60)
    except subprocess.TimeoutExpired:
        p.kill()
        fail("mcp auth did not finish:\n" + "".join(out))
    return p.returncode, "".join(out), params or {}


def main():
    binary = os.path.abspath(sys.argv[1])
    home = tempfile.mkdtemp(prefix="pasclaw-mcp-oauth-e2e-")
    port = free_port()
    AS.base = "http://127.0.0.1:%d" % port
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), AS)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    shim = os.path.join(home, "bin")
    os.makedirs(shim)
    with open(os.path.join(shim, "xdg-open"), "w") as f:
        f.write("#!/bin/sh\nexit 0\n")
    os.chmod(os.path.join(shim, "xdg-open"), 0o755)
    cfg = {"mcp_servers": [{"name": "srv", "cmd": AS.base + "/mcp", "args": "", "enabled": True}]}
    cfg_path = os.path.join(home, "config.json")
    with open(cfg_path, "w") as f:
        json.dump(cfg, f)
    env = dict(os.environ, PASCLAW_HOME=home, NO_COLOR="1", PATH=shim + os.pathsep + os.environ.get("PATH", ""))
    token_file = os.path.join(home, "oauth", "srv.json")
    right = lambda prm: AS.base + "/" + AS.current
    try:
        # 1. iss from another server: refused, nothing redeemed, its error text unseen.
        code, out, prm = run_auth(binary, env, home, iss_of=lambda prm: "https://evil.example",
                                  error="visit http://phish.example now")
        if code == 0 or "RFC 9207" not in out:
            fail("iss mismatch was not refused (exit %d):\n%s" % (code, out))
        if "phish" in out:
            fail("a mismatched response's error text was shown:\n" + out)
        if AS.tokens:
            fail("a code reached the token endpoint despite the iss mismatch")
        if not AS.registrations or AS.registrations[-1][1].get("application_type") != "native":
            fail("registration did not declare application_type native: %r" % AS.registrations)
        print("  ok: iss mismatch refused before the token endpoint; DCR says native")

        # 2. no iss although the server advertises it: refused.
        code, out, prm = run_auth(binary, env, home, iss_of=None)
        if code == 0 or "authorization_response_iss_parameter_supported" not in out or AS.tokens:
            fail("a response without iss was accepted (exit %d):\n%s" % (code, out))
        print("  ok: missing iss refused when advertised")

        # 3. the right iss: tokens saved, client bound to its issuer.
        code, out, prm = run_auth(binary, env, home, iss_of=right)
        if code != 0 or len(AS.tokens) != 1:
            fail("a valid response failed (exit %d):\n%s" % (code, out))
        tok = json.load(open(token_file))
        if tok.get("client_issuer") != AS.base + "/as1" or tok.get("client_registration") != "dcr" \
                or tok.get("client_redirect_uri") != prm["redirect_uri"]:
            fail("token file lacks the issuer binding: %r" % tok)
        first_client, first_redirect = prm["client_id"], prm["redirect_uri"]
        print("  ok: authorized; the stored client is bound to its issuer")

        # 4. same issuer: the registration is reused on the same redirect.
        n = len(AS.registrations)
        code, out, prm = run_auth(binary, env, home, iss_of=right)
        if code != 0 or len(AS.registrations) != n:
            fail("same issuer registered again (exit %d):\n%s" % (code, out))
        if prm["client_id"] != first_client or prm["redirect_uri"] != first_redirect:
            fail("the stored registration was not reused: %r" % prm)
        print("  ok: same issuer reuses the registration")

        # 5. the resource moves to another authorization server: new client.
        AS.current = "as2"
        code, out, prm = run_auth(binary, env, home, iss_of=right)
        if code != 0 or len(AS.registrations) != n + 1 or AS.registrations[-1][0] != "as2":
            fail("issuer change did not register with the new server (exit %d):\n%s" % (code, out))
        if prm["client_id"] == first_client or "authorization server changed" not in out:
            fail("the old client was presented to the new server: %r\n%s" % (prm, out))
        if json.load(open(token_file)).get("client_issuer") != AS.base + "/as2":
            fail("the new registration is not bound to the new issuer")
        print("  ok: a new authorization server gets a new registration")

        # 5b. a forged callback (wrong state) saying invalid_client: refused,
        # and the stored registration is kept. Anything on this machine can
        # call the loopback callback; it must not wipe a working client.
        client_as2 = json.load(open(token_file)).get("client_id")
        code, out, prm = run_auth(binary, env, home, iss_of=right, error="client gone",
                                  error_code="invalid_client", forge_state=True)
        if code == 0 or "state mismatch" not in out:
            fail("a forged callback was not refused (exit %d):\n%s" % (code, out))
        if "dropped the stored client registration" in out or \
                json.load(open(token_file)).get("client_id") != client_as2:
            fail("a forged invalid_client callback dropped the registration:\n" + out)
        print("  ok: a forged invalid_client callback keeps the registration")

        # 5c. the real authorization server saying invalid_client: forgotten.
        code, out, prm = run_auth(binary, env, home, iss_of=right, error="client gone",
                                  error_code="invalid_client")
        if code == 0 or "dropped the stored client registration" not in out or \
                json.load(open(token_file)).get("client_id"):
            fail("an authentic invalid_client did not drop the registration (exit %d):\n%s" % (code, out))
        print("  ok: an authentic invalid_client forgets the registration")

        # 6. CIMD: the configured URL is the client_id; nothing is registered.
        AS.cimd = True
        cfg["mcp_oauth_client_metadata_url"] = CIMD_URL
        with open(cfg_path, "w") as f:
            json.dump(cfg, f)
        n = len(AS.registrations)
        code, out, prm = run_auth(binary, env, home, iss_of=right)
        if code != 0 or prm.get("client_id") != CIMD_URL or len(AS.registrations) != n:
            fail("CIMD not used (exit %d, %r):\n%s" % (code, prm, out))
        if AS.tokens[-1][1].get("client_id") != [CIMD_URL]:
            fail("the token request did not use the CIMD client_id: %r" % AS.tokens[-1][1])
        print("  ok: Client ID Metadata Document used, no registration")
    finally:
        httpd.shutdown()
        shutil.rmtree(home, ignore_errors=True)
    print("mcp_oauth_e2e: OK")


if __name__ == "__main__":
    main()
