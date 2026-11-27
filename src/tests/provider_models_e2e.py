#!/usr/bin/env python3
"""GET /v1/providers/<name>/models: one provider's models, for the Settings
tab's model pickers.

A fake OpenAI-compatible provider lists two models and counts the calls.
Against a real gateway:

  - the first call fetches live (with the key the ${VAR} marker in
    config.json resolves to) and names the models; the next comes from the
    cache without a call; ?refresh=1 fetches again;
  - a provider whose list fails answers 200 with source "none", the error
    and no models; an unknown name is a 404;
  - a provider saved through PUT /v1/config, or added to config.json by
    hand, is listed before any restart;
  - two requests at once for a provider not yet cached make one call;
  - when a refresh fails, the cached list still comes back, with the error;
  - a provider an active profile supplies (config.json has no providers
    block of its own) is listed, and so is one added to that profile's
    file while the gateway runs (both were 404s: the route read only
    config.json); with the profile's file gone, the running config still
    answers for the provider the gateway runs with;
  - no response carries a key.

usage: provider_models_e2e.py <pasclaw-binary>
"""
import http.server
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from contextlib import contextmanager

KEYS = ("sk-a-q4", "sk-broken", "sk-b-q4", "sk-c-q4", "sk-p-q4", "sk-q-q4")
HITS = []          # (path, authorization)
STATE = {"fail": False}


