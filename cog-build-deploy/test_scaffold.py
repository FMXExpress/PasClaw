#!/usr/bin/env python3
"""Standalone test for the deploy scaffold's safety contract.

Run: python3 cog-build-deploy/test_scaffold.py   (needs the `cog` runtime;
`pip install cog`). Exits non-zero on failure.

The one invariant that must never regress: _scaffold_static_worker may only
point Cloudflare's static-asset serving at a DEDICATED web-output subdir
(public/dist/build/...). It must NEVER scaffold a config that serves the
workspace root, which also holds sessions/ + memory/ -- the conversation
history -- because that would publish it at the deployed URL.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import predict as P  # noqa: E402


def _write(home, rel, body="<h1>site</h1>"):
    path = os.path.join(home, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(body)


def _fail(msg):
    print("FAIL:", msg)
    sys.exit(1)


def main():
    pred = P.Predictor.__new__(P.Predictor)  # no setup()
    ws = "workspace"

    # 1. Dedicated public/ with index.html -> scaffold, serving ./public.
    h = tempfile.mkdtemp()
    _write(h, f"{ws}/public/index.html")
    proj = pred._scaffold_static_worker(h)
    toml = os.path.join(h, ws, "wrangler.toml")
    if proj is None or not os.path.isfile(toml):
        _fail("dedicated public/ should be scaffolded")
    body = open(toml).read()
    if 'directory = "./public"' not in body or "[assets]" not in body:
        _fail("scaffold must be an assets-only config pointing at ./public")
    print("  ok: dedicated public/ -> assets-only wrangler.toml for ./public")

    # 2. index.html ONLY at the workspace root -> REFUSE (no leak of sessions/).
    h = tempfile.mkdtemp()
    _write(h, f"{ws}/index.html")
    _write(h, f"{ws}/sessions/abc.json", '{"secret":"conversation"}')
    proj = pred._scaffold_static_worker(h)
    if proj is not None:
        _fail("root-only index.html must NOT be scaffolded (would serve sessions/)")
    if os.path.exists(os.path.join(h, ws, "wrangler.toml")):
        _fail("no wrangler.toml may be written when only the root has index.html")
    print("  ok: root-only index.html refused (workspace root never served)")

    # 3. Other recognised web dirs work too (dist/).
    h = tempfile.mkdtemp()
    _write(h, f"{ws}/dist/index.html")
    proj = pred._scaffold_static_worker(h)
    if proj is None or 'directory = "./dist"' not in open(os.path.join(h, ws, "wrangler.toml")).read():
        _fail("dist/ should scaffold serving ./dist")
    print("  ok: dist/ (and other web-output dirs) scaffold correctly")

    # 4. An existing wrangler.toml is never clobbered.
    h = tempfile.mkdtemp()
    _write(h, f"{ws}/public/index.html")
    _write(h, f"{ws}/wrangler.toml", "name = \"already-here\"\n")
    pred._scaffold_static_worker(h)
    if "already-here" not in open(os.path.join(h, ws, "wrangler.toml")).read():
        _fail("an existing wrangler.toml must not be overwritten")
    print("  ok: existing wrangler.toml left untouched")

    # 5. No web output at all -> nothing to scaffold.
    h = tempfile.mkdtemp()
    _write(h, f"{ws}/notes.txt", "just text")
    if pred._scaffold_static_worker(h) is not None:
        _fail("no index.html anywhere -> must return None")
    print("  ok: no static site -> no scaffold")

    # 6. Built output preferred over source public/ (review P2). A project with
    #    both public/index.html (source) and build/index.html (compiled) must
    #    serve the built artifact.
    h = tempfile.mkdtemp()
    _write(h, f"{ws}/public/index.html")
    _write(h, f"{ws}/build/index.html")
    pred._scaffold_static_worker(h)
    body = open(os.path.join(h, ws, "wrangler.toml")).read()
    if 'directory = "./build"' not in body:
        _fail("with both public/ and build/, must serve ./build (compiled), not ./public")
    print("  ok: built output (build/) preferred over source public/")

    # 7. Symlinked asset dir is refused (review P1) -- a `public -> .` link
    #    must NOT let the scaffold serve the workspace root (sessions/).
    h = tempfile.mkdtemp()
    os.makedirs(os.path.join(h, ws), exist_ok=True)
    _write(h, f"{ws}/sessions/abc.json", '{"secret":"x"}')
    _write(h, f"{ws}/index.html")  # root index (its dir is the root, itself unsafe)
    os.symlink(os.path.join(h, ws), os.path.join(h, ws, "public"))  # public -> workspace root
    proj = pred._scaffold_static_worker(h)
    if proj is not None:
        _fail("a symlinked asset dir (public -> workspace root) must be refused")
    if os.path.exists(os.path.join(h, ws, "wrangler.toml")):
        _fail("no wrangler.toml may be written for a symlinked asset dir")
    print("  ok: symlinked asset dir refused (no workspace-root exposure)")

    print("test_scaffold: OK")


if __name__ == "__main__":
    main()
