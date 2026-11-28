#!/usr/bin/env node
/* The Workflow tab's sharing controls, against the real gateway, in
   headless Chromium (the gateways and fixtures of webui_workflow_e2e.js):

     - the editor's Export menu downloads the saved workflow: "Python script"
       gives wf_<id>.py, "Workflow file (.json)" gives <id>.pasclaw-workflow.json;
       with unsaved changes it says to save first and downloads nothing;
     - Import on a gateway with no workflows: a picked file arrives in
       "Waiting for your approval" with its steps, not in the saved list;
       Approve saves it;
     - importing it again offers Rename / Replace / Cancel, and Rename stages
       it under the new id; a pasted file that is not one is refused with
       the reason.

   Needs node with Playwright and a Chromium; skips without them.
   usage: node webui_workflow_share_e2e.js <pasclaw-binary> */
const fs = require("fs");
const os = require("os");
const path = require("path");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_workflow_share_e2e needs Playwright"); process.exit(0); }
const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const base = require("./webui_workflow_e2e.js");
base.setBinary(binary);

let failures = 0;
const fail = msg => { console.log("FAIL: " + msg); failures++; throw new Error(msg); };
const ok = msg => console.log("  ok: " + msg);
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, what, ms = 15000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch {} await sleep(50); }
  fail("timed out waiting for " + what);
}

(async () => {
  const pport = await base.freePort();
  await new Promise(r => base.provider.listen(pport, "127.0.0.1", r));
  const A = await base.startGateway(pport, "share-a", { seed: true });
  const B = await base.startGateway(pport, "share-b");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-share-"));
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, acceptDownloads: true });
  const page = await ctx.newPage();
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  page.on("dialog", d => d.accept());
  try {
    /* ---- Export from the editor ---- */
    await page.goto(A.base + "/#workflow");
    await until(async () => (await page.locator("#wfList .wf-row").count()) === 3, "the workflow rows");
    await page.click('#wfList .wf-row[data-id="digest"] .wf-rname');
    await until(async () => (await page.inputValue("#wfName")) === "digest", "digest in the editor");
    await page.click("#wfExport");
    await until(async () => await page.isVisible("#wf-export-menu"), "the Export menu");
    const items = await page.$$eval("#wf-export-menu [role=menuitem]", bs => bs.map(b => b.firstChild.textContent));
    if (JSON.stringify(items) !== '["Workflow file (.json)","Python script","Object Pascal program"]')
      fail("the Export menu's items: " + JSON.stringify(items));
    let [dl] = await Promise.all([page.waitForEvent("download"), page.click('#wf-export-menu [data-lang="python"]')]);
    if (dl.suggestedFilename() !== "wf_digest.py") fail("the Python download is named " + dl.suggestedFilename());
    const py = fs.readFileSync(await dl.path(), "utf8");
    if (!/^#!\/usr\/bin\/env python3/.test(py) || !py.includes('"id": "digest"')) fail("the Python download: " + py.slice(0, 200));
    if (await page.isVisible("#wf-export-menu")) fail("the menu stays open after a download");
    await page.click("#wfExport");
    [dl] = await Promise.all([page.waitForEvent("download"), page.click('#wf-export-menu [data-lang="workflow"]')]);
    if (dl.suggestedFilename() !== "digest.pasclaw-workflow.json") fail("the workflow file is named " + dl.suggestedFilename());
    const file = path.join(tmp, "digest.pasclaw-workflow.json");
    fs.copyFileSync(await dl.path(), file);
    if (JSON.parse(fs.readFileSync(file, "utf8")).format !== "pasclaw-workflow") fail("the workflow file's format");
    ok("Export downloads wf_digest.py and digest.pasclaw-workflow.json");

    await page.click("#wf-details > summary");
    await page.fill("#wfDesc", "An edit not saved yet.");
    let downloaded = false;
    const onDl = () => { downloaded = true; };
    page.on("download", onDl);
    await page.click("#wfExport");
    await page.click('#wf-export-menu [data-lang="python"]');
    await until(async () => /Save your changes first/.test(await page.textContent("#wfMsg")), "the save-first message");
    await sleep(300);
    page.off("download", onDl);
    if (downloaded) fail("an export with unsaved changes downloaded anyway");
    ok("with unsaved changes, Export says to save first and downloads nothing");

    /* ---- Import on an empty gateway ---- */
    await page.goto(B.base + "/#workflow");
    await until(async () => /No workflows yet/.test(await page.textContent("#wfList")), "the empty list");
    await page.click("#wf-import");
    await until(async () => await page.isVisible("#wf-imp"), "the import panel");
    await page.setInputFiles("#wf-imp-file", file);
    await until(async () => (await page.locator('#wf-pend .wf-row[data-id="digest"]').count()) === 1, "the staged import");
    if (!/Imported digest/.test(await page.textContent("#wf-note"))) fail("the import note: " + await page.textContent("#wf-note"));
    if (await page.isVisible("#wf-imp")) fail("the import panel stays open after an import");
    const pend = (await page.textContent('#wf-pend .wf-row[data-id="digest"]')).replace(/\s+/g, " ");
    if (!/fetch read_file/.test(pend) || !/sum llm/.test(pend)) fail("the staged import's steps: " + pend);
    if ((await page.locator('#wfList .wf-row[data-id="digest"]').count()) !== 0) fail("an import is saved before approval");
    const [, saved0] = await B.api("GET", "/v1/workflows");
    if ((saved0.workflows || []).length) fail("GET /v1/workflows lists the import before approval");
    await page.click('#wf-pend .wf-row[data-id="digest"] .wf-approve');
    await until(async () => (await page.locator('#wfList .wf-row[data-id="digest"]').count()) === 1, "digest saved");
    ok("Import (file): staged with its steps, not saved; Approve saves it");

    /* ---- a clash, then Rename ---- */
    await page.click("#wf-import");
    await page.setInputFiles("#wf-imp-file", file);
    await until(async () => await page.isVisible("#wf-imp-clash"), "the clash choices");
    if (!/already here/.test(await page.textContent("#wf-imp-clash-msg"))) fail("the clash message");
    if ((await page.inputValue("#wf-imp-as")) !== "digest-2") fail("the suggested new id: " + await page.inputValue("#wf-imp-as"));
    await page.click("#wf-imp-rename");
    await until(async () => (await page.locator('#wf-pend .wf-row[data-id="digest-2"]').count()) === 1, "the renamed import");
    ok("importing it again offers Rename / Replace / Cancel; Rename stages it as digest-2");

    /* ---- a pasted file that is not one ---- */
    await page.click("#wf-import");
    await page.fill("#wf-imp-text", '{"name": "x"}');
    await page.click("#wf-imp-go");
    await until(async () => /format/.test(await page.textContent("#wf-imp-err")), "the refusal");
    ok("a pasted file that is not a workflow file is refused with the reason");
  } catch (e) {
    if (!failures) { console.log("FAIL: " + (e && e.stack || e)); failures++; }
  } finally {
    await browser.close();
    A.proc.kill(); B.proc.kill(); base.provider.close();
    for (const d of [A.home, B.home, tmp]) try { fs.rmSync(d, { recursive: true, force: true }); } catch {}
  }
  if (failures) process.exit(1);
  console.log("webui_workflow_share_e2e: all checks passed");
})();
