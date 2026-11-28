#!/usr/bin/env node
/* The web UI's Stats tab, against the real gateway.

   One gateway starts with five saved conversations carrying counters (one
   whose provider and model hold HTML); a second has usage counters off and
   nothing saved. Through headless Chromium:

     - the strip and the caching panel show what GET /v1/stats says, with
       thousands separators;
     - the provider and model tables are sorted by tokens, right-aligned,
       with each row's share; names holding HTML are drawn as text (no
       element made, no script run);
     - with nothing counted, the empty state stands where the tables go, and
       with counters off, a banner says so and its link opens Settings on
       Diagnostics;
     - Reset asks first, in the page (no native dialog): Cancel keeps the
       totals; confirming empties them, says so, and the empty state shows;
     - phone width: no sideways scroll.

   Needs node with Playwright and a Chromium; skips without them.
   STATS_SHOTS=<dir> also writes dark, light, phone, confirm and empty
   screenshots.
   usage: node webui_stats_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_stats_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const shots = process.env.STATS_SHOTS || "";
if (shots) fs.mkdirSync(shots, { recursive: true });

let failures = 0, gwLog = "";
const fail = msg => { console.log("FAIL: " + msg); failures++; throw new Error(msg); };
const ok = msg => console.log("  ok: " + msg);
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, what, ms = 12000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch {} await sleep(50); }
  fail("timed out waiting for " + what);
}
function freePort() {
  return new Promise(r => { const s = http.createServer().listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => r(p)); }); });
}

const EVIL_PROVIDER = "<b id=evil-p>evil</b>";
const EVIL_MODEL = '<img id=evil-m src=x onerror="window.__xss=1">';
const S = (i, o, cr, cw, t, tc, b) => ({ input_tokens: i, output_tokens: o, cache_read_tokens: cr, cache_created_tokens: cw,
                                         turns: t, tool_calls: tc, truncation_bytes_saved: b });
const SEED = [
  { id: "a1", provider: "anthropic", model: "claude-opus-4-7", stats: S(812345, 154321, 640000, 42000, 212, 980, 3456789) },
  { id: "a2", provider: "anthropic", model: "claude-sonnet-4-5", stats: S(301200, 61200, 120000, 9000, 88, 301, 120000) },
  { id: "o1", provider: "openai", model: "gpt-5.1", stats: S(204500, 40100, 0, 0, 41, 77, 0) },
  { id: "l1", provider: "local-llama", model: "Qwen2.5-Coder-7B-Instruct", stats: S(9800, 2100, 0, 0, 9, 4, 0) },
  { id: "x1", provider: EVIL_PROVIDER, model: EVIL_MODEL, stats: S(120, 30, 0, 0, 1, 0, 0) },
];

/* A gateway of its own, in a home of its own, with saved conversations. */
async function startGateway(seed, statsOn, tag) {
  const port = await freePort();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-stats-" + tag + "-"));
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify({
    gateway: { port, bind_addr: "127.0.0.1" }, stats_collection_enabled: statsOn,
    providers: [{ name: "fake", kind: "openai", api_base: "http://127.0.0.1:9/v1", api_key: "sk-test", model: "m" }],
    default_provider: "fake", default_model: "m" }));
  const dir = path.join(home, "workspace", "sessions");
  fs.mkdirSync(dir, { recursive: true });
  for (const s of seed)
    fs.writeFileSync(path.join(dir, s.id + ".json"), JSON.stringify({ meta: { id: s.id, title: s.id, provider: s.provider,
      model: s.model, created_at: 1764200000, updated_at: 1764200000, stats: s.stats }, messages: [] }));
  const proc = spawn(binary, ["gateway", "--port", String(port), "--addr", "127.0.0.1", "--no-mcp"],
                     { cwd: home, env: Object.assign({}, process.env, { PASCLAW_HOME: home }), stdio: ["ignore", "pipe", "pipe"] });
  proc.stdout.on("data", d => gwLog += d); proc.stderr.on("data", d => gwLog += d);
  const base = `http://127.0.0.1:${port}`;
  await until(async () => (await fetch(base + "/v1/health")).ok, "the " + tag + " gateway");
  return { base, home, proc };
}

