#!/usr/bin/env node
/* The web UI's Workflow tab, against the real gateway.

   One gateway holds three saved workflows (a two-step one, a five-step
   one, and one whose name, description and step id are HTML) and one the
   agent staged for approval; a second holds none. llm steps reach a fake
   OpenAI-compatible provider that answers with the first line of the
   prompt (slowly for "Summarise", so a run is seen in flight). Through
   headless Chromium:

     - the list matches GET /v1/workflows: one row per workflow, by name,
       with its step count and the tool it is served as;
     - HTML in a workflow's name, description or step id is drawn as text;
     - the staged workflow shows with its steps; Approve saves it;
     - opening a workflow draws its steps, with their type labels;
     - an edit (description, a step dragged, a step added) marks the editor
       unsaved, Back asks first, and Save reaches the route;
     - a run shows its steps as running, then each step's result; a run
       that fails names the step and marks the ones after it as not run;
     - Delete asks first and does nothing when cancelled;
     - with no workflows, the empty state shows;
     - phone width: no sideways scroll, on the list and in the editor.

   Needs node with Playwright and a Chromium; skips without them.
   WF_SHOTS=<dir> also writes screenshots there.
   usage: node webui_workflow_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

let gwLog = "", failures = 0;
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

/* The model behind every llm step: it answers with the first line of the
   prompt it was given, so a run's output shows which step said what. */
const text = m => { const c = (m && m.content) || ""; return Array.isArray(c) ? c.map(p => p.text || "").join(" ") : c; };
const provider = http.createServer((req, res) => {
  let raw = "";
  req.on("data", c => raw += c);
  req.on("end", async () => {
    let body = {};
    try { body = JSON.parse(raw || "{}"); } catch {}
    const msgs = body.messages || [];
    const last = msgs[msgs.length - 1] || {};
    const q = String(text(last)).split("\n\n[current date/time")[0].trim();
    if (q.startsWith("Summarise")) await sleep(1200);
    const content = "Model says: " + q.split("\n")[0].slice(0, 60);
    if (!body.stream) {
      const out = JSON.stringify({ id: "c", object: "chat.completion", model: "m",
        choices: [{ index: 0, finish_reason: "stop", message: { role: "assistant", content } }],
        usage: { prompt_tokens: 3, completion_tokens: 3 } });
      res.writeHead(200, { "content-type": "application/json", "content-length": Buffer.byteLength(out) });
      return res.end(out);
    }
    res.writeHead(200, { "content-type": "text/event-stream" });
    const frame = o => res.write("data: " + JSON.stringify(o) + "\n\n");
    frame({ choices: [{ index: 0, delta: { role: "assistant", content } }] });
    frame({ choices: [{ index: 0, delta: {}, finish_reason: "stop" }] });
    frame({ choices: [], usage: { prompt_tokens: 3, completion_tokens: 3 } });
    res.end("data: [DONE]\n\n");
  });
});

const XSS_NAME = '<img src=x onerror="window.__wfXss=1">Report';
const XSS_DESC = '<script>window.__wfXss=2</script> in a description';
const XSS_NODE = '<b id="wfxss">step</b>';

