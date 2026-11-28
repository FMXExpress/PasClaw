#!/usr/bin/env node
/* The web UI of `pasclaw gateway` running inside FreePascalOS, in headless
   Chromium: scripts/test-fpos-qemu.py runs this against the port QEMU
   forwards to the gateway. The page is loaded with the gateway token in
   its storage (as the key button leaves it), a chat message is sent, and
   the fake model's reply has to show up in the conversation.

   usage: node fpos-webui-chat.js <base-url> <token> <message> <expected-reply>

   With FPOS_WEBUI_SCREENSHOT=<prefix> in the environment, the page is
   saved once the reply shows, tool cards open, as <prefix>-dark.png and
   <prefix>-light.png (1280x900 at 2x).

   Prints "ok: ..." and exits 0 when the reply shows; "skip: ..." and exits
   0 without Playwright; "FAIL: ..." and exits 1 otherwise, with what the
   page did (its /v1 requests and how they ended, its errors, the
   conversation's text). The system runs under TCG, so the waits are long. */
let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("skip: needs Playwright (require('playwright') failed)"); process.exit(0); }

const [base, token, message, expected] = process.argv.slice(2);
if (!base || !expected) { console.log("FAIL: usage: fpos-webui-chat.js <base-url> <token> <message> <expected-reply>"); process.exit(1); }

(async () => {
  const t0 = Date.now();
  const secs = () => ((Date.now() - t0) / 1000).toFixed(1) + " s";
  const trail = [], errors = [];
  let browser, page, state = null;
  try {
    const shot = process.env.FPOS_WEBUI_SCREENSHOT;
    browser = await chromium.launch();
    page = await browser.newPage(shot ? { viewport: { width: 1280, height: 900 }, deviceScaleFactor: 2,
                                          colorScheme: "dark" } : {});
    page.on("pageerror", e => errors.push(String(e)));
    page.on("console", m => { if (m.type() === "error") errors.push(m.text()); });
    const short = r => r.method() + " " + new URL(r.url()).pathname;
    page.on("requestfinished", async r => {
      if (!r.url().includes("/v1/")) return;
      const resp = await r.response().catch(() => null);
      trail.push(secs() + " " + short(r) + " -> " + (resp ? resp.status() : "?"));
    });
    page.on("requestfailed", r => trail.push(secs() + " " + short(r) + " failed: " + (r.failure() || {}).errorText));
    await page.addInitScript(t => { try { localStorage.setItem("pasclaw.gw_token.v1", t); } catch {} }, token);
    await page.goto(base + "/", { timeout: 180000 });
    await page.waitForSelector("#m", { timeout: 60000 });
    /* Let the page's first requests (status, sessions, models ...) finish
       before typing, as a person would: a message sent while the session
       list is still loading can be drawn and then wiped when it arrives,
       which a slow gateway (this one runs under TCG) makes likely. */
    await page.waitForLoadState("networkidle", { timeout: 60000 }).catch(() => {});
    const loaded = secs();
    await page.fill("#m", message);
    await page.press("#m", "Enter");
    state = await page.evaluate(() => ({
      composer: document.querySelector("#m").value,
      streaming: typeof streaming === "undefined" ? "?" : streaming,
    })).catch(() => null);
    await page.waitForFunction(text => {
      const log = document.querySelector("#log");
      return log && log.textContent.includes(text);
    }, expected, { timeout: 240000 });
    if (shot) {
      await page.waitForFunction(() => typeof streaming === "undefined" || !streaming, null, { timeout: 60000 })
        .catch(() => {});
      await page.evaluate(() => document.querySelectorAll("details.tool-card").forEach(d => { d.open = true; }));
      await page.waitForTimeout(500);
      await page.screenshot({ path: shot + "-dark.png" });
      await page.emulateMedia({ colorScheme: "light" });
      await page.waitForTimeout(500);
      await page.screenshot({ path: shot + "-light.png" });
    }
    console.log("ok: the reply showed in the page (loaded in " + loaded + ", replied at " + secs() + ")" +
                (errors.length ? "; page errors: " + errors.join("; ") : ""));
    await browser.close();
    process.exit(0);
  } catch (e) {
    console.log("FAIL: " + (e && e.message ? e.message.split("\n")[0] : String(e)) + " at " + secs());
    if (state) console.log("  after Enter: " + JSON.stringify(state));
    if (page) {
      const log = await page.evaluate(() => (document.querySelector("#log") || {}).textContent || "").catch(() => "");
      console.log("  conversation: " + JSON.stringify(log.slice(-400)));
    }
    if (errors.length) console.log("  page errors: " + errors.join(" | "));
    if (trail.length) console.log("  requests: " + trail.slice(0, 40).join(" | "));
    if (browser) await browser.close().catch(() => {});
    process.exit(1);
  }
})();
