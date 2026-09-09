#!/usr/bin/env python3
"""Capture PasClaw's browser surfaces into docs/screenshots/.

Deliberately shot against a gateway holding real content -- a completed
conversation, seeded workspace memory, a few projects -- because an empty
shell documents the chrome and nothing else.

Device scale factor 1: these live in the repo, and the 2x versions were
~1.4 MB each for no legibility gain at this viewport.
"""
import os, sys
from playwright.sync_api import sync_playwright

BASE = os.environ.get("PASCLAW_SHOT_BASE", "http://127.0.0.1:8330")
OUT  = sys.argv[1]
EXE  = "/opt/pw-browsers/chromium-1194/chrome-linux/chrome"
W, H = 1600, 1000

os.makedirs(OUT, exist_ok=True)
results = []

with sync_playwright() as p:
    browser = p.chromium.launch(executable_path=EXE, args=["--no-sandbox"])

    def shot(name, path, click=None, then=None, settle=2500):
        page = browser.new_page(viewport={"width": W, "height": H},
                                device_scale_factor=1)
        errs = []
        page.on("pageerror", lambda e: errs.append(str(e)))
        page.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)
        page.goto(BASE + path, wait_until="networkidle", timeout=30000)
        page.wait_for_timeout(settle)
        if click:
            page.locator("nav button", has_text=click).first.click()
            page.wait_for_timeout(1800)
        for label in (then or []):
            page.get_by_text(label).first.click()
            page.wait_for_timeout(1500)
        dest = os.path.join(OUT, name + ".png")
        page.screenshot(path=dest)
        results.append((name, os.path.getsize(dest), page.title(), list(errs)[:2]))
        page.close()

    shot("web-ui-chat",    "/")
    shot("web-ui-memory",  "/", click="MEMORY", then=["MEMORY.md"])
    shot("web-desktop",    "/desktop")

    browser.close()

for name, size, title, errs in results:
    print("%-16s %7d bytes  title=%r%s"
          % (name, size, title, ("  JS-ERRORS=%s" % errs) if errs else ""))