/* A two-step workflow, a longer one, and one whose name and a step id are HTML. */
const SPECS = [
  { name: "digest", description: "Read a file and summarise it.",
    inputs: [{ name: "path", type: "string", required: false }],   // the editor has no control for this: a save keeps it
    outputs: [{ name: "summary", value: "{{nodes.sum}}", type: "string" }],
    nodes: [{ id: "fetch", tool: "read_file", args: { path: "{{inputs.path}}" }, x: 192, y: 48 },
            { id: "sum", tool: "llm", args: { provider: "", model: "", prompt: "Summarise this file:\n{{nodes.fetch}}" }, x: 432, y: 48 }],
    edges: [{ from: "fetch", to: "sum" }] },
  { name: "release-notes", description: "Turn the changelog into reviewed release notes.",
    inputs: [{ name: "version", type: "string", required: true }],
    outputs: [{ name: "notes", value: "{{nodes.polish}}", type: "string" }],
    nodes: [{ id: "log", tool: "read_file", args: { path: "CHANGELOG.md" } },
            { id: "outline", tool: "llm", args: { prompt: "Outline release {{inputs.version}}:\n{{nodes.log}}" } },
            { id: "draft", tool: "llm", args: { prompt: "Draft notes from the outline:\n{{nodes.outline}}" } },
            { id: "review", tool: "llm", args: { prompt: "Review the draft:\n{{nodes.draft}}" } },
            { id: "polish", tool: "llm", args: { prompt: "Polish with the review:\n{{nodes.draft}}\n{{nodes.review}}" } }],
    edges: [{ from: "log", to: "outline" }, { from: "outline", to: "draft" }, { from: "draft", to: "review" },
            { from: "review", to: "polish" }, { from: "draft", to: "polish" }] },
  { id: "html-name", name: XSS_NAME, description: XSS_DESC, inputs: [], outputs: [],
    nodes: [{ id: XSS_NODE, tool: "llm", args: { prompt: "hello" } }], edges: [] },
];
/* What an agent's workflow_save leaves when nobody could be asked. */
const PENDING = { id: "shout", name: "shout", description: "Read a file, staged by an agent.",
  inputs: [{ name: "path", type: "string", required: true }],
  nodes: [{ id: "r", tool: "read_file", args: { path: "{{inputs.path}}" } }], edges: [] };

let binary = "";
async function startGateway(pport, tag, { seed = false } = {}) {
  const port = await freePort();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-wf-" + tag + "-"));
  const ws = path.join(home, "workspace");
  fs.mkdirSync(ws, { recursive: true });
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify({
    gateway: { port, bind_addr: "127.0.0.1" },
    providers: [{ name: "fake", kind: "openai", api_base: `http://127.0.0.1:${pport}/v1`, api_key: "sk-test", model: "m" }],
    default_provider: "fake", default_model: "m", workflows_enabled: true }));
  const proc = spawn(binary, ["gateway", "--port", String(port), "--addr", "127.0.0.1", "--no-mcp"],
                     { cwd: home, env: Object.assign({}, process.env, { PASCLAW_HOME: home }), stdio: ["ignore", "pipe", "pipe"] });
  proc.stdout.on("data", d => gwLog += d); proc.stderr.on("data", d => gwLog += d);
  const base = `http://127.0.0.1:${port}`;
  await until(async () => (await fetch(base + "/v1/health")).ok, "the " + tag + " gateway");
  const api = async (method, p, body) => {
    const r = await fetch(base + p, { method, headers: { "content-type": "application/json" },
                                      body: body === undefined ? undefined : JSON.stringify(body) });
    return [r.status, await r.json().catch(() => ({}))];
  };
  if (seed) {
    fs.writeFileSync(path.join(ws, "notes.txt"), "PasClaw keeps a copy before every edit.\nSecond line.\n");
    fs.writeFileSync(path.join(ws, "CHANGELOG.md"), "# Changelog\n- workflows got a new tab\n");
    for (const s of SPECS) {
      const [st, j] = await api("POST", "/v1/workflows", s);
      if (st !== 200) fail("seed " + s.name + ": " + st + " " + JSON.stringify(j));
    }
    const pdir = path.join(ws, "workflows", ".pending");
    fs.mkdirSync(pdir, { recursive: true });
    fs.writeFileSync(path.join(pdir, "shout.json"), JSON.stringify(PENDING));
  }
  return { base, home, ws, proc, api };
}

module.exports = { setBinary: b => { binary = b; }, startGateway, provider, freePort, SPECS };
if (require.main !== module) return;

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_workflow_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }
binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const shots = process.env.WF_SHOTS || "";
if (shots) fs.mkdirSync(shots, { recursive: true });

