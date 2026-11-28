#!/usr/bin/env node
/* The web UI's Vault tab (the pasclaw.dev Code Vault), against the real
   gateway.

   GET /v1/vault?q= and GET /v1/vault/<slug> proxy pasclaw.dev, so the
   browser's calls to those two routes are answered from fixtures here (the
   test never reaches the internet); the page, its config read and the rest
   come from the gateway. Gateway A has the vault tools on, a gateway token
   and a provider key; gateway B has the tools off. Through headless
   Chromium:

     - GET /v1/vault without ?q= is refused by the gateway itself;
     - before a search, the empty state shows with its suggestions, and the
       pill says whether the agent's vault tools are on;
     - the rows match the route: names, category, version, summary and
       repository, in order, with the count;
     - HTML in an entry's name and summary is drawn as text, and a
       non-http(s) repository URL is never a link;
     - opening an entry shows its facts, install snippet (Copy works) and
       description; a flagged entry says so; a blocked one says so and has
       no Build with this; Build with this opens Chat with the library
       attached and a prompt;
     - a failed search and a missing entry show their errors as text, and
       Try again searches again;
     - the Settings link opens Settings on Tools;
     - no secret anywhere: the gateway token and the provider key are never
       in the page's HTML, in any input's value or on the console, at any
       step (this tab has nothing to reveal);
     - phone width: no sideways scroll, and an open entry replaces the list
       until Results brings it back;
     - with the tools off the pill says so; no matches shows the empty state.

   Needs node with Playwright and a Chromium; skips without them.
   VAULT_SHOTS=<dir> also writes screenshots there (fixture data only).
   usage: node webui_vault_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_vault_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const shots = process.env.VAULT_SHOTS || "";
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

/* Secrets the gateway and the page hold; none may ever be drawn. */
const GW_TOKEN = "gwtok-VLT-7c1e9b44d2";
const API_KEY = "sk-VLT-SENTINEL-5a0f3e81";
const SECRETS = [GW_TOKEN, API_KEY];

const XSS_NAME = '<img src=x onerror="window.__vltXss=1">';
const XSS_SUM = '<b>bold</b> & <script>window.__vltXss=2</script>';
const RESULTS = [
  { slug: "fixture-json", displayName: "Fixture JSON", summary: "A JSON reader and writer for Delphi and Free Pascal (fixture).",
    category: "library", tags: "json, parser", repoUrl: "https://github.com/example/fixture-json.git", version: "1.2.4" },
  { slug: "fixture-xss", displayName: XSS_NAME, summary: XSS_SUM, category: "sample", tags: "", repoUrl: "javascript:alert(1)", version: "" },
  { slug: "fixture-flagged", displayName: "Fixture Flagged", summary: "Flagged for review (fixture).", category: "component",
    tags: "", repoUrl: "https://github.com/example/flagged", version: "0.3.0" },
  { slug: "fixture-blocked", displayName: "Fixture Blocked", summary: "Blocked by moderation (fixture).", category: "library",
    tags: "", repoUrl: "https://github.com/example/blocked", version: "" },
];
const detailOf = r => ({
  slug: r.slug, displayName: r.displayName, summary: r.summary, category: r.category, tags: r.tags, repoUrl: r.repoUrl,
  homepageUrl: r.slug === "fixture-json" ? "https://example.com/fixture-json" : "",
  descriptionMarkdown: r.slug === "fixture-xss" ? "## About\n" + XSS_SUM : "## Usage\nParse with `TFixtureJson.Parse`.\n\n- fast\n- small",
  license: r.slug === "fixture-json" ? "MIT" : "", delphiVersions: r.slug === "fixture-json" ? "XE2, 11, 12" : "",
  packageManager: r.slug === "fixture-json" ? "boss" : "",
  installSnippet: r.slug === "fixture-json" ? "boss install example/fixture-json" : "",
  latestVersion: r.version, viewCount: r.slug === "fixture-json" ? 1234 : 0,
  blocked: r.slug === "fixture-blocked", suspicious: r.slug === "fixture-flagged" });

