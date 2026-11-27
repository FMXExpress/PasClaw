#!/usr/bin/env node
/* The web UI's Cron tab, against the real gateway.

   One gateway has cron jobs in config.json (enabled and disabled, simple
   and complex schedules, HTML in an id and in the arguments) and a
   scheduler state file that says one of them has fired; it runs at
   UTC+05:30, so last_fired has to be turned from the scheduler's local
   slot into a true unix time (FPC reads TZ in the ":Area/City" form). A
   second gateway has no jobs. Through
   headless Chromium:

     - the rows match GET /v1/cron: ids in order, enabled or disabled,
       the spec, a last run with the route's time for the job that fired
       and "Not yet" for the rest; the fired slot comes back as the UTC
       instant it was;
     - the plain reading is right for simple expressions and absent for
       ones it cannot read exactly;
     - HTML in a job id and in its arguments is drawn as text;
     - Show all appears for long arguments and opens them;
     - the Settings link opens Settings on Scheduling;
     - with no jobs, the empty state shows;
     - phone width: no sideways scroll.

   Needs node with Playwright and a Chromium; skips without them.
   CRON_SHOTS=<dir> also writes screenshots there.
   usage: node webui_cron_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_cron_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const shots = process.env.CRON_SHOTS || "";
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

const XSS_ID = '<img src=x onerror="window.__cronXss=1">';
const XSS_ARGS = '<b>bold</b> & <script>window.__cronXss=2</script>';
const LONG_ARGS = "Summarize my inbox, today's calendar and any GitHub notifications that mention me. "
  + "Keep it to ten bullet points, most urgent first. ".repeat(6) + "END-OF-ARGS";
/* Disabled jobs keep their state: the scheduler skips them, so nothing
   re-stamps the fired slot while the test runs. */
const CRONS = [
  { id: "morning-brief", spec: "0 9 * * 1-5", skill: "daily-brief", args: LONG_ARGS, enabled: true,
    channel_kind: "slack", channel_target: "https://hooks.slack.test/T0/B0/secret" },
  { id: "inbox-sweep", spec: "*/5 * * * *", skill: "triage", args: "label:inbox", enabled: false },
  { id: XSS_ID, spec: "0 17 * * 5", skill: "weekly", args: XSS_ARGS, enabled: false },
  { id: "quarter-close", spec: "15 8,20 1-7 */3 1", skill: "finance-close", args: "", enabled: false },
];
/* The scheduler stamps a slot as its local wall-clock time in unix form;
   at UTC+05:30 the instant FIRED_UTC is stored 5.5 h later. */
const FIRED_UTC = Math.floor(Date.now() / 1000) - 2 * 3600 - 17 * 60;
const FIRED_STORED = FIRED_UTC + 5.5 * 3600;

async function startGateway(crons, state, tag) {
  const port = await freePort();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-cron-" + tag + "-"));
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify({
    gateway: { port, bind_addr: "127.0.0.1" }, crons,
    providers: [{ name: "fake", kind: "openai", api_base: "http://127.0.0.1:9/v1", api_key: "sk-test", model: "m" }],
    default_provider: "fake", default_model: "m" }));
  if (state) {
    fs.mkdirSync(path.join(home, "workspace", "cron"), { recursive: true });
    fs.writeFileSync(path.join(home, "workspace", "cron", "state.json"), JSON.stringify({ entries: state }));
  }
  const proc = spawn(binary, ["gateway", "--port", String(port), "--addr", "127.0.0.1", "--no-mcp"],
                     { cwd: home, env: Object.assign({}, process.env, { PASCLAW_HOME: home, TZ: ":Asia/Kolkata" }),
                       stdio: ["ignore", "pipe", "pipe"] });
  proc.stdout.on("data", d => gwLog += d); proc.stderr.on("data", d => gwLog += d);
  const base = `http://127.0.0.1:${port}`;
  await until(async () => (await fetch(base + "/v1/health")).ok, "the " + tag + " gateway");
  return { base, home, proc };
}

