#!/usr/bin/env node
/* The Settings tab's model pickers, against the real gateway.

   Two providers on a fake API: "pa" (OpenAI-style, two models) and "pb"
   (Anthropic-style, three models with display names). Through headless
   Chromium:

     - the default model's caret lists the default provider's models with
       the current one marked; a click picks one and counts as a change;
     - typing filters the list; an id the list does not have is kept as
       typed (free text and a dropdown, both);
     - keyboard: the down arrow opens and moves, Enter picks, Esc closes
       without changing the value;
     - a provider card lists that provider's models, with their names; a
       fallback row lists its own provider's, and follows a change of it;
       the advisor model lists the advisor provider's;
     - a provider card not saved yet says to save it first;
     - Refresh asks the provider again; otherwise each list is fetched once
       (the gateway and the page both keep it);
     - a picked model is what Save sends;
     - light theme: the list takes the light tokens; phone width: the open
       list stays on screen with no sideways scroll.

   Needs node with Playwright and a Chromium; skips without them.
   PICKER_SHOTS=<dir> also writes screenshots of the open lists there.
   usage: node webui_model_picker_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_model_picker_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }

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

/* ---------------------------------------------------------------- provider */
const hits = { a: 0, b: 0 };
const provider = http.createServer((req, res) => {
  const send = obj => { const out = JSON.stringify(obj); res.writeHead(200, { "Content-Type": "application/json" }); res.end(out); };
  if (req.url.startsWith("/a/v1/models")) {
    hits.a++;
    return send({ object: "list", data: [{ id: "alpha-1", object: "model", created: 1700000000 },
                                          { id: "alpha-2", object: "model", created: 1700000100 }] });
  }
  if (req.url.startsWith("/b/v1/models")) {
    hits.b++;
    return send({ data: [{ id: "beta-1", display_name: "Beta One", created_at: "2026-01-01T00:00:00Z" },
                         { id: "beta-2", display_name: "Beta Two", created_at: "2026-02-01T00:00:00Z" },
                         { id: "beta-3", display_name: "Beta Three", created_at: "2026-03-01T00:00:00Z" }] });
  }
  res.writeHead(404); res.end();
});

function freePort() {
  return new Promise(r => { const s = http.createServer().listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => r(p)); }); });
}