async function startGateway(extra, tag, token) {
  const port = await freePort();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-vault-" + tag + "-"));
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify(Object.assign({
    gateway: Object.assign({ port, bind_addr: "127.0.0.1" }, token ? { token } : {}),
    providers: [{ name: "fake", kind: "openai", api_base: "http://127.0.0.1:9/v1", api_key: API_KEY, model: "m" }],
    default_provider: "fake", default_model: "m" }, extra)));
  const proc = spawn(binary, ["gateway", "--port", String(port), "--addr", "127.0.0.1", "--no-mcp"],
                     { cwd: home, env: Object.assign({}, process.env, { PASCLAW_HOME: home }), stdio: ["ignore", "pipe", "pipe"] });
  proc.stdout.on("data", d => gwLog += d); proc.stderr.on("data", d => gwLog += d);
  const base = `http://127.0.0.1:${port}`;
  await until(async () => (await fetch(base + "/v1/health")).ok, "the " + tag + " gateway");
  return { base, home, proc };
}

/* Answer the browser's /v1/vault calls from the fixtures. */
async function fakeVault(page, seen) {
  await page.route(/\/v1\/vault(\?.*)?$/, r => {
    const q = new URL(r.request().url()).searchParams.get("q") || "";
    seen.push(q);
    if (q === "boom") return r.fulfill({ status: 502, contentType: "application/json", body: '{"error":"http 503: <i>upstream</i> down"}' });
    const results = q === "zzz" ? [] : RESULTS;
    return r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ results }) });
  });
  await page.route(/\/v1\/vault\/[^?]+$/, r => {
    const slug = decodeURIComponent(new URL(r.request().url()).pathname.split("/").pop());
    const row = RESULTS.find(x => x.slug === slug);
    if (!row) return r.fulfill({ status: 404, contentType: "application/json", body: '{"error":"not found"}' });
    return r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(detailOf(row)) });
  });
}

