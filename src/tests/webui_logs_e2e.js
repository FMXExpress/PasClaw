#!/usr/bin/env node
/* The web UI's Logs tab, against the real gateway.

   One gateway runs at log_level debug (every request writes a debug
   line naming its path) with an MCP server that cannot start, whose
   command holds HTML, so its buffer has info, warn and debug lines. A
   second gateway needs a token the page does not have. Through headless
   Chromium:

     - the buffer is shown, then new lines arrive live, with a time;
     - the level chips and the text filter hide and show lines, and
       Download saves the lines shown;
     - Pause holds new lines back and Resume brings them;
     - HTML in a log line (the MCP command, a request path) is text;
     - the view holds at most 2000 lines;
     - a gateway restart shows as reconnecting, then live again, with no
       line shown twice;
     - a refused stream shows the error state;
     - phone width: no sideways scroll.

   Needs node with Playwright and a Chromium; skips without them.
   LOGS_SHOTS=<dir> also writes screenshots there.
   usage: node webui_logs_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_logs_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const shots = process.env.LOGS_SHOTS || "";
if (shots) fs.mkdirSync(shots, { recursive: true });

let failures = 0, gwLog = "";
const fail = msg => { console.log("FAIL: " + msg); failures++; throw new Error(msg); };
const ok = msg => console.log("  ok: " + msg);
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, what, ms = 15000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch {} await sleep(50); }
  fail("timed out waiting for " + what);
}
function freePort() {
  return new Promise(r => { const s = http.createServer().listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => r(p)); }); });
}

const XSS_CMD = '/nonexistent/<img src=x onerror="window.__lgXss=1">';
const XSS_PATH = "/lg-xss/<img src=x onerror=window.__lgXss=2>";

function spawnGateway(g) {
  const proc = spawn(binary, ["gateway", "--port", String(g.port), "--addr", "127.0.0.1"],
                     { cwd: g.home, env: Object.assign({}, process.env, { PASCLAW_HOME: g.home }, g.env || {}),
                       stdio: ["ignore", "pipe", "pipe"] });
  proc.stdout.on("data", d => gwLog += d); proc.stderr.on("data", d => gwLog += d);
  g.proc = proc;
}
async function startGateway(tag, env) {
  const port = await freePort();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-logs-" + tag + "-"));
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify({
    gateway: { port, bind_addr: "127.0.0.1", log_level: "debug" },
    providers: [{ name: "fake", kind: "openai", api_base: "http://127.0.0.1:9/v1", api_key: "sk-test", model: "m" }],
    default_provider: "fake", default_model: "m",
    mcp_servers: [{ name: "broken", cmd: XSS_CMD, args: "--stdio", enabled: true }] }));
  const g = { port, home, env, base: `http://127.0.0.1:${port}` };
  spawnGateway(g);
  await until(async () => (await fetch(g.base + "/v1/health")).status > 0, "the " + tag + " gateway");
  return g;
}

(async () => {
  const A = await startGateway("main");
  const B = await startGateway("token", { PASCLAW_GATEWAY_TOKEN: "lg-secret-token" });
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: "dark", acceptDownloads: true });
  const page = await ctx.newPage();
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  page.on("dialog", d => d.dismiss());
  const shot = async name => { if (shots) await page.screenshot({ path: path.join(shots, name) }); };
  const lines = () => page.$$eval("#lg-view .lg-line", rs => rs.map(r => ({
    lv: r.querySelector(".lg-lv").textContent, t: r.querySelector("time").textContent,
    msg: r.querySelector(".lg-msg").textContent, hidden: r.hidden })));
  const has = async s => (await lines()).some(l => l.msg.includes(s));
  const state = () => page.getAttribute("#lg-state", "data-state");

  try {
    /* ---- the buffer, then live lines ---- */
    await page.goto(A.base + "/#logs");
    await until(async () => (await state()) === "live" && (await page.locator("#lg-view .lg-mark").count()) > 0,
                "the stream to go live and the buffer to be shown");
    /* The lines before the "Live from" mark are the replayed buffer. */
    const first = await page.$$eval("#lg-view > *", rs => {
      const out = [];
      for (const r of rs) {
        if (r.classList.contains("lg-mark")) break;
        out.push({ lv: r.querySelector(".lg-lv").textContent, t: r.querySelector("time").textContent,
                   msg: r.querySelector(".lg-msg").textContent });
      }
      return out;
    });
    if (!first.length || first.some(l => l.t !== "")) fail("buffered lines: " + JSON.stringify(first.slice(0, 3)));
    for (const lv of ["info", "warn", "debug"])
      if (!first.some(l => l.lv === lv)) fail("no " + lv + " line in the buffer");
    if (!first.some(l => l.lv === "warn" && l.msg.includes("mcp[broken]"))) fail("the failing MCP server's warning is missing");
    ok("the gateway's buffer is shown, untimed, with info, warn and debug lines");

    await fetch(A.base + "/lg-probe-live");
    await until(() => has("/lg-probe-live"), "a live line");
    const live = (await lines()).find(l => l.msg.includes("/lg-probe-live"));
    if (!/^\d\d:\d\d:\d\d$/.test(live.t) || live.lv !== "debug") fail("live line: " + JSON.stringify(live));
    ok("a new line arrives live, with the time it came in and its level");

    /* ---- HTML in a line is text ---- */
    await fetch(A.base + XSS_PATH.replace(/[<>= ]/g, c => encodeURIComponent(c)));
    await until(() => has("/lg-xss/"), "the request-path line");
    await shot("logs-desktop-dark.png");
    const xss = await page.evaluate(() => [window.__lgXss, document.querySelectorAll("#lg-view img").length,
      [...document.querySelectorAll("#lg-view .lg-msg")].some(m => m.textContent.includes('<img src=x onerror="window.__lgXss=1">'))]);
    if (xss[0] !== undefined || xss[1] !== 0 || !xss[2]) fail("HTML in a log line rendered as markup: " + JSON.stringify(xss));
    ok("HTML in a log line is drawn as text");

    /* ---- level chips and the text filter ---- */
    await page.click('.lg-chip[data-lv="debug"]');
    let ls = await lines();
    if (ls.some(l => l.lv === "debug" && !l.hidden) || !ls.some(l => !l.hidden)) fail("Debug off still shows debug lines");
    if ((await page.getAttribute('.lg-chip[data-lv="debug"]', "aria-pressed")) !== "false") fail("the Debug chip is not off");
    await page.click('.lg-chip[data-lv="info"]');
    ls = await lines();
    if (ls.some(l => l.lv !== "warn" && !l.hidden) || !ls.some(l => l.lv === "warn" && !l.hidden)) fail("Info and Debug off: " + ls.filter(l => !l.hidden).map(l => l.lv));
    await shot("logs-filtered-desktop-dark.png");
    await page.click('.lg-chip[data-lv="info"]');
    await page.click('.lg-chip[data-lv="debug"]');
    ok("level chips hide and show their lines");

    await page.fill("#lg-q", "LG-PROBE");
    await until(async () => { const v = (await lines()).filter(l => !l.hidden); return v.length === 1 && v[0].msg.includes("/lg-probe-live"); },
                "the text filter to leave the one probe line");
    if (!/1 of [\d,]+ lines shown/.test(await page.textContent("#lg-count"))) fail("the count: " + await page.textContent("#lg-count"));
    const [dl] = await Promise.all([page.waitForEvent("download"), page.click("#lg-download")]);
    const saved = fs.readFileSync(await dl.path(), "utf8");
    if (!/^\d\d:\d\d:\d\d \[debug\] gateway: GET \/lg-probe-live\n$/.test(saved)) fail("download: " + JSON.stringify(saved));
    await page.fill("#lg-q", "no-such-line-anywhere");
    await until(() => page.isVisible("#lg-empty"), "the no-match state");
    if (!/No lines match/.test(await page.textContent("#lg-empty"))) fail("no-match state: " + await page.textContent("#lg-empty"));
    await page.click("#lg-empty-btn");
    await until(async () => (await lines()).every(l => !l.hidden) && (await page.inputValue("#lg-q")) === "", "Show all lines");
    ok("the text filter matches case-insensitively, Download saves only the lines shown, no match has its own state");

    /* ---- pause and resume ---- */
    await page.click("#lg-pause");
    await fetch(A.base + "/lg-while-paused");
    await until(async () => /Paused · \d+ new/.test(await page.textContent("#lg-state")), "the paused count");
    await sleep(400);
    if (await has("/lg-while-paused")) fail("a line appeared while paused");
    if ((await state()) !== "paused" || (await page.textContent("#lg-pause")).trim() !== "Resume") fail("pause state");
    await shot("logs-paused-desktop-dark.png");
    await page.click("#lg-pause");
    await until(() => has("/lg-while-paused"), "the held line after Resume");
    if ((await state()) !== "live") fail("not live after Resume");
    ok("Pause holds new lines back and Resume brings them");

    /* ---- the cap ---- */
    for (let i = 0; i < 2300; i += 50)
      await Promise.all(Array.from({ length: 50 }, (_, j) => fetch(A.base + "/lg-cap-" + (i + j)).then(r => r.text()).catch(() => {})));
    await until(() => has("/lg-cap-2299"), "the last cap line", 30000);
    await sleep(300);
    const held = await page.$$eval("#lg-view > *", rs => rs.length);
    if (held > 2000) fail("the view holds " + held + " rows");
    if ((await lines()).some(l => /\/lg-cap-0$/.test(l.msg)) || await has("/lg-probe-live")) fail("the oldest lines were not dropped");
    if (!/Holding the newest 2,000 lines/.test(await page.textContent("#lg-note"))) fail("the cap note: " + await page.textContent("#lg-note"));
    const scrolled = await page.$eval("#lg-view", v => v.scrollHeight - v.scrollTop - v.clientHeight < 40);
    if (!scrolled) fail("the view did not follow new lines while at the bottom");
    ok("the view holds at most 2000 lines and keeps the newest, following the tail");

    /* ---- scrolled up: no auto-scroll, a Latest button ---- */
    await page.$eval("#lg-view", v => { v.scrollTop = 0; v.dispatchEvent(new Event("scroll")); });
    await fetch(A.base + "/lg-while-up");
    await until(() => has("/lg-while-up"), "a line while scrolled up");
    await until(() => page.isVisible("#lg-jump"), "the Latest button");
    if ((await page.$eval("#lg-view", v => v.scrollTop)) !== 0) fail("the view moved while the reader was scrolled up");
    if (!/Latest · \d+ new/.test(await page.textContent("#lg-jump"))) fail("Latest: " + await page.textContent("#lg-jump"));
    await page.click("#lg-jump");
    await until(async () => await page.isHidden("#lg-jump") &&
      await page.$eval("#lg-view", v => v.scrollHeight - v.scrollTop - v.clientHeight < 40), "Latest to go to the bottom");
    ok("scrolled up, the view stays put and Latest brings the reader back");

    /* ---- clear ---- */
    await page.click("#lg-clear");
    if ((await page.locator("#lg-view > *").count()) !== 0 || !/View cleared/.test(await page.textContent("#lg-empty")))
      fail("Clear did not empty the view");
    await fetch(A.base + "/lg-after-clear");
    await until(() => has("/lg-after-clear"), "a line after Clear");
    ok("Clear empties the view and new lines keep coming");

    /* ---- the gateway restarts ---- */
    A.proc.kill();
    await until(async () => (await state()) === "reconnecting", "the reconnecting state");
    await shot("logs-reconnecting-desktop-dark.png");
    await sleep(500);
    spawnGateway(A);
    await until(async () => (await state()) === "live", "live again after the restart", 30000);
    await until(async () => /Reconnected at/.test(await page.textContent("#lg-view")), "the reconnected mark");
    await fetch(A.base + "/lg-after-restart");
    await until(() => has("/lg-after-restart"), "a line after the restart");
    const after = (await lines()).filter(l => l.t);
    const seen = new Set();
    for (const l of after) { if (seen.has(l.t + l.msg) && /lg-/.test(l.msg)) fail("a line shown twice: " + l.msg); seen.add(l.t + l.msg); }
    if ((await lines()).filter(l => l.msg.includes("/lg-after-clear")).length !== 1) fail("the line before the restart is shown twice");
    ok("a dropped stream shows as reconnecting, then live again, with nothing shown twice");

    /* ---- light theme, phone width ---- */
    await page.click("#theme-btn");
    await sleep(300);
    await shot("logs-desktop-light.png");
    await page.setViewportSize({ width: 390, height: 844 });
    await sleep(200);
    await shot("logs-phone-light.png");
    const sw = await page.evaluate(() => [document.documentElement.scrollWidth, document.querySelector("#lg-view").scrollWidth,
                                          document.querySelector("#lg-view").clientWidth, document.querySelector("#tab-logs").scrollWidth,
                                          document.querySelector("#tab-logs").clientWidth]);
    if (sw[0] > 390 || sw[1] > sw[2] || sw[3] > sw[4]) fail("sideways scroll at phone width: " + sw);
    await page.click("#theme-btn");
    await shot("logs-phone-dark.png");
    ok("phone width: no sideways scroll");

    /* ---- a refused stream ---- */
    const page2 = await ctx.newPage();
    page2.on("dialog", d => d.dismiss());
    await page2.setViewportSize({ width: 1280, height: 900 });
    await page2.goto(B.base + "/#logs");
    await until(async () => (await page2.getAttribute("#lg-state", "data-state")) === "down", "the down state");
    const err = (await page2.textContent("#lg-empty")).replace(/\s+/g, " ");
    if (!(await page2.isVisible("#lg-empty")) || !/Can't open the log stream/.test(err) || !/Retry now/.test(err)) fail("error state: " + err);
    if (shots) await page2.screenshot({ path: path.join(shots, "logs-error-desktop-dark.png") });
    ok("a refused stream shows the error state with Retry now");
  } catch (e) {
    if (!failures) { console.log("FAIL: " + (e && e.stack || e)); failures++; }
  } finally {
    await browser.close();
    A.proc.kill(); B.proc.kill();
    for (const g of [A, B]) try { fs.rmSync(g.home, { recursive: true, force: true }); } catch {}
  }
  if (failures) {
    console.log("--- gateway log (tail) ---\n" + gwLog.split("\n").slice(-30).join("\n"));
    process.exit(1);
  }
  console.log("webui_logs_e2e: all checks passed");
})();