class Provider(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        HITS.append((self.path, self.headers.get("Authorization", "")))
        if self.path == "/slow/v1/models":
            time.sleep(1)           # long enough for two requests to overlap
            self.path = "/v1/models"
        if self.path != "/v1/models" or STATE["fail"]:
            self.send_response(500)
            self.end_headers()
            return
        out = json.dumps({"object": "list", "data": [{"id": "alpha-1", "object": "model", "created": 1700000000},
                                                     {"id": "beta-2", "object": "model", "created": 1700000100}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def fail(msg, log=None):
    print("FAIL: " + msg)
    if log and os.path.exists(log):
        print("---- gateway log (tail) ----\n" + "".join(open(log, errors="replace").readlines()[-20:]))
    sys.exit(1)


def get(base, path):
    try:
        with urllib.request.urlopen(base + path, timeout=30) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


@contextmanager
def gateway(binary, home, gport, **extra_env):
    """Runs `pasclaw gateway` on home; yields (models, log)."""
    env = {k: v for k, v in os.environ.items() if k != "PASCLAW_PROFILE"}
    env.update(PASCLAW_HOME=home, NO_COLOR="1", **extra_env)
    log = os.path.join(home, "gateway.log")
    gw = None
    try:
        with open(log, "w") as lf:
            gw = subprocess.Popen([binary, "gateway", "--port", str(gport), "--addr", "127.0.0.1", "--no-tools"],
                                  env=env, cwd=home, stdin=subprocess.DEVNULL, stdout=lf, stderr=subprocess.STDOUT)
        base = "http://127.0.0.1:%d" % gport
        for _ in range(80):
            try:
                urllib.request.urlopen(base + "/v1/health", timeout=1).read()
                break
            except Exception:
                time.sleep(0.25)
        else:
            fail("the gateway never answered /v1/health", log)

        def models(name, query=""):
            code, text = get(base, "/v1/providers/%s/models%s" % (name, query))
            for k in KEYS:
                if k in text:
                    fail("a key leaked into the response: " + text, log)
            return code, (json.loads(text) if text.startswith("{") else {})
        yield base, models, log
    finally:
        if gw and gw.poll() is None:
            gw.terminate()
            try:
                gw.wait(timeout=10)
            except subprocess.TimeoutExpired:
                gw.kill()


def profile_case(binary, fake):
    """config.json without providers; the active profile (chosen by
    PASCLAW_PROFILE) inherits a base profile that supplies them."""
    home = tempfile.mkdtemp(prefix="pasclaw-provider-models-profile-e2e-")
    gport = free_port()
    try:
        os.makedirs(os.path.join(home, "profiles"))
        base_path = os.path.join(home, "profiles", "pm-base-q4.json")
        base_body = {"_description": "providers for the e2e",
                     "providers": [{"name": "fp", "kind": "openai", "api_base": fake,
                                    "api_key": "${PM_TEST_KEY_P4}", "model": "beta-2"}]}
        with open(base_path, "w") as f:
            json.dump(base_body, f)
        with open(os.path.join(home, "profiles", "pm-team-q4.json"), "w") as f:
            json.dump({"_inherits": ["pm-base-q4"], "default_provider": "fp", "default_model": "beta-2"}, f)
        with open(os.path.join(home, "config.json"), "w") as f:
            json.dump({"gateway": {"port": gport, "bind_addr": "127.0.0.1"}}, f)
        with gateway(binary, home, gport, PASCLAW_PROFILE="pm-team-q4", PM_TEST_KEY_P4="sk-p-q4") as (base, models, log):
            code, j = models("fp")
            if code != 200 or [m.get("id") for m in j.get("models", [])] != ["alpha-1", "beta-2"] \
                    or j.get("default_model") != "beta-2" or HITS[-1][1] != "Bearer sk-p-q4":
                fail("a provider the active profile supplies: %d %r" % (code, j), log)
            print("  ok: a provider the active profile (via an ancestor) supplies is listed")

            # Added to the profile's file while the gateway runs: the next
            # start would have it, so its picker lists it now.
            base_body["providers"].append({"name": "fq", "kind": "openai", "api_base": fake, "api_key": "sk-q-q4"})
            with open(base_path, "w") as f:
                json.dump(base_body, f)
            code, j = models("fq")
            if code != 200 or len(j.get("models", [])) != 2 or HITS[-1][1] != "Bearer sk-q-q4":
                fail("a provider added to the profile while the gateway runs: %d %r" % (code, j), log)
            if models("nosuch")[0] != 404:
                fail("an unknown provider is not a 404 under a profile", log)
            print("  ok: one added to the profile's file while the gateway runs is listed too")

            # The base profile's file goes away: the running gateway still
            # uses fp, so the running config answers for it.
            os.remove(base_path)
            code, j = models("fp")
            if code != 200 or len(j.get("models", [])) != 2:
                fail("a provider the running gateway uses, once its profile file is gone: %d %r" % (code, j), log)
            print("  ok: with the profile file gone, the running config still answers")
    finally:
        shutil.rmtree(home, ignore_errors=True)


def main():
    binary = os.path.abspath(sys.argv[1])
    home = tempfile.mkdtemp(prefix="pasclaw-provider-models-e2e-")
    pport, gport = free_port(), free_port()
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", pport), Provider)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    fake = "http://127.0.0.1:%d" % pport
    with open(os.path.join(home, "config.json"), "w") as f:
        json.dump({"providers": [
            {"name": "fa", "kind": "openai", "api_base": fake, "api_key": "${PM_TEST_KEY_Q4}", "model": "alpha-1"},
            {"name": "broken", "kind": "openai", "api_base": fake + "/broken", "api_key": "sk-broken"},
            {"name": "slow", "kind": "openai", "api_base": fake + "/slow", "api_key": "sk-broken"}],
            "default_provider": "fa", "default_model": "alpha-1",
            "gateway": {"port": gport, "bind_addr": "127.0.0.1"}}, f)
    try:
        with gateway(binary, home, gport, PM_TEST_KEY_Q4="sk-a-q4") as (base, models, log):
            HITS.clear()
            code, j = models("fa")
            ids = [m.get("id") for m in j.get("models", [])]
            if code != 200 or ids != ["alpha-1", "beta-2"] or j.get("source") != "live":
                fail("first call: %d %r" % (code, j), log)
            if j.get("default_model") != "alpha-1" or j.get("provider") != "fa" or j.get("kind") != "openai":
                fail("first call: provider fields %r" % j, log)
            if not HITS or HITS[-1][1] != "Bearer sk-a-q4":
                fail("the live fetch did not use the resolved key: %r" % HITS, log)
            print("  ok: a live fetch with the resolved key lists the models")

            n = len(HITS)
            code, j = models("fa")
            if j.get("source") != "cache" or len(HITS) != n or len(j.get("models", [])) != 2:
                fail("second call did not come from the cache: %r (hits %d -> %d)" % (j, n, len(HITS)), log)
            code, j = models("fa", "?refresh=1")
            if j.get("source") != "live" or len(HITS) != n + 1:
                fail("?refresh=1 did not fetch again: %r" % j, log)
            print("  ok: the cache answers next; ?refresh=1 fetches again")

            # Two requests at once for a provider with no cache yet (the
            # chat's roster and a Settings picker on one page load): one
            # call to the provider; the second waits and takes the list.
            got = []
            ts = [threading.Thread(target=lambda: got.append(models("slow"))) for _ in range(2)]
            for t in ts:
                t.start()
            for t in ts:
                t.join(30)
            slow_hits = [h for h in HITS if h[0].startswith("/slow/")]
            if len(slow_hits) != 1:
                fail("two requests at once fetched %d times" % len(slow_hits), log)
            if sorted(j.get("source") for _, j in got) != ["cache", "live"] or \
                    any(c != 200 or len(j.get("models", [])) != 2 for c, j in got):
                fail("two requests at once: %r" % got, log)
            print("  ok: two requests at once cost the provider one call")

            code, j = models("broken")
            if code != 200 or j.get("source") != "none" or not j.get("error") or j.get("models"):
                fail("a failing provider: %d %r" % (code, j), log)
            code, j = models("nosuch")
            if code != 404:
                fail("an unknown provider answered %d" % code, log)
            print("  ok: a failing provider says why; an unknown one is a 404")

            req = urllib.request.Request(base + "/v1/config?source=file")
            cfg = json.loads(urllib.request.urlopen(req, timeout=30).read())
            cfg["providers"].append({"name": "fb", "kind": "openai", "api_base": fake, "api_key": "sk-b-q4"})
            put = urllib.request.Request(base + "/v1/config", method="PUT", data=json.dumps(cfg).encode(),
                                         headers={"Content-Type": "application/json"})
            if not json.loads(urllib.request.urlopen(put, timeout=30).read()).get("saved"):
                fail("could not save a new provider", log)
            code, j = models("fb")
            if code != 200 or [m.get("id") for m in j.get("models", [])] != ["alpha-1", "beta-2"] \
                    or HITS[-1][1] != "Bearer sk-b-q4":
                fail("a provider saved before a restart: %d %r" % (code, j), log)
            print("  ok: a provider saved in Settings is listed before a restart")

            # Added to config.json by hand while the gateway runs: the Settings
            # form shows it (it edits the saved file), so its picker must list it.
            disk = json.load(open(os.path.join(home, "config.json")))
            disk["providers"].append({"name": "fc", "kind": "openai", "api_base": fake, "api_key": "sk-c-q4"})
            with open(os.path.join(home, "config.json"), "w") as f:
                json.dump(disk, f)
            code, j = models("fc")
            if code != 200 or len(j.get("models", [])) != 2 or HITS[-1][1] != "Bearer sk-c-q4":
                fail("a provider added to config.json by hand: %d %r" % (code, j), log)
            print("  ok: a provider added to config.json by hand is listed too")

            STATE["fail"] = True
            code, j = models("fa", "?refresh=1")
            if j.get("source") != "cache" or len(j.get("models", [])) != 2 or not j.get("error"):
                fail("a failed refresh should return the cached list with the error: %r" % j, log)
            print("  ok: a failed refresh still returns the cached list, with the error")
        STATE["fail"] = False
        profile_case(binary, fake)
        print("provider_models_e2e: OK")
    finally:
        httpd.shutdown()
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    main()