(async () => {
  const A = await startGateway(SEED, true, "data");
  const B = await startGateway([], false, "off");
  const stats = async g => (await fetch(g.base + "/v1/stats")).json();

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: "dark", locale: "en-US" });
  const page = await ctx.newPage();
  let dialogs = 0;
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  page.on("dialog", d => { dialogs++; d.dismiss(); });
  const shot = async name => { if (shots) await page.screenshot({ path: path.join(shots, name) }); };
  const text = async sel => (await page.textContent(sel)).trim();
  const digits = async sel => (await text(sel)).replace(/[^\d]/g, "");
  const visible = sel => page.isVisible(sel);
  const rows = sel => page.$$eval(sel + " tbody tr", trs => trs.map(tr => [...tr.cells].map(td => td.textContent.trim())));

  try {
    /* ---- the numbers ---- */
    await page.goto(A.base + "/#stats");
    await page.waitForSelector("#stats-pane");
    const j = await stats(A);
    if (!(j.input_tokens > 0)) fail("the seeded gateway reports no input tokens: " + JSON.stringify(j));
    await until(async () => (await digits("#stats-in")) === String(j.input_tokens), "the strip to load");
    const cells = { "#stats-in": "input_tokens", "#stats-out": "output_tokens", "#stats-turns": "turns",
                    "#stats-tool-calls": "tool_calls", "#stats-sessions": "sessions", "#stats-cache-r": "cache_read_tokens",
                    "#stats-cache-w": "cache_created_tokens", "#stats-warm-pings": "prompt_cache_warm_pings" };
    for (const [sel, key] of Object.entries(cells))
      if ((await digits(sel)) !== String(j[key])) fail(sel + " reads " + (await text(sel)) + ", /v1/stats has " + key + " " + j[key]);
    if ((await text("#stats-in")) !== "1,327,965") fail("input tokens have no thousands separators: " + (await text("#stats-in")));
    if ((await text("#stats-bytes-saved")) !== "3.4 MB") fail("bytes saved reads " + (await text("#stats-bytes-saved")));
    if (!/^Updated /.test(await text("#stats-updated"))) fail("no refresh time: " + (await text("#stats-updated")));
    ok("strip and caching panel match /v1/stats (" + (await text("#stats-in")) + " in, " + (await text("#stats-out")) + " out)");

    /* ---- the tables, and names as text ---- */
    const prov = await rows("#stats-by-provider"), model = await rows("#stats-by-model");
    const wantProv = j.by_provider.slice().sort((a, b) => b.tokens - a.tokens);
    if (prov.length !== wantProv.length) fail("provider rows: " + JSON.stringify(prov));
    wantProv.forEach((r, i) => {
      if (prov[i][0] !== r.provider || prov[i][1].replace(/,/g, "") !== String(r.tokens)) fail("provider row " + i + ": " + JSON.stringify(prov[i]) + " vs " + JSON.stringify(r));
    });
    if (prov[0][2] !== "84%") fail("anthropic's share reads " + prov[0][2]);
    if (model.length !== j.by_model.length || model[0][0] !== "claude-opus-4-7") fail("model rows: " + JSON.stringify(model));
    const align = await page.$eval("#stats-by-model tbody td.num", td => getComputedStyle(td).textAlign);
    if (align !== "right") fail("token counts are aligned " + align);
    const evilP = prov.find(r => r[0].includes("evil")), evilM = model.find(r => r[0].includes("img"));
    if (!evilP || evilP[0] !== EVIL_PROVIDER) fail("the HTML provider name is not shown as text: " + JSON.stringify(evilP));
    if (!evilM || evilM[0] !== EVIL_MODEL) fail("the HTML model name is not shown as text: " + JSON.stringify(evilM));
    if (await page.$("#evil-p, #evil-m")) fail("a name holding HTML made an element");
    await sleep(200);
    if (await page.evaluate(() => window.__xss)) fail("a model name ran script");
    ok("tables sorted by tokens with shares, counts right-aligned; HTML in provider and model names drawn as text");
    if (await visible("#stats-empty")) fail("the empty state shows with usage counted");

    if (shots) {
      await shot("stats-dark.png");
      await page.click("#theme-btn"); await sleep(250); await shot("stats-light.png"); await page.click("#theme-btn");
    }

    /* ---- phone width ---- */
    await page.setViewportSize({ width: 390, height: 844 });
    await sleep(150);
    const w = await page.evaluate(() => { const p = document.querySelector("#stats-pane");
      return [document.documentElement.scrollWidth, document.body.scrollWidth, p.scrollWidth, p.clientWidth]; });
    if (w[0] > 390 || w[1] > 390 || w[2] > w[3]) fail("sideways scroll at phone width: " + w);
    await shot("stats-phone.png");
    await page.setViewportSize({ width: 1280, height: 900 });
    ok("phone width: no sideways scroll");

    /* ---- Reset asks first ---- */
    if (await visible("#stats-confirm")) fail("the reset confirm shows before Reset is pressed");
    await page.click("#stats-reset");
    await until(() => visible("#stats-confirm"), "the reset confirm");
    if ((await page.evaluate(() => document.activeElement && document.activeElement.id)) !== "stats-reset-cancel") fail("Cancel does not have focus in the confirm");
    await page.click("#stats-reset-cancel");
    await until(async () => !(await visible("#stats-confirm")), "the confirm to close on Cancel");
    if ((await stats(A)).input_tokens !== j.input_tokens) fail("Cancel reset the totals");
    ok("Reset opens a confirm in the page with Cancel focused; Cancel keeps the totals");

    await page.click("#stats-reset");
    await until(() => visible("#stats-confirm"), "the reset confirm, again");
    await shot("stats-confirm.png");
    await page.click("#stats-reset-go");
    await until(async () => (await stats(A)).input_tokens === 0, "the gateway's totals to reset");
    await until(async () => (await digits("#stats-in")) === "0" && (await visible("#stats-empty")), "zeros and the empty state after the reset");
    if (await visible("#stats-confirm")) fail("the confirm stays open after the reset");
    if (!/Totals reset/.test(await text("#stats-note"))) fail("the note after a reset reads " + JSON.stringify(await text("#stats-note")));
    if (await visible("#stats-tables")) fail("the tables still show after the reset");
    if (dialogs) fail(dialogs + " native dialog(s) opened");
    ok("confirming resets the totals, says so, and the empty state shows; no native dialog");

    /* ---- counters off, nothing saved ---- */
    await page.goto(B.base + "/#stats");
    await until(async () => (await page.getAttribute("#stats-hint", "data-state")) === "warn", "the counters-off banner");
    if (!/Usage counters are off/.test(await text("#stats-hint"))) fail("the banner reads " + (await text("#stats-hint")));
    if (!(await visible("#stats-empty")) || (await visible("#stats-tables"))) fail("no empty state with nothing counted");
    if ((await digits("#stats-in")) !== "0") fail("input tokens read " + (await text("#stats-in")) + " with nothing counted");
    if (shots) { await sleep(400); await shot("stats-empty.png"); }
    await page.click("#stats-hint a[data-stats-settings]");
    await until(async () => (await page.getAttribute('#set-nav button[data-sec="diagnostics"]', "aria-current")) === "true", "Settings on Diagnostics");
    ok("counters off: a banner whose link opens Settings on Diagnostics; nothing counted: the empty state");

    if (failures) throw new Error(failures + " failure(s)");
    console.log("webui_stats_e2e: OK");
  } catch (e) {
    if (!failures) console.log("FAIL: " + e.message);
    console.log("---- gateway log (tail) ----\n" + gwLog.split("\n").slice(-25).join("\n"));
    process.exitCode = 1;
  } finally {
    await browser.close();
    for (const g of [A, B]) { g.proc.kill(); fs.rmSync(g.home, { recursive: true, force: true }); }
  }
})();