(async () => {
  const pport = await freePort(), gport = await freePort();
  await new Promise(r => provider.listen(pport, "127.0.0.1", r));
  const fake = `http://127.0.0.1:${pport}`;
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-model-picker-e2e-"));
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify({
    providers: [
      { name: "pa", kind: "openai", api_base: fake + "/a", api_key: "sk-a", model: "alpha-1" },
      { name: "pb", kind: "anthropic", api_base: fake + "/b", api_key: "sk-b", model: "beta-1" }],
    default_provider: "pa", default_model: "alpha-1",
    fallbacks: ["pb"], fallback_models: [""],
    advisor: { provider: "pb", model: "" },
    gateway: { port: gport, bind_addr: "127.0.0.1" } }));
  const gw = spawn(binary, ["gateway", "--port", String(gport), "--addr", "127.0.0.1", "--no-mcp", "--no-tools"],
                   { cwd: home, env: Object.assign({}, process.env, { PASCLAW_HOME: home }), stdio: ["ignore", "pipe", "pipe"] });
  gw.stdout.on("data", d => gwLog += d); gw.stderr.on("data", d => gwLog += d);
  const base = `http://127.0.0.1:${gport}`;
  await until(async () => (await fetch(base + "/v1/health")).ok, "the gateway");

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: "dark" });
  const page = await ctx.newPage();
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  page.on("dialog", d => d.dismiss());
  const puts = [];
  page.on("request", r => { if (r.method() === "PUT" && /\/v1\/config$/.test(r.url())) puts.push(JSON.parse(r.postData() || "null")); });
  const row = p => page.locator(`#config-form .set-row[data-path="${p}"]`);
  const ids = async scope => scope.locator(".set-combo-opt .id").allTextContents();
  const popOpen = async scope => scope.locator(".set-combo-pop").first().evaluate(p => !p.hidden);
  const shot = async name => { if (process.env.PICKER_SHOTS) await page.screenshot({ path: path.join(process.env.PICKER_SHOTS, name) }); };
  const foot = async scope => (await scope.locator(".set-combo-foot").first().textContent()) || "";

  try {
    await page.goto(base + "/#settings");
    await page.waitForSelector('#config-form .set-row[data-path="default_model"] .set-combo input');

    /* ---- the default model: a dropdown of the default provider's models ---- */
    const dm = row("default_model"), dmi = dm.locator("input[role=combobox]");
    await dm.locator(".set-combo-btn").click();
    await until(async () => eq(await ids(dm), ["alpha-1", "alpha-2"]), "pa's models in the default model's list");
    if ((await dm.locator('.set-combo-opt[aria-selected="true"] .id').textContent()) !== "alpha-1")
      fail("the current model is not marked in the list");
    if (!/2 models/.test(await foot(dm))) fail("the list does not say how many models: " + await foot(dm));
    await shot("picker-default-dark.png");
    await dm.locator('.set-combo-opt[data-id="alpha-2"]').click();
    if ((await dmi.inputValue()) !== "alpha-2" || await popOpen(dm)) fail("a click did not pick alpha-2 and close the list");
    await until(async () => /1 unsaved change/.test(await page.textContent("#config-status")), "the change counted");
    ok("the default model's caret lists the default provider's models; a click picks one");

    /* ---- free text: typing filters, anything typed is kept ---- */
    await dmi.fill("2");
    await until(async () => eq(await ids(dm), ["alpha-2"]), "the filtered list");
    if (!/1 of 2 models/.test(await foot(dm))) fail("the filtered count: " + await foot(dm));
    await dmi.fill("my-own-model");
    await until(async () => /used as typed/.test(await foot(dm)), "the no-match line");
    await dmi.press("Enter");
    if ((await dmi.inputValue()) !== "my-own-model" || await popOpen(dm)) fail("a typed model id was not kept");
    ok("typing filters the list; a model id the list does not have is kept as typed");

    /* ---- keyboard ---- */
    await dmi.press("ArrowDown");
    await until(async () => (await popOpen(dm)) && (await ids(dm)).length === 2, "the down arrow opening the whole list");
    await dmi.press("ArrowDown");
    await dmi.press("Enter");
    if ((await dmi.inputValue()) !== "alpha-1") fail("down, Enter did not pick the first model: " + await dmi.inputValue());
    await dmi.press("ArrowDown"); await dmi.press("ArrowDown"); await dmi.press("ArrowDown");
    await dmi.press("Escape");
    if ((await dmi.inputValue()) !== "alpha-1" || await popOpen(dm)) fail("Esc changed the value or left the list open");
    ok("keyboard: the down arrow opens and moves, Enter picks, Esc closes without changing it");

    /* ---- each field lists its own provider's models ---- */
    const pbCard = row("providers").locator(".set-item").filter({ has: page.locator(".set-item-title", { hasText: /^pb$/ }) });
    await pbCard.locator(".set-combo-btn").click();
    await until(async () => eq(await ids(pbCard), ["beta-1", "beta-2", "beta-3"]), "pb's models on its card");
    const names = await pbCard.locator(".set-combo-opt .nm").allTextContents();
    if (!names.includes("Beta One")) fail("the display names are missing: " + names);
    await pbCard.scrollIntoViewIfNeeded(); await shot("picker-card-dark.png");
    await pbCard.locator("input[role=combobox]").press("Escape");
    ok("a provider card lists that provider's models, with their names");

    const fr = row("fallbacks").locator(".set-list-row").first();
    await fr.locator(".set-combo-btn").click();
    await until(async () => eq(await ids(fr), ["beta-1", "beta-2", "beta-3"]), "pb's models on the fallback row");
    await fr.locator("input[role=combobox]").press("Escape");
    await fr.locator("select").selectOption("pa");
    await fr.locator(".set-combo-btn").click();
    await until(async () => eq(await ids(fr), ["alpha-1", "alpha-2"]), "pa's models after the row's provider changed");
    await fr.locator("input[role=combobox]").press("Escape");
    ok("a fallback row lists its own provider's models, and follows a change of provider");

    await row("advisor.model").locator(".set-combo-btn").click();
    await until(async () => eq(await ids(row("advisor.model")), ["beta-1", "beta-2", "beta-3"]), "the advisor provider's models");
    await row("advisor.model").locator("input[role=combobox]").press("Escape");
    ok("the advisor model lists the advisor provider's models");

    /* ---- a provider not saved yet ---- */
    await row("providers").locator(".set-add").click();
    const fresh = row("providers").locator(".set-item.new").last();
    await fresh.locator(".set-combo-btn").click();
    await until(async () => /Name this provider and save it/.test(await foot(fresh)), "the unnamed card's line");
    await fresh.locator("input[role=combobox]").press("Escape");
    await fresh.locator('input[id]').first().fill("newp");
    await fresh.locator(".set-combo-btn").click();
    await until(async () => /Save “newp” first/.test(await foot(fresh)), "the unsaved card's line");
    await fresh.locator("input[role=combobox]").press("Escape");
    ok("a provider card not saved yet says to save it first");

    /* ---- fetched once; Refresh asks again ---- */
    if (hits.a !== 1 || hits.b !== 1) fail("each list should be fetched once, got " + JSON.stringify(hits));
    await dm.locator(".set-combo-btn").click();
    await until(async () => (await ids(dm)).length === 2, "pa's list again");
    await dm.locator(".set-combo-foot button").click();
    await until(async () => hits.a === 2, "Refresh asking pa again");
    await until(async () => /listed just now/.test(await foot(dm)), "the refreshed list");
    await dmi.press("Escape");
    ok("each list is fetched once; Refresh asks the provider again");

    /* ---- what Save sends ---- */
    await page.click("#config-discard");
    await until(async () => /No unsaved changes|Changes discarded/.test(await page.textContent("#config-status")), "Discard");
    await dm.locator(".set-combo-btn").click();
    await until(async () => (await ids(dm)).length === 2, "the list after Discard");
    await dm.locator('.set-combo-opt[data-id="alpha-2"]').click();
    await page.click("#config-save");
    await until(async () => puts.length === 1, "the PUT");
    if (puts[0].default_model !== "alpha-2") fail("Save sent default_model " + JSON.stringify(puts[0].default_model));
    await until(async () => /Saved\./.test(await page.textContent("#config-status")), "the save to finish");
    if ((await dmi.inputValue()) !== "alpha-2") fail("after the save the form shows " + await dmi.inputValue());
    ok("a picked model is what Save sends");

    /* ---- light theme and phone width ---- */
    const darkBg = await (async () => { await dm.locator(".set-combo-btn").click(); await until(() => popOpen(dm), "the list");
      return dm.locator(".set-combo-pop").evaluate(p => getComputedStyle(p).backgroundColor); })();
    await dmi.press("Escape");
    await page.click("#theme-btn");
    await dm.locator(".set-combo-btn").click(); await until(() => popOpen(dm), "the list in the light theme");
    const liteBg = await dm.locator(".set-combo-pop").evaluate(p => getComputedStyle(p).backgroundColor);
    await shot("picker-default-light.png");
    const bodyBg = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
    if (liteBg === darkBg || !/^rgb\((2[0-9]{2}|1[89][0-9]), /.test(liteBg)) fail("the list does not take the light tokens: " + darkBg + " / " + liteBg + " (body " + bodyBg + ")");
    await dmi.press("Escape");
    await page.click("#theme-btn");
    ok("light theme: the list takes the light tokens");

    await page.setViewportSize({ width: 390, height: 844 });
    await dm.scrollIntoViewIfNeeded();
    await dm.locator(".set-combo-btn").click(); await until(() => popOpen(dm), "the list at phone width");
    await shot("picker-phone.png");
    const geo = await dm.locator(".set-combo-pop").evaluate(p => { const r = p.getBoundingClientRect();
      return [r.left, r.right, document.documentElement.scrollWidth, document.body.scrollWidth]; });
    if (geo[0] < 0 || geo[1] > 390 || geo[2] > 390 || geo[3] > 390) fail("the open list at phone width: " + geo);
    await dmi.press("Escape");
    ok("phone width: the open list stays on screen, no sideways scroll");

    if (failures) throw new Error(failures + " failure(s)");
    console.log("webui_model_picker_e2e: OK");
  } catch (e) {
    if (!failures) console.log("FAIL: " + e.message);
    console.log("---- gateway log (tail) ----\n" + gwLog.split("\n").slice(-25).join("\n"));
    process.exitCode = 1;
  } finally {
    await browser.close();
    gw.kill();
    provider.close();
    fs.rmSync(home, { recursive: true, force: true });
  }
})();
