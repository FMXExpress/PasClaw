#!/usr/bin/env node
/* The web UI's Settings tab, against the real gateway.

   A gateway starts from a seeded config.json with two providers (each with a
   key), a channel and an MCP server (each carrying a secret). The page's
   GET /v1/config?source=file is passed through Playwright and four keys the
   page has no description for are added to it -- standing in for keys a
   newer PasClaw would add. Through headless Chromium:

     - the section list shows one section at a time, and the search box
       finds settings by label, by config key and by description, with a
       count per section and a line when nothing matches;
     - a switch, a select and a list editor change the draft; the bar counts
       the unsaved changes, the sections changed carry a dot, and Discard puts
       every value back without sending anything;
     - a port out of range and a bad URL are refused inline, and Save sends
       nothing while they stand;
     - renaming a provider whose key is left as saved is refused, because the
       server matches a kept key by name;
     - the PUT body carries the switch, the select and the list, keeps the
       untouched key as the mask, sends the replaced one, keeps the unknown
       keys exactly, and adds no key it did not change; config.json on disk
       then holds the untouched secrets (provider key, channel target, MCP
       env) and the new one, and no secret ever appears in the page;
     - a reload shows the saved file, not the running copy;
     - Advanced: edit as JSON refuses invalid JSON (and a top level that is
       not an object) and will not save it or go back to the form with it;
       valid JSON goes back into the form;
     - leaving the tab with unsaved changes asks first;
     - light theme: the panels and the switch take the light tokens;
     - phone width: no sideways scroll, the section list is a select.

   Needs node with Playwright and a Chromium; skips without them.
   SETTINGS_SHOTS=<dir> also writes dark, light and phone screenshots there.
   usage: node webui_settings_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_settings_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const shots = process.env.SETTINGS_SHOTS || "";

let failures = 0, gwLog = "";
const fail = msg => { console.log("FAIL: " + msg); failures++; throw new Error(msg); };
const ok = msg => console.log("  ok: " + msg);
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, what, ms = 10000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch {} await sleep(50); }
  fail("timed out waiting for " + what);
}
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const MASK = "•••";

function freePort() {
  return new Promise(r => { const s = http.createServer().listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => r(p)); }); });
}

/* Secrets the page must never show; each is checked against the DOM. */
const SECRETS = ["sk-keep-me-123", "sk-spare-old-456", "https://hooks.example/ops-secret-789", "GITHUB_TOKEN=keep-0ab"];

