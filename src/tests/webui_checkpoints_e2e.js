#!/usr/bin/env node
/* The web UI's Checkpoints tab, against the real gateway.

   A fake OpenAI-compatible provider answers "WRITE <path>::<content>" with a
   write_file tool call, so each chat turn sent to POST /v1/chat edits a file
   in the workspace and the gateway checkpoints it (no X-PasClaw-Session:
   the workspace timeline, which is also what the tab shows with no chat
   open). Three turns: one edits notes.txt, one creates a file whose name
   is HTML, one edits notes.txt again and creates a second file. A second
   gateway has checkpoints and no turns. Through headless Chromium:

     - the rows match GET /v1/checkpoints: newest first, turn numbers,
       a relative time with the route's exact time on hover, the file
       count, and each file with Added or Changed;
     - HTML in a file name is drawn as text;
     - Undo in the tab rewinds notes.txt on disk and reports the files it
       restored; Redo puts it back; Restore on an older turn asks first,
       does nothing when cancelled, and rewinds the file when confirmed;
     - with no checkpoints, the empty state shows;
     - phone width: no sideways scroll.

   Needs node with Playwright and a Chromium; skips without them.
   CKP_SHOTS=<dir> also writes screenshots there.
   usage: node webui_checkpoints_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_checkpoints_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const shots = process.env.CKP_SHOTS || "";
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

/* ---------------------------------------------------------------- provider */
const text = m => { const c = (m && m.content) || ""; return Array.isArray(c) ? c.map(p => p.text || "").join(" ") : c; };
const clean = t => String(t).split("\n\n[current date/time")[0].trim();
function sendReply(res, stream, message, finish) {
  if (!stream) {
    const out = JSON.stringify({ id: "c", object: "chat.completion", model: "m",
      choices: [{ index: 0, finish_reason: finish, message }], usage: { prompt_tokens: 3, completion_tokens: 3 } });
    res.writeHead(200, { "content-type": "application/json", "content-length": Buffer.byteLength(out) });
    return res.end(out);
  }
  res.writeHead(200, { "content-type": "text/event-stream" });
  const frame = o => res.write("data: " + JSON.stringify(o) + "\n\n");
  if (message.tool_calls)
    frame({ choices: [{ index: 0, delta: { role: "assistant", tool_calls: message.tool_calls.map((t, i) => Object.assign({ index: i }, t)) } }] });
  else
    frame({ choices: [{ index: 0, delta: { role: "assistant", content: message.content } }] });
  frame({ choices: [{ index: 0, delta: {}, finish_reason: finish }] });
  frame({ choices: [], usage: { prompt_tokens: 3, completion_tokens: 3 } });
  res.end("data: [DONE]\n\n");
}
/* "WRITE a.txt::one | b.txt::two": one write_file call per path::content pair. */
const provider = http.createServer((req, res) => {
  let raw = "";
  req.on("data", c => raw += c);
  req.on("end", () => {
    const body = JSON.parse(raw || "{}");
    const msgs = body.messages || [];
    const last = msgs[msgs.length - 1] || {};
    if (last.role === "tool") return sendReply(res, body.stream, { role: "assistant", content: "Done." }, "stop");
    const q = clean(text(last));
    if (!q.startsWith("WRITE ")) return sendReply(res, body.stream, { role: "assistant", content: "hello" }, "stop");
    const calls = q.slice(6).split(" | ").map((pair, i) => {
      const sp = pair.indexOf("::");
      return { id: "w" + i, type: "function",
               function: { name: "write_file", arguments: JSON.stringify({ path: pair.slice(0, sp), content: pair.slice(sp + 2) }) } };
    });
    sendReply(res, body.stream, { role: "assistant", content: null, tool_calls: calls }, "tool_calls");
  });
});