(async () => {
  const A = await startGateway(CRONS, [{ id: XSS_ID, last_fired: FIRED_STORED }], "jobs");
  const B = await startGateway([], null, "empty");
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: "dark" });
  const page = await ctx.newPage();
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  page.on("dialog", d => d.dismiss());
  const shot = async name => { if (shots) await page.screenshot({ path: path.join(shots, name), fullPage: true }); };
  const rowOf = i => page.locator("#cron-list .cr-job").nth(i);

  try {
    /* ---- the route ---- */
    const route = (await (await fetch(A.base + "/v1/cron")).json()).entries;
    if (!Array.isArray(route) || route.length !== CRONS.length) fail("GET /v1/cron entries: " + JSON.stringify(route));
    const fired = route.find(c => c.id === XSS_ID);
    if (fired.last_fired !== FIRED_UTC) fail(`last_fired ${fired.last_fired}, want the UTC instant ${FIRED_UTC}`);
    if (route.filter(c => c.id !== XSS_ID).some(c => c.last_fired !== null)) fail("a job that never fired has a last_fired");
    ok("GET /v1/cron: last_fired is the fired slot as a true unix time, null for the rest");
    const raw = await (await fetch(A.base + "/v1/cron")).text();
    if (raw.includes("hooks.slack.test") || raw.includes("/secret")) fail("GET /v1/cron serves a webhook URL unmasked");
    if (!route.some(c => c.channel_kind === "slack" && c.channel_target && c.channel_target !== ""))
      fail("a job's channel target should be there, masked");
    ok("GET /v1/cron masks a channel's webhook URL");

    await page.goto(A.base + "/#cron");
    await until(async () => (await page.locator("#cron-list .cr-job").count()) === CRONS.length, "the job rows");
    await shot("cron-desktop-dark.png");

    /* ---- the rows match the route ---- */
    const rows = await page.$$eval("#cron-list .cr-job", rs => rs.map(r => ({
      id: r.querySelector(".cr-id").textContent,
      on: r.classList.contains("on"),
      state: r.querySelector(".cr-state").textContent,
      spec: r.querySelector(".cr-spec").textContent,
      reading: (r.querySelector(".cr-human") || {}).textContent || "",
      skill: r.querySelector(".cr-skill").textContent,
      args: (r.querySelector(".cr-args") || {}).textContent || "",
      last: r.querySelector(".cr-last").textContent,
      lastAt: (r.querySelector("time.cr-last") || {}).dateTime || "" })));
    route.forEach((c, i) => {
      const r = rows[i];
      if (r.id !== c.id) fail(`row ${i} id ${JSON.stringify(r.id)}, route ${JSON.stringify(c.id)}`);
      if (r.on !== c.enabled || r.state !== (c.enabled ? "Enabled" : "Disabled")) fail(`row ${c.id} state: ${r.state}`);
      if (r.spec !== c.spec) fail(`row ${c.id} spec ${JSON.stringify(r.spec)}`);
      if (r.skill !== c.skill) fail(`row ${c.id} skill ${r.skill}`);
      if (r.args !== (c.args || "")) fail(`row ${c.id} args ${JSON.stringify(r.args)}`);
      if (c.last_fired) {
        if (r.lastAt !== new Date(c.last_fired * 1000).toISOString()) fail(`row ${c.id} last run at ${r.lastAt}`);
        if (r.last !== "2 h ago") fail(`row ${c.id} last run reads ${r.last}`);
      } else if (r.last !== "Not yet") fail(`row ${c.id} last run reads ${r.last}`);
    });
    const n = (await page.textContent("#cron-n")).trim();
    if (n !== "4 · 1 enabled") fail("the count reads " + n);
    ok("rows match the route: ids, enabled or disabled, spec, skill, arguments, last run");

    const runs = await rowOf(0).locator(".cr-runs").textContent();
    if (!/posts the result to Slack/.test(runs) || /hooks\.slack/.test(await page.textContent("#cron-list")))
      fail("the channel line: " + runs);
    ok("the channel is named, its webhook URL is not shown");

    /* ---- the plain reading ---- */
    const want = { "morning-brief": "Weekdays at 09:00", "inbox-sweep": "Every 5 minutes",
                   [XSS_ID]: "Every Friday at 17:00", "quarter-close": "" };
    for (const r of rows) if (r.reading !== want[r.id]) fail(`reading of ${r.spec}: ${JSON.stringify(r.reading)}`);
    const more = await page.evaluate(() => ["* * * * *", "0 * * * *", "30 */6 * * *", "*/7 * * * *", "0 9 * * 0,6",
      "0 9 1 * *", "0 9 * 1 *", "0 9 * * 1,3,5", "bad"].map(cronReading));
    const wantMore = ["Every minute", "Every hour, on the hour", "Every 6 hours at :30", "", "Weekends at 09:00",
      "Monthly on day 1 at 09:00", "", "Mon, Wed and Fri at 09:00", ""];
    if (JSON.stringify(more) !== JSON.stringify(wantMore)) fail("cronReading: " + JSON.stringify(more));
    ok("schedule readings: simple expressions read, complex ones left as the expression");

    /* ---- HTML is text ---- */
    const html = await page.evaluate(() => [window.__cronXss, document.querySelectorAll("#cron-list img, #cron-list b, #cron-list script").length]);
    if (html[0] !== undefined || html[1] !== 0) fail("HTML in a job rendered as markup: " + html);
    ok("HTML in a job id and its arguments is drawn as text");

    /* ---- Show all ---- */
    const btn = rowOf(0).locator(".cr-more");
    if (!(await btn.isVisible())) fail("no Show all on long arguments");
    if (await rowOf(1).locator(".cr-more").isVisible()) fail("Show all on a one-line argument");
    const clipped = await rowOf(0).locator(".cr-args").evaluate(a => a.scrollHeight > a.clientHeight + 1);
    await btn.click();
    const open = await rowOf(0).locator(".cr-args").evaluate(a => a.scrollHeight <= a.clientHeight + 1);
    if (!clipped || !open || (await btn.textContent()) !== "Show less" || (await btn.getAttribute("aria-expanded")) !== "true")
      fail("Show all did not open the arguments");
    ok("long arguments are clipped to two lines and Show all opens them");

    /* ---- Settings › Scheduling ---- */
    await page.click(".cr-lead [data-cron-settings]");
    await until(async () => (await page.getAttribute('#set-nav button[data-sec="scheduling"]', "aria-current")) === "true",
                "Settings on Scheduling");
    ok("the Settings link opens Settings on Scheduling");

    /* ---- phone width, light ---- */
    await page.goto(A.base + "/#cron");
    await page.setViewportSize({ width: 390, height: 844 });
    await page.click("#theme-btn");
    await until(async () => (await page.locator("#cron-list .cr-job").count()) === CRONS.length, "the rows again");
    const sw = await page.evaluate(() => [document.documentElement.scrollWidth, document.querySelector("#cron-pane").scrollWidth,
                                          document.querySelector("#cron-pane").clientWidth]);
    if (sw[0] > 390 || sw[1] > sw[2]) fail("sideways scroll at phone width: " + sw);
    await shot("cron-phone-light.png");
    ok("phone width: no sideways scroll");

    /* ---- no jobs ---- */
    await page.goto(B.base + "/#cron");
    await until(async () => await page.isVisible("#cron-list .cr-empty"), "the empty state");
    const empty = (await page.textContent("#cron-list")).replace(/\s+/g, " ");
    if (!/No scheduled jobs/.test(empty) || (await page.locator("#cron-list .cr-job").count()) !== 0) fail("empty state: " + empty);
    if (!(await page.isHidden("#cron-foot"))) fail("the footnote shows with no jobs");
    await shot("cron-empty-phone-light.png");
    ok("with no jobs, the empty state shows");
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
  console.log("webui_cron_e2e: all checks passed");
})();