(async () => {
  const pport = await freePort();
  await new Promise(r => provider.listen(pport, "127.0.0.1", r));
  const A = await startGateway(pport, "full", { seed: true });
  const B = await startGateway(pport, "empty");
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: "dark" });
  const page = await ctx.newPage();
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  let answer = false;            // what the next confirm() gets
  const asked = [];
  page.on("dialog", d => { asked.push(d.message()); answer ? d.accept() : d.dismiss(); });
  const shot = async (name, full = true) => { if (shots) await page.screenshot({ path: path.join(shots, name), fullPage: full }); };
  const rowsOf = sel => page.$$eval(sel + " .wf-row", rs => rs.map(r => ({
    id: r.dataset.id, name: r.querySelector(".wf-rname").textContent,
    tool: (r.querySelector(".wf-rid") || {}).textContent || "",
    steps: (r.querySelector(".wf-rsteps") || {}).textContent || "" })));
  const noScroll = async (sel, what) => {
    const sw = await page.evaluate(s => [document.documentElement.scrollWidth, document.querySelector(s).scrollWidth,
                                         document.querySelector(s).clientWidth], sel);
    if (sw[0] > 390 || sw[1] > sw[2]) fail("sideways scroll at phone width (" + what + "): " + sw);
  };

  try {
    /* ---- the list matches the route ---- */
    const [st0, list0] = await A.api("GET", "/v1/workflows");
    if (st0 !== 200 || (list0.workflows || []).length !== 3) fail("GET /v1/workflows: " + st0 + " " + JSON.stringify(list0));
    await page.goto(A.base + "/#workflow");
    await until(async () => (await page.locator("#wfList .wf-row").count()) === 3, "the workflow rows");
    await until(async () => (await page.locator("#wf-pend .wf-row").count()) === 1, "the staged workflow");
    await shot("workflow-list-desktop-dark.png");
    const want = list0.workflows.slice().sort((a, b) => a.name.localeCompare(b.name));
    const rows = await rowsOf("#wfList");
    want.forEach((w, i) => {
      const r = rows[i];
      const tool = ("wf_" + w.id).replace(/[^A-Za-z0-9_-]/g, "_");
      if (!r || r.id !== w.id || r.name !== w.name || r.tool !== tool ||
          r.steps !== w.nodes + (w.nodes === 1 ? " step" : " steps"))
        fail(`row ${i}: ${JSON.stringify(r)}, route ${JSON.stringify(w)}`);
    });
    if ((await page.textContent("#wf-saved-n")) !== "3") fail("the Saved count");
    ok("rows match the route: by name, step count, the tool each is served as");

    /* ---- HTML is text ---- */
    const xss = () => page.evaluate(() => [window.__wfXss, document.querySelectorAll(
      "#tab-workflow img, #tab-workflow script, #wfxss").length]);
    let h = await xss();
    if (h[0] !== undefined || h[1] !== 0) fail("HTML in a workflow name or description rendered as markup: " + h);
    const listText = await page.textContent("#wfList");
    if (!listText.includes(XSS_NAME) || !listText.includes(XSS_DESC)) fail("the HTML name/description is not shown as text");

    /* ---- the staged workflow: its steps, then Approve ---- */
    const pend = (await page.textContent("#wf-pend")).replace(/\s+/g, " ");
    if (!/shout/.test(pend) || !/1 step/.test(pend) || !/read_file/.test(pend) || !/\{\{inputs\.path\}\}/.test(pend))
      fail("the staged workflow does not show its steps: " + pend);
    await page.click("#wf-pend .wf-approve");
    await until(async () => /Approved shout/.test(await page.textContent("#wf-note")), "the approve note");
    await until(async () => (await page.locator("#wfList .wf-row").count()) === 4, "shout in the saved list");
    await until(async () => await page.isHidden("#wf-pend-sec"), "the approval section to go after the last approval");
    const [, pend2] = await A.api("GET", "/v1/workflows/pending");
    const [stShout] = await A.api("GET", "/v1/workflows/shout");
    if ((pend2.pending || []).length || stShout !== 200) fail("approve did not reach the route: " + JSON.stringify(pend2));
    ok("the staged workflow shows its steps; Approve saves it");

    /* ---- open the HTML-named one: its step id is text too ---- */
    await page.click('#wfList .wf-row[data-id="html-name"] [data-act=open]');
    await until(async () => (await page.locator("#wfCanvas .wf-node").count()) === 1, "the HTML-named workflow's step");
    h = await xss();
    if (h[0] !== undefined || h[1] !== 0) fail("HTML in a step id rendered as markup: " + h);
    if ((await page.textContent("#wfCanvas .wf-node .wf-nid")) !== XSS_NODE) fail("the HTML step id is not shown as text");
    if ((await page.inputValue("#wfName")) !== XSS_NAME) fail("the name field: " + await page.inputValue("#wfName"));
    ok("HTML in a workflow's name, description and step id is drawn as text");

    /* ---- open digest: its steps ---- */
    await page.click("#wf-back");
    await until(async () => await page.isVisible("#wf-home"), "the list again");
    await page.click('#wfList .wf-row[data-id="digest"] .wf-rname');
    await until(async () => (await page.inputValue("#wfName")) === "digest" &&
                            (await page.locator("#wfCanvas .wf-node").count()) === 2, "digest's steps");
    const nodes = await page.$$eval("#wfCanvas .wf-node", ns => ns.map(n => [n.dataset.node,
      n.querySelector(".wf-kind").textContent, n.style.left]));
    if (JSON.stringify(nodes) !== JSON.stringify([["fetch", "Tool", "192px"], ["sum", "LLM", "432px"]]))
      fail("digest's steps: " + JSON.stringify(nodes));
    if ((await page.locator("#wfEdgeLayer path.wf-edge").count()) !== 1) fail("digest's connection is not drawn");
    if ((await page.textContent("#wf-state")) !== "Saved") fail("state on open: " + await page.textContent("#wf-state"));
    ok("opening a workflow draws its steps, their type labels and the connection");

    /* ---- edit, Back asks, Save reaches the route ---- */
    await page.click("#wf-details > summary");
    await page.fill("#wfDesc", "Read a file, then summarise it in a line.");
    const head = await page.locator('#wfCanvas .wf-node[data-node="sum"] .wf-head').boundingBox();
    await page.mouse.move(head.x + 60, head.y + 15);
    await page.mouse.down();
    await page.mouse.move(head.x + 110, head.y + 75, { steps: 6 });
    await page.mouse.move(head.x + 156, head.y + 111, { steps: 6 });
    await page.mouse.up();
    await page.selectOption("#wfPalette", "llm");
    await page.click("#wfAddNode");
    await until(async () => (await page.locator("#wfCanvas .wf-node").count()) === 3, "the added step");
    if (!(await page.isVisible("#wfInspect"))) fail("the new step's settings do not open");
    if ((await page.textContent("#wf-state")) !== "Unsaved changes") fail("state after edits: " + await page.textContent("#wf-state"));
    await shot("workflow-editor-desktop-dark.png");
    answer = false;
    await page.click("#wf-back");
    await sleep(200);
    if (!asked.length || !/unsaved changes/.test(asked[asked.length - 1])) fail("Back did not ask: " + JSON.stringify(asked));
    if (!(await page.isVisible("#wf-editor"))) fail("a cancelled Back left the editor");
    await page.click("#wfSave");
    await until(async () => (await page.textContent("#wf-state")) === "Saved", "the save");
    const [, saved] = await A.api("GET", "/v1/workflows/digest");
    const sum = (saved.nodes || []).find(n => n.id === "sum");
    if (saved.description !== "Read a file, then summarise it in a line." || (saved.nodes || []).length !== 3 ||
        !sum || sum.x !== 528 || sum.y !== 144 || JSON.stringify(saved.edges) !== JSON.stringify([{ from: "fetch", to: "sum" }]) ||
        JSON.stringify(saved.inputs) !== JSON.stringify([{ name: "path", type: "string", required: false }]))
      fail("the save did not reach the route: " + JSON.stringify(saved));
    ok("an edit marks the editor unsaved, Back asks first, Save sends the description, the moved and the added step, and keeps the rest");

    /* ---- a run: in flight, then each step ---- */
    await page.click('#wfInspect #wfInspDel');   // the added step reads an input digest doesn't have; drop it
    await page.click("#wfSave");
    await until(async () => (await page.textContent("#wf-state")) === "Saved", "the second save");
    await page.click("#wfRun");
    await until(async () => await page.isVisible("#wfRunInputs input[name=path]"), "the run's input");
    await page.fill("#wfRunInputs input[name=path]", "notes.txt");
    await page.click("#wf-run-go");
    await until(async () => (await page.locator('#wfCanvas .wf-node[data-st="run"]').count()) === 2, "the steps to show as running");
    if (!/^Running 2 steps/.test(await page.textContent("#wf-run-state"))) fail("the run state: " + await page.textContent("#wf-run-state"));
    await until(async () => await page.isVisible("#wfResults .wf-sum.ok"), "the run to finish", 20000);
    const steps = await page.$$eval("#wfResults .wf-step", ls => ls.map(l => [l.dataset.node, l.className,
      (l.querySelector(".wf-step-out") || {}).textContent || ""]));
    if (steps.length !== 2 || steps[0][0] !== "fetch" || !/ok/.test(steps[0][1]) || !/PasClaw keeps a copy/.test(steps[0][2]) ||
        steps[1][0] !== "sum" || !/ok/.test(steps[1][1]) || steps[1][2] !== "Model says: Summarise this file:")
      fail("the run's steps: " + JSON.stringify(steps));
    const sts = await page.$$eval("#wfCanvas .wf-node", ns => ns.map(n => n.dataset.st));
    if (JSON.stringify(sts) !== '["ok","ok"]') fail("the steps' state on the canvas after the run: " + sts);
    await page.evaluate(() => document.querySelector("#wfRunPanel").scrollIntoView({ block: "end" }));
    await shot("workflow-run-desktop-dark.png", false);
    ok("a run shows its steps running, then each step's output");

    /* ---- a failing run ---- */
    await page.fill("#wfRunInputs input[name=path]", "missing.txt");
    await page.click("#wf-run-go");
    await until(async () => await page.isVisible("#wfResults .wf-sum.err"), "the failed run", 20000);
    const errText = await page.textContent("#wfResults .wf-sum");
    if (!/Failed at step fetch/.test(errText)) fail("the failed run: " + errText);
    const fsts = await page.$$eval("#wfResults .wf-step", ls => ls.map(l => l.className + ":" + l.querySelector(".wf-tag").textContent));
    if (!/err:Failed/.test(fsts[0]) || !/skip:Didn't run/.test(fsts[1])) fail("the failed run's steps: " + fsts);
    const fsts2 = await page.$$eval("#wfCanvas .wf-node", ns => ns.map(n => n.dataset.st));
    if (JSON.stringify(fsts2) !== '["err","skip"]') fail("the canvas after the failed run: " + fsts2);
    await page.evaluate(() => document.querySelector("#wfRunPanel").scrollIntoView({ block: "end" }));
    await shot("workflow-run-failed-desktop-dark.png", false);
    ok("a failed run names the step, and the steps after it read Didn't run");

    /* ---- Delete asks first ---- */
    await page.click("#wf-back");
    await until(async () => await page.isVisible("#wf-home"), "the list after the runs");
    const n0 = asked.length;
    answer = false;
    await page.click('#wfList .wf-row[data-id="release-notes"] [data-act=delete]');
    await sleep(200);
    if (asked.length !== n0 + 1 || !/Delete the workflow release-notes\?/.test(asked[n0])) fail("Delete did not ask: " + JSON.stringify(asked));
    if ((await A.api("GET", "/v1/workflows/release-notes"))[0] !== 200) fail("a cancelled Delete deleted it");
    answer = true;
    await page.click('#wfList .wf-row[data-id="release-notes"] [data-act=delete]');
    await until(async () => (await A.api("GET", "/v1/workflows/release-notes"))[0] === 404, "the delete");
    await until(async () => (await page.locator('#wfList .wf-row[data-id="release-notes"]').count()) === 0, "the row to go");
    ok("Delete asks first, does nothing when cancelled, deletes when confirmed");

    /* ---- phone width, light ---- */
    await page.setViewportSize({ width: 390, height: 844 });
    await page.click("#theme-btn");
    await page.reload();   // the URL is already #workflow: a goto would not load the page again
    await until(async () => (await page.locator("#wfList .wf-row").count()) === 3, "the list at phone width");
    await noScroll("#wf-home", "list");
    await shot("workflow-list-phone-light.png");
    await page.click('#wfList .wf-row[data-id="digest"] .wf-rname');
    await until(async () => await page.isVisible("#wf-editor") &&
                            (await page.locator("#wfCanvas .wf-node").count()) === 2, "the editor at phone width");
    await noScroll("#wf-editor", "editor");
    await shot("workflow-editor-phone-light.png");
    await page.click("#wfRun");
    await page.fill("#wfRunInputs input[name=path]", "notes.txt");
    await page.click("#wf-run-go");
    await until(async () => await page.isVisible("#wfResults .wf-sum.ok"), "the run at phone width", 20000);
    await noScroll("#wf-editor", "run");
    await page.evaluate(() => document.querySelector("#wfRunPanel").scrollIntoView({ block: "start" }));
    await shot("workflow-run-phone-light.png", false);
    ok("phone width: no sideways scroll on the list, in the editor or in a run");

    /* ---- no workflows ---- */
    await page.goto(B.base + "/#workflow");
    await page.click("#theme-btn");   // another origin: the light choice is not remembered here
    await until(async () => await page.isVisible("#wfList .wf-empty"), "the empty state");
    const empty = (await page.textContent("#wfList")).replace(/\s+/g, " ");
    if (!/No workflows yet/.test(empty) || (await page.locator("#wfList .wf-row").count()) !== 0) fail("empty state: " + empty);
    await until(async () => await page.isHidden("#wf-pend-sec"), "no approval section with nothing staged");
    await noScroll("#wf-home", "empty");
    await shot("workflow-empty-phone-light.png");
    await page.setViewportSize({ width: 1280, height: 900 });
    await shot("workflow-empty-desktop-light.png");
    await page.click("#wfList .wf-empty [data-act=new]");
    await until(async () => await page.isVisible("#wf-editor"), "a new workflow");
    if (!/No steps yet/.test(await page.textContent("#wfCanvas")) || (await page.textContent("#wf-state")) !== "New, not saved")
      fail("a new workflow's editor");
    await shot("workflow-new-desktop-light.png");
    ok("with no workflows, the empty state shows, and New opens an empty editor");
  } catch (e) {
    if (!failures) { console.log("FAIL: " + (e && e.stack || e)); failures++; }
  } finally {
    await browser.close();
    A.proc.kill(); B.proc.kill(); provider.close();
    for (const g of [A, B]) try { fs.rmSync(g.home, { recursive: true, force: true }); } catch {}
  }
  if (failures) {
    console.log("--- gateway log (tail) ---\n" + gwLog.split("\n").slice(-30).join("\n"));
    process.exit(1);
  }
  console.log("webui_workflow_e2e: all checks passed");
})();