async function startGateway(pport, tag) {
  const port = await freePort();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-ckp-" + tag + "-"));
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify({
    gateway: { port, bind_addr: "127.0.0.1" },
    providers: [{ name: "fake", kind: "openai", api_base: `http://127.0.0.1:${pport}/v1`, api_key: "sk-test", model: "m" }],
    default_provider: "fake", default_model: "m" }));
  const proc = spawn(binary, ["gateway", "--port", String(port), "--addr", "127.0.0.1", "--no-mcp"],
                     { cwd: home, env: Object.assign({}, process.env, { PASCLAW_HOME: home }), stdio: ["ignore", "pipe", "pipe"] });
  proc.stdout.on("data", d => gwLog += d); proc.stderr.on("data", d => gwLog += d);
  const base = `http://127.0.0.1:${port}`;
  await until(async () => (await fetch(base + "/v1/health")).ok, "the " + tag + " gateway");
  const chat = async message => {
    const r = await fetch(base + "/v1/chat", { method: "POST", headers: { "content-type": "application/json" },
                                               body: JSON.stringify({ message }) });
    if (!r.ok) fail("POST /v1/chat: HTTP " + r.status + " " + await r.text());
    return r.json();
  };
  const state = async () => (await fetch(base + "/v1/checkpoints")).json();
  return { base, home, proc, chat, state };
}

const XSS_NAME = '<img src=x onerror="window.__ckpXss=1">.txt';

module.exports = { startGateway, provider, freePort, XSS_NAME, until, sleep };
if (require.main !== module) return;