(async () => {
  const A = await startGateway({ vault_tools_enabled: true }, "on", GW_TOKEN);
  const B = await startGateway({ vault_tools_enabled: false }, "off");

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: "dark",
                                         permissions: ["clipboard-read", "clipboard-write"] });
  await ctx.addInitScript(t => { try { localStorage.setItem("pasclaw.gw_token.v1", t); } catch {} }, GW_TOKEN);
  const page = await ctx.newPage();
  const consoleText = [];
  page.on("console", m => consoleText.push(m.text()));
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  page.on("dialog", d => d.dismiss());
  const seen = [];
  await fakeVault(page, seen);
  const shot = async (name, full = true) => { if (shots) await page.screenshot({ path: path.join(shots, name), fullPage: full }); };
  /* No secret in the HTML, in any field's value, or on the console. */
  const noSecrets = async step => {
    const [html, values] = await page.evaluate(() => [document.documentElement.outerHTML,
      [...document.querySelectorAll("input, textarea, select")].map(e => e.value).join("\n")]);
    for (const s of SECRETS) {
      if (html.includes(s)) fail(`${step}: a secret is in the page's HTML`);
      if (values.includes(s)) fail(`${step}: a secret is in an input's value`);
      if (consoleText.some(t => t.includes(s))) fail(`${step}: a secret was logged to the console`);
    }
  };
  const rowsOnPage = () => page.$$eval("#vlt-list .vlt-row", rs => rs.map(r => ({
    slug: r.dataset.slug,
    name: r.querySelector(".vlt-name").textContent,
    tags: [...r.querySelectorAll(".vlt-tag")].map(t => t.textContent),
    sum: (r.querySelector(".vlt-sum") || {}).textContent || "",
    repo: (r.querySelector(".vlt-repo") || {}).textContent || "" })));
  const search = async q => { await page.fill("#vlt-q", q); await page.press("#vlt-q", "Enter"); };
  const openRow = async i => {
    await page.locator("#vlt-list .vlt-row").nth(i).click();
    await until(async () => (await page.locator("#vlt-detail .vlt-d-name").count()) === 1, "entry " + i);
  };

  try {
    /* ---- the real route ---- */
    const r400 = await fetch(A.base + "/v1/vault", { headers: { Authorization: "Bearer " + GW_TOKEN } });
    if (r400.status !== 400 || !/missing query/.test(await r400.text())) fail("GET /v1/vault without q: " + r400.status);
    ok("GET /v1/vault without ?q= is refused by the gateway");

    /* ---- before a search ---- */
    await page.goto(A.base + "/#vault"); await page.reload();
    await until(async () => await page.isVisible("#vlt-list .vlt-empty"), "the start state");
    await until(async () => (await page.textContent("#vlt-agent")) === "Agent tools on", "the agent pill");
    const start = (await page.textContent("#vlt-list")).replace(/\s+/g, " ");
    if (!/Search the Code Vault/.test(start) || (await page.locator("#vlt-list .vlt-chips button").count()) < 3)
      fail("start state: " + start);
    if (!(await page.isHidden("#vlt-detail"))) fail("an entry pane shows before any search");
    await noSecrets("start");
    await shot("vault-start-desktop-dark.png");
    ok("before a search: the empty state with suggestions, and the pill says the agent's tools are on");

    /* ---- rows match the route ---- */
    await search("json");
    await until(async () => (await page.locator("#vlt-list .vlt-row").count()) === RESULTS.length, "the rows");
    if (seen[seen.length - 1] !== "json") fail("the query sent: " + seen[seen.length - 1]);
    const rows = await rowsOnPage();
    RESULTS.forEach((r, i) => {
      const w = rows[i];
      if (w.slug !== r.slug || w.name !== r.displayName) fail(`row ${i}: ${JSON.stringify(w)}`);
      const tags = [r.category, r.version ? "v" + r.version : ""].filter(Boolean);
      if (JSON.stringify(w.tags) !== JSON.stringify(tags)) fail(`row ${r.slug} tags ${JSON.stringify(w.tags)}`);
      if (w.sum !== r.summary) fail(`row ${r.slug} summary ${JSON.stringify(w.sum)}`);
    });
    if (rows[0].repo !== "github.com/example/fixture-json") fail("row 0 repository: " + rows[0].repo);
    const n = await page.textContent("#vlt-n");
    if (n !== "4 entries for “json”") fail("the count reads " + n);
    ok("rows match the route: name, category, version, summary, repository, in order, with the count");

    /* ---- HTML is text ---- */
    const xss = await page.evaluate(() => [window.__vltXss,
      document.querySelectorAll("#tab-vault img, #tab-vault script, #tab-vault b").length]);
    if (xss[0] !== undefined || xss[1] !== 0) fail("HTML in an entry rendered as markup: " + xss);
    ok("HTML in an entry's name and summary is drawn as text");

    /* ---- an entry ---- */
    await openRow(0);
    const d = await page.evaluate(() => {
      const v = document.querySelector("#vlt-detail");
      const facts = {};
      const dts = v.querySelectorAll(".vlt-facts dt");
      dts.forEach(dt => facts[dt.textContent] = dt.nextElementSibling.textContent);
      return { name: v.querySelector(".vlt-d-name").textContent, facts,
               tags: [...v.querySelectorAll(".vlt-d-head .vlt-tag")].map(t => t.textContent),
               code: (v.querySelector(".vlt-install code") || {}).textContent || "",
               about: (v.querySelector(".vlt-about") || {}).textContent || "",
               repo: (v.querySelector("a.vlt-repo-link") || {}).href || "",
               home: (v.querySelector("a.vlt-home-link") || {}).href || "",
               build: !!v.querySelector(".build-with"), note: !!v.querySelector(".vlt-note") };
    });
    const wantFacts = { Repository: "https://github.com/example/fixture-json.git", Homepage: "https://example.com/fixture-json",
      License: "MIT", "Delphi versions": "XE2, 11, 12", "Package manager": "boss", Tags: "json, parser",
      Views: (1234).toLocaleString("en-US"), Slug: "fixture-json" };
    if (d.name !== "Fixture JSON" || JSON.stringify(d.tags) !== '["library","v1.2.4"]') fail("entry head: " + JSON.stringify(d));
    for (const [k, v] of Object.entries(wantFacts)) if (d.facts[k] !== v) fail(`fact ${k}: ${JSON.stringify(d.facts[k])}`);
    if (d.code !== "boss install example/fixture-json" || !/TFixtureJson\.Parse/.test(d.about)) fail("install/about: " + JSON.stringify(d));
    if (d.repo !== "https://github.com/example/fixture-json.git" || d.home !== "https://example.com/fixture-json") fail("links: " + JSON.stringify(d));
    if (!d.build || d.note) fail("a clean entry: Build with this " + d.build + ", note " + d.note);
    if ((await page.getAttribute("#vlt-list .vlt-row >> nth=0", "aria-current")) !== "true") fail("the open row is not marked");
    await page.click("#vlt-detail .vlt-install .copy-btn");
    const clip = await page.evaluate(() => navigator.clipboard.readText());
    if (clip !== "boss install example/fixture-json") fail("Copy put " + JSON.stringify(clip));
    await noSecrets("entry");
    await shot("vault-entries-desktop-dark.png");
    ok("an entry: facts, links, install snippet with a working Copy, description, Build with this");

    await openRow(1);
    const x = await page.evaluate(() => [window.__vltXss, document.querySelectorAll("#tab-vault img, #tab-vault script, #tab-vault b").length,
      document.querySelectorAll('#vlt-detail a[href^="javascript"], #vlt-detail a.vlt-repo-link').length,
      document.querySelector("#vlt-detail .vlt-d-name").textContent]);
    if (x[0] !== undefined || x[1] !== 0 || x[2] !== 0 || x[3] !== XSS_NAME) fail("an entry with HTML in it: " + JSON.stringify(x));
    ok("an entry with HTML: drawn as text; a javascript: repository is not a link");

    await openRow(2);
    if ((await page.textContent("#vlt-detail .vlt-d-head .vlt-tag.warn")) !== "Flagged"
        || !/flagged this entry/.test(await page.textContent("#vlt-detail .vlt-note"))
        || (await page.locator("#vlt-detail .build-with").count()) !== 1) fail("the flagged entry");
    await openRow(3);
    if ((await page.textContent("#vlt-detail .vlt-d-head .vlt-tag.bad")) !== "Blocked"
        || !/blocked this entry/.test(await page.textContent("#vlt-detail .vlt-note.bad"))
        || (await page.locator("#vlt-detail .build-with").count()) !== 0) fail("the blocked entry");
    await shot("vault-blocked-desktop-dark.png");
    ok("a flagged entry warns; a blocked one says so and has no Build with this");

    /* ---- Build with this ---- */
    await openRow(0);
    await page.click("#vlt-detail .build-with");
    await until(async () => await page.isVisible("#tab-chat.active"), "Chat");
    const prompt = await page.inputValue("#m");
    const chips = await page.evaluate(() => (document.querySelector("#attach-chips") || document.body).textContent);
    if (!/Fixture JSON/.test(prompt) || !/fixture-json\.md/.test(chips)) fail("Build with this: " + prompt);
    await noSecrets("build with this");
    ok("Build with this opens Chat with the library attached and a prompt");

    /* ---- errors ---- */
    await page.goto(A.base + "/#vault"); await page.reload();
    await until(async () => await page.isVisible("#vlt-list .vlt-empty"), "the start state again");
    await search("boom");
    await until(async () => await page.isVisible("#vlt-list .vlt-msg.err"), "the search error");
    const err = await page.textContent("#vlt-list .vlt-msg.err .vlt-err-text");
    if (err !== "http 503: <i>upstream</i> down" || (await page.locator("#vlt-list i").count()) !== 0) fail("search error: " + err);
    const before = seen.length;
    await page.click("#vlt-list .vlt-retry");
    await until(async () => seen.length === before + 1 && await page.isVisible("#vlt-list .vlt-msg.err"), "Try again");
    await shot("vault-error-desktop-dark.png", false);
    await page.evaluate(() => vltOpen("gone"));
    await until(async () => /no longer in the vault/.test(await page.textContent("#vlt-detail")), "the missing entry");
    if ((await page.locator("#vlt-detail .vlt-retry").count()) !== 0) fail("Try again on a missing entry");
    ok("a failed search and a missing entry show their errors as text; Try again searches again");

    /* ---- Settings › Tools ---- */
    await page.click("#tab-vault [data-vlt-settings]");
    await until(async () => (await page.getAttribute('#set-nav button[data-sec="tools"]', "aria-current")) === "true",
                "Settings on Tools");
    await noSecrets("settings");
    ok("the Settings link opens Settings on Tools");

    /* ---- phone width, light ---- */
    await page.goto(A.base + "/#vault"); await page.reload();
    await page.setViewportSize({ width: 390, height: 844 });
    await page.click("#theme-btn");
    await until(async () => await page.isVisible("#vlt-list .vlt-empty"), "the start state on a phone");
    await shot("vault-start-phone-light.png");
    await search("json");
    await until(async () => (await page.locator("#vlt-list .vlt-row").count()) === RESULTS.length, "the rows on a phone");
    const sideways = () => page.evaluate(() => [document.documentElement.scrollWidth, document.querySelector("#vault-pane").scrollWidth,
                                                document.querySelector("#vault-pane").clientWidth]);
    let sw = await sideways();
    if (sw[0] > 390 || sw[1] > sw[2]) fail("sideways scroll at phone width (list): " + sw);
    await shot("vault-entries-phone-light.png");
    await openRow(0);
    if (await page.isVisible("#vlt-list")) fail("the list still shows beside an open entry on a phone");
    sw = await sideways();
    if (sw[0] > 390 || sw[1] > sw[2]) fail("sideways scroll at phone width (entry): " + sw);
    await shot("vault-entry-phone-light.png");
    await page.click("#vlt-detail .vlt-back");
    await until(async () => await page.isVisible("#vlt-list .vlt-row"), "Results back");
    await noSecrets("phone");
    ok("phone width: no sideways scroll; an open entry replaces the list until Results");

    /* ---- tools off, no matches ---- */
    const p2 = await ctx.newPage();
    await fakeVault(p2, seen);
    p2.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
    await p2.setViewportSize({ width: 1280, height: 900 });
    await p2.emulateMedia({ colorScheme: "light" });
    await p2.goto(B.base + "/#vault");
    await until(async () => (await p2.textContent("#vlt-agent")) === "Agent tools off", "the off pill");
    if (await p2.evaluate(() => document.querySelector("#vlt-agent").classList.contains("on"))) fail("the off pill looks on");
    await p2.fill("#vlt-q", "zzz"); await p2.press("#vlt-q", "Enter");
    await until(async () => await p2.isVisible("#vlt-list .vlt-empty"), "no matches");
    const none = (await p2.textContent("#vlt-list")).replace(/\s+/g, " ");
    if (!/No entries match “zzz”/.test(none) || (await p2.locator("#vlt-list .vlt-row").count()) !== 0
        || (await p2.textContent("#vlt-n")) !== "0 entries for “zzz”") fail("no matches: " + none);
    if (shots) await p2.screenshot({ path: path.join(shots, "vault-empty-desktop-light.png"), fullPage: true });
    if (shots) {
      await p2.fill("#vlt-q", "json"); await p2.press("#vlt-q", "Enter");
      await until(async () => (await p2.locator("#vlt-list .vlt-row").count()) === RESULTS.length, "rows in light");
      await p2.locator("#vlt-list .vlt-row").nth(0).click();
      await until(async () => (await p2.locator("#vlt-detail .vlt-d-name").count()) === 1, "entry in light");
      await p2.screenshot({ path: path.join(shots, "vault-entries-desktop-light.png"), fullPage: true });
      await page.emulateMedia({ colorScheme: "dark" });
      await page.click("#theme-btn");
      await page.goto(A.base + "/#vault"); await page.reload();
      await page.fill("#vlt-q", "zzz"); await page.press("#vlt-q", "Enter");
      await until(async () => await page.isVisible("#vlt-list .vlt-empty"), "no matches on a phone");
      await page.screenshot({ path: path.join(shots, "vault-empty-phone-dark.png"), fullPage: true });
    }
    ok("with the tools off the pill says so; no matches shows the empty state");
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
  console.log("webui_vault_e2e: all checks passed");
})();