(async () => {
  const gport = await freePort();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-settings-e2e-"));
  const cfgPath = path.join(home, "config.json");
  fs.writeFileSync(cfgPath, JSON.stringify({
    providers: [
      { name: "fake", kind: "openai", api_base: "http://127.0.0.1:9/v1", api_key: SECRETS[0], model: "m" },
      { name: "spare", kind: "openai", api_base: "http://127.0.0.1:9/v1", api_key: SECRETS[1], model: "m2" }],
    default_provider: "fake", default_model: "m",
    gateway: { port: gport, bind_addr: "127.0.0.1", log_level: "info" },
    sandbox: { allow_read_paths: ["^/usr/share/.*"] },
    channels: [{ name: "ops", kind: "discord", target: SECRETS[2] }],
    mcp_servers: [{ name: "gh", cmd: "npx", args: "-y server-gh", env: SECRETS[3], enabled: true }] }));
  const gw = spawn(binary, ["gateway", "--port", String(gport), "--addr", "127.0.0.1", "--no-mcp"],
                   { cwd: home, env: Object.assign({}, process.env, { PASCLAW_HOME: home }), stdio: ["ignore", "pipe", "pipe"] });
  gw.stdout.on("data", d => gwLog += d); gw.stderr.on("data", d => gwLog += d);
  const base = `http://127.0.0.1:${gport}`;
  await until(async () => (await fetch(base + "/v1/health")).ok, "the gateway");

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: "dark" });
  const page = await ctx.newPage();
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  let dialogs = [], dialogAnswer = "dismiss";
  page.on("dialog", d => { dialogs.push(d.message()); dialogAnswer === "accept" ? d.accept() : d.dismiss(); });
  const puts = [];
  page.on("request", r => { if (r.method() === "PUT" && /\/v1\/config$/.test(r.url())) puts.push(JSON.parse(r.postData() || "null")); });
  /* Keys this page has no table entry for, added to what the server sends. */
  const UNKNOWN = { future_flag: true, experimental: { mode: "fast", tags: ["a", "b"] } };
  await page.route(/\/v1\/config\?source=file$/, async route => {
    const resp = await route.fetch();
    const j = await resp.json();
    Object.assign(j, JSON.parse(JSON.stringify(UNKNOWN)));
    j.gateway.future_knob = 7;
    j.providers[0].region = "eu";
    await route.fulfill({ response: resp, json: j });
  });
  const shot = async name => { if (shots) await page.screenshot({ path: path.join(shots, name) }); };
  const row = p => page.locator(`#config-form .set-row[data-path="${p}"]`);
  const status = () => page.textContent("#config-status");
  const visible = async sel => page.evaluate(s => { const e = document.querySelector(s); return !!e && !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length); }, sel);
  const secShown = async id => page.evaluate(id => { const s = document.querySelector(`.set-sec[data-sec="${id}"]`); return !!s && !s.hidden; }, id);
  const go = async id => { await page.click(`#set-nav button[data-sec="${id}"]`); await until(() => secShown(id), "section " + id); };

  try {
    await page.goto(base + "/#settings");
    await page.waitForSelector('#config-form .set-row[data-path="default_provider"]');

    /* ---- sections ---- */
    const secs = await page.$$eval("#set-nav button", bs => bs.map(b => b.dataset.sec));
    for (const id of ["models", "agent", "tools", "memory", "mcp", "gateway", "channels", "scheduling", "diagnostics", "backup", "advanced", "other"])
      if (!secs.includes(id)) fail("no section " + id + " in " + secs);
    if (!(await secShown("models")) || await secShown("gateway")) fail("the first visit should show Models & providers alone");
    await go("gateway");
    if (await secShown("models")) fail("Models still shown after picking Gateway");
    if ((await row("gateway.port").locator(".set-label").textContent()) !== "Port") fail("the port row's label");
    if ((await row("gateway.port").locator(".set-key").textContent()) !== "gateway.port") fail("the port row's key");
    if (!(await row("gateway.port").locator(".set-desc").count()) && !(await row("gateway.log_level").locator(".set-desc").textContent())) fail("no description");
    /* Labels are tied to their controls: getByLabel finds them. */
    if (await page.getByLabel("Port", { exact: true }).inputValue() !== String(gport)) fail("getByLabel('Port') did not find the port field");
    if (await page.getByLabel("Log level", { exact: true }).inputValue() !== "info") fail("getByLabel('Log level')");
    ok("sections: the list shows one section at a time, each row has a label tied to its control, a description and the key");

    /* ---- unknown keys ---- */
    await go("other");
    for (const p of ["future_flag", "gateway.future_knob", "experimental.mode", "experimental.tags"])
      if (!(await row(p).count())) fail("unknown key " + p + " not listed under Other");
    ok("keys without a description are listed under Other");

    /* ---- search ---- */
    await page.fill("#set-q", "log level");
    await until(async () => await visible('.set-row[data-path="gateway.log_level"]'), "search by label");
    if (await visible('.set-row[data-path="gateway.port"]')) fail("search left a non-matching row shown");
    await page.fill("#set-q", "allow_read_paths");
    await until(async () => await visible('.set-row[data-path="sandbox.allow_read_paths"]'), "search by key");
    if ((await page.textContent('#set-nav button[data-sec="tools"] .n')) !== "1") fail("the section count for a key search");
    await page.fill("#set-q", "reverse proxy");
    await until(async () => await visible('.set-row[data-path="gateway.allowed_hosts"]'), "search by description");
    await page.fill("#set-q", "zzzqqq");
    await until(async () => /No settings match/.test(await page.textContent("#set-nomatch")) && await visible("#set-nomatch"), "the no-match line");
    await page.press("#set-q", "Escape");
    if ((await page.inputValue("#set-q")) !== "" || !(await secShown("other"))) fail("Escape should clear the search and return to the section");
    ok("search: by label, key and description, with section counts and a no-match line; Escape clears");

    /* ---- a switch, a select, a list ---- */
    await go("tools");
    const sw = row("sandbox.restrict_to_workspace").locator('input[role="switch"]');
    if (await sw.isChecked()) fail("restrict_to_workspace starts on");
    await row("sandbox.restrict_to_workspace").locator("label.set-label").click();     // the label toggles it
    if (!(await sw.isChecked())) fail("clicking the label did not toggle the switch");
    await row("sandbox.allow_read_paths").locator(".set-add").click();
    const listInputs = row("sandbox.allow_read_paths").locator(".set-list-row input");
    if ((await listInputs.count()) !== 2) fail("Add did not add a list row");
    await listInputs.nth(1).fill("^/opt/data/.*");
    await go("gateway");
    await row("gateway.log_level").locator("select").selectOption("debug");
    await until(async () => /^3 unsaved changes/.test(await status()), "3 unsaved changes, got: " + await status());
    const dots = await page.$$eval("#set-nav button .dot", ds => ds.map(d => d.parentElement.dataset.sec).sort());
    if (!eq(dots, ["gateway", "tools"])) fail("changed sections should carry a dot: " + dots);
    if (!(await row("gateway.log_level").evaluate(r => r.classList.contains("dirty")))) fail("a changed row is not marked");
    ok("a switch (toggled from its label), a select and a list editor: 3 unsaved changes, dots on the two sections");

    /* ---- Discard ---- */
    await page.click("#config-discard");
    await until(async () => (await row("gateway.log_level").locator("select").inputValue()) === "info", "Discard to restore the select");
    await go("tools");
    if (await row("sandbox.restrict_to_workspace").locator('input[role="switch"]').isChecked()) fail("Discard left the switch on");
    if ((await row("sandbox.allow_read_paths").locator(".set-list-row input").count()) !== 1) fail("Discard left the list row");
    if (/unsaved/.test(await status()) || puts.length) fail("Discard should leave no changes and send nothing: " + await status());
    ok("Discard restores every value and sends nothing");

    /* ---- the same three again, keyboard for the switch ---- */
    await row("sandbox.restrict_to_workspace").locator('input[role="switch"]').focus();
    await page.keyboard.press("Space");
    if (!(await row("sandbox.restrict_to_workspace").locator('input[role="switch"]').isChecked())) fail("Space did not toggle the focused switch");
    await row("sandbox.allow_read_paths").locator(".set-add").click();
    await row("sandbox.allow_read_paths").locator(".set-list-row input").nth(1).fill("^/opt/data/.*");
    await row("sandbox.custom_shell_deny").locator(".set-add").click();
    await row("sandbox.custom_shell_deny").locator(".set-list-row input").nth(0).fill("scp ");
    await go("gateway");
    await row("gateway.log_level").locator("select").selectOption("debug");

    /* ---- validation ---- */
    const port = row("gateway.port").locator("input");
    await port.fill("70000");
    await until(async () => /from 1 to 65535/.test(await row("gateway.port").locator(".set-err").textContent()), "the port range error");
    if (!(await row("gateway.port").evaluate(r => r.classList.contains("invalid")))) fail("the port row is not marked invalid");
    if (!/1 field to fix/.test(await status())) fail("the bar should say a field needs fixing: " + await status());
    await page.click("#config-save");
    await until(async () => /Fix 1 field/.test(await status()), "Save to refuse while a field is invalid");
    if (puts.length) fail("Save sent a PUT with an invalid port");
    await port.fill(String(gport));
    await go("models");
    const fakeCard = page.locator("#config-form .set-item").filter({ has: page.locator(".set-item-title", { hasText: /^fake$/ }) });
    await fakeCard.getByLabel("Base URL", { exact: true }).fill("not a url");
    await until(async () => /full URL/.test(await fakeCard.locator(".set-err").allTextContents().then(a => a.join(" "))), "the URL error");
    await fakeCard.getByLabel("Base URL", { exact: true }).fill("http://127.0.0.1:9/v1");
    /* Renaming a provider whose key stays as saved would lose the key. */
    await fakeCard.getByLabel("Name", { exact: true }).fill("fake-renamed");
    await until(async () => /saved api key belongs to “fake”/.test(await page.locator("#config-form .set-item").first().locator(".set-err").allTextContents().then(a => a.join(" "))), "the rename-with-kept-key error");
    await page.locator("#config-form .set-item").first().getByLabel("Name", { exact: true }).fill("fake");
    await until(async () => !/to fix/.test(await status()), "the errors to clear: " + await status());
    ok("validation: a port out of range, a bad URL and a rename that would drop a saved key are refused inline; Save sends nothing meanwhile");

    /* ---- secrets ---- */
    const spareCard = page.locator("#config-form .set-item").filter({ has: page.locator(".set-item-title", { hasText: /^spare$/ }) });
    const spareKey = spareCard.getByLabel("API key", { exact: true });
    if ((await spareKey.inputValue()) !== "" || (await spareKey.getAttribute("type")) !== "password") fail("a saved key's field should be an empty password field");
    if (!/Set/.test(await spareCard.locator(".set-secret-state").textContent())) fail("a saved key should read as Set");
    await spareKey.fill("sk-spare-new-999");
    if (!/New value/.test(await spareCard.locator(".set-secret-state").textContent())) fail("a typed key should read as a new value");
    const html = await page.content();
    for (const s of SECRETS) if (html.includes(s)) fail("the page holds a saved secret: " + s);
    ok("secrets: saved ones show as Set in an empty password field and never reach the page; typing one marks it new");

    if (shots) { await go("models"); await shot("web-ui-settings-dark.png"); }

    /* ---- a card: add a channel ---- */
    await go("channels");
    await row("channels").locator(".set-add").click();
    const newCh = row("channels").locator(".set-item.new");
    await until(async () => (await newCh.count()) === 1, "the new channel card");
    await newCh.getByLabel("Name", { exact: true }).fill("alerts");
    await newCh.getByLabel("Kind", { exact: true }).selectOption("slack");
    await newCh.getByLabel("Target", { exact: true }).fill("https://hooks.example/alerts-new");
    if ((await newCh.locator(".set-item-title").textContent()) !== "alerts") fail("the card title follows its name");
    ok("cards: Add makes a new channel card whose title follows its name");

    /* ---- Save ---- */
    const before = await status();
    if (!/^6 unsaved changes$/.test(before)) fail("expected 6 unsaved changes before Save, got: " + before);
    await page.click("#config-save");
    await until(() => puts.length === 1, "the PUT");
    await until(async () => /^Saved\./.test(await status()), "the saved status, got: " + await status());
    const body = puts[0];
    if (body.sandbox.restrict_to_workspace !== true) fail("PUT: the switch");
    if (body.gateway.log_level !== "debug") fail("PUT: the select");
    if (!eq(body.sandbox.allow_read_paths, ["^/usr/share/.*", "^/opt/data/.*"])) fail("PUT: the list " + JSON.stringify(body.sandbox.allow_read_paths));
    if (!eq(body.sandbox.custom_shell_deny, ["scp "])) fail("PUT: a list entry's trailing space was lost");
    const prov = n => body.providers.find(p => p.name === n);
    if (prov("fake").api_key !== MASK) fail("PUT: the untouched key should go back as the mask, got " + prov("fake").api_key);
    if (prov("spare").api_key !== "sk-spare-new-999") fail("PUT: the replaced key");
    if (body.channels[0].target !== MASK || body.mcp_servers[0].env !== MASK) fail("PUT: untouched channel target / MCP env should be the mask");
    if (!eq(body.channels[1], { name: "alerts", kind: "slack", target: "https://hooks.example/alerts-new" })) fail("PUT: the new channel " + JSON.stringify(body.channels[1]));
    if (body.future_flag !== true || !eq(body.experimental, UNKNOWN.experimental) || body.gateway.future_knob !== 7 || prov("fake").region !== "eu")
      fail("PUT: unknown keys not kept as they came: " + JSON.stringify([body.future_flag, body.experimental, body.gateway.future_knob, prov("fake").region]));
    for (const k of ["compaction", "prune", "web_search", "heartbeat"]) if (k in body) fail("PUT: added a key nobody changed: " + k);
    if (body.gateway.port !== gport) fail("PUT: the port");
    const disk = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
    const dprov = n => disk.providers.find(p => p.name === n);
    if (dprov("fake").api_key !== SECRETS[0]) fail("disk: the untouched key was not kept");
    if (dprov("spare").api_key !== "sk-spare-new-999") fail("disk: the replaced key");
    if (disk.channels[0].target !== SECRETS[2]) fail("disk: the channel target was not kept: " + disk.channels[0].target);
    if (!disk.channels[1] || disk.channels[1].target !== "https://hooks.example/alerts-new") fail("disk: the new channel");
    if (disk.mcp_servers[0].env !== SECRETS[3]) fail("disk: the MCP env was not kept");
    if (disk.gateway.log_level !== "debug" || disk.sandbox.restrict_to_workspace !== true) fail("disk: the edits");
    if (/unsaved/.test(await status())) fail("still unsaved after Save");
    if (!/Log level/.test(await page.textContent("#set-banners"))) fail("the restart banner should list Log level");
    ok("Save: the PUT carries the edits, the mask for untouched secrets, the new key and the unknown keys as they came; the disk keeps every secret");

    /* ---- the saved file, not the running copy ---- */
    const running = await (await fetch(base + "/v1/config")).json();
    if (running.gateway.log_level !== "info") fail("the running config should still say info until a restart");
    dialogAnswer = "accept";
    await page.reload();
    await page.waitForSelector('#config-form .set-row[data-path="gateway.log_level"]', { state: "attached" });
    await go("gateway");
    if ((await row("gateway.log_level").locator("select").inputValue()) !== "debug") fail("a reload should show the saved value, not the running one");
    dialogAnswer = "dismiss";
    ok("after a reload the form shows config.json as saved (debug), while the running gateway still says info");

    /* ---- Advanced: edit as JSON ---- */
    await page.click("#config-raw-toggle");
    await until(() => visible("#config-edit"), "the JSON editor");
    const raw = await page.inputValue("#config-edit");
    const parsed = JSON.parse(raw);
    if (parsed.future_flag !== true) fail("the JSON view lost an unknown key");
    if (SECRETS.some(s => raw.includes(s))) fail("the JSON view shows a secret");
    await page.fill("#config-edit", raw + "{");
    await until(async () => /Not valid JSON/.test(await page.textContent("#set-raw-state")), "the invalid-JSON message");
    const n = puts.length;
    await page.click("#config-save");
    await until(async () => /Fix the JSON/.test(await status()), "Save to refuse invalid JSON");
    await page.click("#config-raw-toggle");
    if (!(await visible("#config-edit"))) fail("left the JSON editor with invalid JSON");
    await page.fill("#config-edit", "[1, 2]");
    await until(async () => /JSON object/.test(await page.textContent("#set-raw-state")), "the top-level-object message");
    if (puts.length !== n) fail("invalid JSON was sent");
    parsed.gateway.log_level = "warn";
    await page.fill("#config-edit", JSON.stringify(parsed, null, 2));
    await until(async () => /Valid JSON/.test(await page.textContent("#set-raw-state")), "the valid-JSON message");
    await until(async () => /^1 unsaved change$/.test(await status()), "1 unsaved change from the JSON edit, got: " + await status());
    await page.click("#config-raw-toggle");
    await until(() => visible('.set-row[data-path="gateway.log_level"]'), "back to the form");
    if ((await row("gateway.log_level").locator("select").inputValue()) !== "warn") fail("the JSON edit did not reach the form");
    ok("Advanced: edit as JSON refuses invalid JSON and a non-object, will not save or leave with them, and a valid edit lands in the form");

    /* ---- leaving the tab with unsaved changes ---- */
    dialogs = [];
    await page.click('nav button[data-tab="chat"]');
    await until(() => dialogs.length === 1, "the leave confirmation");
    if (!/1 unsaved change/.test(dialogs[0])) fail("the confirmation should count the changes: " + dialogs[0]);
    if (!(await page.evaluate(() => document.getElementById("tab-settings").classList.contains("active"))) || !/#settings$/.test(page.url()))
      fail("dismissing the confirmation should stay on Settings");
    dialogAnswer = "accept";
    await page.click('nav button[data-tab="chat"]');
    await until(() => page.evaluate(() => document.getElementById("tab-chat").classList.contains("active")), "leaving after accepting");
    dialogAnswer = "dismiss";
    await page.click('nav button[data-tab="settings"]');
    await until(async () => /^1 unsaved change$/.test(await status()), "the draft to survive leaving the tab");
    await page.click("#config-discard");
    ok("leaving the tab with unsaved changes asks; Cancel stays, OK leaves and the draft is still there on return");

    /* ---- light theme ---- */
    const darkSwitch = await page.evaluate(() => { const i = document.querySelector('#config-form input[role="switch"]:checked'); return i && getComputedStyle(i.nextElementSibling).backgroundColor; });
    await page.click("#theme-btn");
    const lite = await page.evaluate(() => {
      const i = document.querySelector('#config-form .set-sec:not([hidden]) input[role="switch"]:checked') || document.querySelector('#config-form input[role="switch"]:checked');
      return [document.documentElement.classList.contains("lite"), getComputedStyle(document.querySelector("#config-form .set-sec:not([hidden]) .set-panel")).backgroundColor,
        i && getComputedStyle(i.nextElementSibling).backgroundColor, getComputedStyle(document.querySelector(".set-bar")).backgroundColor];
    });
    if (!lite[0]) fail("the theme button did not switch to light");
    if (lite[1] !== "rgb(255, 255, 255)" || lite[3] !== "rgb(255, 255, 255)") fail("panels and the save bar should take the light surface: " + lite);
    if (lite[2] !== "rgb(37, 99, 235)" || lite[2] === darkSwitch) fail("an on switch should take the light accent: " + darkSwitch + " / " + lite[2]);
    if (shots) { await go("models"); await shot("web-ui-settings-light.png"); }
    await page.click("#theme-btn");
    ok("light theme: panels, the save bar and the switches follow the tokens");

    /* ---- phone width ---- */
    await page.setViewportSize({ width: 390, height: 844 });
    await sleep(150);
    for (const id of ["models", "tools", "gateway", "channels", "mcp", "other"]) {
      await page.selectOption("#set-sec-select", id);
      await until(() => secShown(id), "section " + id + " from the select");
      const wide = await page.evaluate(() => {
        const m = document.getElementById("set-main");
        return [document.documentElement.scrollWidth, document.body.scrollWidth, m.scrollWidth, m.clientWidth];
      });
      if (wide[0] > 390 || wide[1] > 390 || wide[2] > wide[3]) fail("sideways scroll at phone width in " + id + ": " + wide);
    }
    if (await visible("#set-nav") || !(await visible("#set-sec-select"))) fail("at phone width the section list should be a select");
    const bar = await page.locator(".set-bar").boundingBox();
    if (!bar || bar.y + bar.height > 844) fail("the save bar is off screen at phone width");
    if (shots) { await page.selectOption("#set-sec-select", "models"); await shot("web-ui-settings-phone.png"); }
    ok("phone width: no sideways scroll in any section, the section list is a select, the save bar stays on screen");

    if (failures) throw new Error(failures + " failure(s)");
    console.log("webui_settings_e2e: OK");
  } catch (e) {
    if (!failures) console.log("FAIL: " + e.message);
    console.log("---- gateway log (tail) ----\n" + gwLog.split("\n").slice(-25).join("\n"));
    process.exitCode = 1;
  } finally {
    await browser.close();
    gw.kill();
    fs.rmSync(home, { recursive: true, force: true });
  }
})();