(async () => {
  const pport = await freePort();
  await new Promise(r => provider.listen(pport, "127.0.0.1", r));
  const A = await startGateway(pport, "turns");
  const B = await startGateway(pport, "empty");
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: "dark" });
  const page = await ctx.newPage();
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  let answer = false;            // what the next confirm() gets
  const asked = [];
  page.on("dialog", d => { asked.push(d.message()); answer ? d.accept() : d.dismiss(); });
  const shot = async name => { if (shots) await page.screenshot({ path: path.join(shots, name), fullPage: true }); };

  try {
    /* ---- three turns that edit files ---- */
    const ws = path.join(A.home, "workspace");
    const notes = path.join(ws, "notes.txt");
    await A.chat("WRITE notes.txt::version one");
    await A.chat(`WRITE ${XSS_NAME}::hello`);
    await A.chat("WRITE notes.txt::version two | plan.md::# plan");
    const read = () => fs.readFileSync(notes, "utf8");
    if (read() !== "version two") fail("notes.txt after three turns: " + read());
    const st = await A.state();
    if (!st.enabled || !Array.isArray(st.turns) || st.turns.length !== 3)
      fail("GET /v1/checkpoints: " + JSON.stringify(st));
    ok("three chat turns, three checkpoints (" + st.backend + " backend)");

    await page.goto(A.base + "/#checkpoints");
    await until(async () => (await page.locator("#cp-list .ckp-row").count()) === 3, "the checkpoint rows");
    await shot("checkpoints-desktop-dark.png");

    /* ---- rows match the route, newest first ---- */
    const want = st.turns.slice().sort((a, b) => b.turn - a.turn);
    const rows = await page.$$eval("#cp-list .ckp-row", rs => rs.map(r => ({
      turn: r.dataset.turn,
      title: r.querySelector(".ckp-turn").textContent,
      when: r.querySelector("time").textContent,
      at: r.querySelector("time").getAttribute("datetime"),
      count: r.querySelector(".ckp-count").textContent,
      files: [...r.querySelectorAll(".ckp-file")].map(f => [f.querySelector(".ckp-kind").textContent,
                                                            f.getAttribute("title")]) })));
    want.forEach((t, i) => {
      const r = rows[i];
      if (r.turn !== String(t.turn) || r.title !== "Turn " + t.turn) fail(`row ${i}: ${JSON.stringify(r)}, route turn ${t.turn}`);
      if (r.at !== t.ts) fail(`row ${i} time ${r.at}, route ${t.ts}`);
      if (!/^(just now|\d+ min ago)$/.test(r.when)) fail(`row ${i} reads ${r.when}`);
      const n = t.files.length;
      if (r.count !== n + (n === 1 ? " file" : " files")) fail(`row ${i} count ${r.count}`);
      if (JSON.stringify(r.files) !== JSON.stringify(t.files.map(f => [f.created ? "Added" : "Changed", f.path])))
        fail(`row ${i} files ${JSON.stringify(r.files)}`);
    });
    ok("rows match the route: newest first, turn, time, file count, each file Added or Changed");

    /* ---- HTML is text ---- */
    const html = await page.evaluate(() => [window.__ckpXss, document.querySelectorAll("#cp-list img, #cp-list script").length]);
    if (html[0] !== undefined || html[1] !== 0) fail("HTML in a file name rendered as markup: " + html);
    if (!(await page.textContent("#cp-list")).includes(XSS_NAME)) fail("the HTML file name is not shown as text");
    ok("HTML in a file name is drawn as text");

    /* ---- Undo and Redo ---- */
    await page.click("#cp-undo");
    await until(async () => read() === "version one", "Undo to rewind notes.txt");
    await until(async () => /Undid the last turn/.test(await page.textContent("#ckp-note")), "the undo note");
    const note = await page.textContent("#ckp-note");
    if (!/notes\.txt/.test(note)) fail("the undo note does not name the restored file: " + note);
    if (st.backend === "zpaq") {
      await until(async () => !(await page.isDisabled("#cp-redo")), "Redo to be enabled");
      await shot("checkpoints-after-undo-dark.png");
      await page.click("#cp-redo");
      await until(async () => read() === "version two", "Redo to put notes.txt back");
      ok("Undo rewinds the file on disk and names it; Redo puts it back");
    } else ok("Undo rewinds the file on disk and names it (redo needs the zpaq backend)");

    /* ---- Restore to before turn 2: asks first ----
       That rewinds turns 2 and 3, so notes.txt goes back to what turn 3
       found (turn 1 created it, and Undo leaves created files alone). */
    await page.click("#ckp-note .ckp-x");
    if (!(await page.isHidden("#ckp-note"))) fail("the note does not dismiss");
    if (read() !== "version two") fail("notes.txt before Restore: " + read());
    const turn2 = page.locator('#cp-list .ckp-row[data-turn="2"] .cp-revert');
    answer = false;
    await turn2.click();
    await sleep(300);
    if (asked.length !== 1 || !/before turn 2\?/.test(asked[0]) || !/2 turns \(2 to 3\)/.test(asked[0]))
      fail("Restore did not ask first: " + JSON.stringify(asked));
    if (read() !== "version two") fail("a cancelled Restore changed the file");
    answer = true;
    await turn2.click();
    await until(async () => read() === "version one", "Restore to rewind notes.txt");
    await until(async () => /Restored the workspace to before turn 2/.test(await page.textContent("#ckp-note")), "the restore note");
    ok("Restore asks first, does nothing when cancelled, rewinds the workspace when confirmed");

    /* ---- phone width, light ---- */
    await page.goto(A.base + "/#checkpoints");
    await page.setViewportSize({ width: 390, height: 844 });
    await page.click("#theme-btn");
    await until(async () => (await page.locator("#cp-list .ckp-row, #cp-list .ckp-empty").count()) > 0, "the tab again");
    const sw = await page.evaluate(() => [document.documentElement.scrollWidth, document.querySelector("#cp-pane").scrollWidth,
                                          document.querySelector("#cp-pane").clientWidth]);
    if (sw[0] > 390 || sw[1] > sw[2]) fail("sideways scroll at phone width: " + sw);
    await shot("checkpoints-phone-light.png");
    ok("phone width: no sideways scroll");

    /* ---- no checkpoints ---- */
    await page.goto(B.base + "/#checkpoints");
    await until(async () => await page.isVisible("#cp-list .ckp-empty"), "the empty state");
    const empty = (await page.textContent("#cp-list")).replace(/\s+/g, " ");
    if (!/No checkpoints yet/.test(empty) || (await page.locator("#cp-list .ckp-row").count()) !== 0) fail("empty state: " + empty);
    if (!(await page.isDisabled("#cp-undo"))) fail("Undo is enabled with nothing to undo");
    await shot("checkpoints-empty-phone-light.png");
    await page.setViewportSize({ width: 1280, height: 900 });
    await shot("checkpoints-empty-desktop-light.png");
    ok("with no checkpoints, the empty state shows and Undo is off");
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
  console.log("webui_checkpoints_e2e: all checks passed");
})();
