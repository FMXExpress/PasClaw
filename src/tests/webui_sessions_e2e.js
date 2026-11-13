#!/usr/bin/env node
/* The web UI: chats can be switched while a turn runs, and the chat's Files
   menu downloads what the agent wrote.

   Switching used to be refused outright while a reply streamed: one global
   turn wrote its reply into whichever chat was open when it ended, so the
   page simply did not let you leave. Now a turn belongs to the chat it was
   asked in. And the Files menu's downloads were a 403 whenever the gateway
   was launched outside its workspace: the menu passes the tool's own
   relative path, which /v1/fs resolved against the wrong directory.

   Against the real binary (launched outside its workspace), with a fake
   OpenAI-compatible provider in this script that holds each reply until the
   test lets it go, driven through headless Chromium:

     - a turn in chat A runs; a new chat B is opened and asked too; A is
       reopened from the list (marked running) and shows its question and
       the live reply, never B's; B's reply finishes while A is open and
       does not appear there; A's reply streams in while open; each chat's
       saved transcript holds only its own turns, and the gateway was
       asked under the right session each time;
     - a new chat left while its session is still being made (the create
       held back) still sends its own question, under its own new id, and
       the chat opened meanwhile keeps its id and transcript;
     - Stop in the open chat stops that turn only: the other one goes on;
     - deleting a chat whose turn is running discards that turn: the chat
       does not come back;
     - the Files menu lists a file the agent wrote with a relative path,
       and clicking it downloads that file's contents.

   Needs node with Playwright and a Chromium; skips when Playwright is not
   installed. usage: node webui_sessions_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_sessions_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }

let failures = 0, gwLog = "";
const fail = msg => { console.log("FAIL: " + msg); failures++; };
const ok = msg => console.log("  ok: " + msg);
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, what, ms = 15000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch {} await sleep(50); }
  throw new Error("timed out waiting for " + what);
}

/* ---------------------------------------------------------------- provider */
/* Every ordinary question is held until the test releases it, then answered
   "reply to <question>" in a few streamed pieces. "please write the file"
   gets a write_file call instead, answered at once. */
const held = new Map();        // question -> { release() }
const asked = [];              // { question, session } per provider request
function lastUserText(msgs) {
  for (let i = msgs.length - 1; i >= 0; i--)
    if (msgs[i].role === "user") {
      const c = msgs[i].content;
      const t = Array.isArray(c) ? c.map(p => p.text || "").join(" ") : (c || "");
      return t.split("\n\n[current date/time")[0].trim();
    }
  return "";
}
function sendReply(res, stream, message, finish) {
  if (!stream) {
    const out = JSON.stringify({ id: "c", object: "chat.completion", model: "m",
      choices: [{ index: 0, finish_reason: finish, message }], usage: { prompt_tokens: 3, completion_tokens: 3 } });
    res.writeHead(200, { "content-type": "application/json", "content-length": Buffer.byteLength(out) });
    return res.end(out);
  }
  res.writeHead(200, { "content-type": "text/event-stream" });
  const frame = o => res.write("data: " + JSON.stringify(o) + "\n\n");
  if (message.tool_calls) {
    frame({ choices: [{ index: 0, delta: { role: "assistant", tool_calls: message.tool_calls.map((t, i) => Object.assign({ index: i }, t)) } }] });
    frame({ choices: [{ index: 0, delta: {}, finish_reason: finish }] });
    frame({ choices: [], usage: { prompt_tokens: 3, completion_tokens: 3 } });
    res.end("data: [DONE]\n\n");
    return;
  }
  const words = message.content.split(/(?<= )/);
  let i = 0;
  const tick = () => {
    if (i < words.length) { frame({ choices: [{ index: 0, delta: { content: words[i++] } }] }); setTimeout(tick, 60); return; }
    frame({ choices: [{ index: 0, delta: {}, finish_reason: finish }] });
    frame({ choices: [], usage: { prompt_tokens: 3, completion_tokens: 3 } });
    res.end("data: [DONE]\n\n");
  };
  tick();
}
const provider = http.createServer((req, res) => {
  let raw = "";
  req.on("data", c => raw += c);
  req.on("end", () => {
    const body = JSON.parse(raw || "{}");
    const msgs = body.messages || [];
    const last = msgs[msgs.length - 1] || {};
    const q = lastUserText(msgs);
    if (last.role === "tool") return sendReply(res, body.stream, { role: "assistant", content: "the file is written" }, "stop");
    if (q === "please write the file")
      return sendReply(res, body.stream, { role: "assistant", content: null, tool_calls: [{ id: "w1", type: "function",
        function: { name: "write_file", arguments: JSON.stringify({ path: "out/report.txt", content: "the report body\n" }) } }] }, "tool_calls");
    asked.push({ question: q });
    let released = false;
    held.set(q, { release() { released = true; } });
    const wait = () => {
      if (res.destroyed) return;
      if (!released) return setTimeout(wait, 30);
      sendReply(res, body.stream, { role: "assistant", content: "reply to " + q + " streamed in pieces" }, "stop");
    };
    wait();
  });
});

/* ----------------------------------------------------------------- gateway */
function freePort() {
  return new Promise(r => { const s = http.createServer().listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => r(p)); }); });
}

(async () => {
  const pport = await freePort(), gport = await freePort();
  await new Promise(r => provider.listen(pport, "127.0.0.1", r));
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-sessions-e2e-"));
  const ws = path.join(home, "ws");
  fs.mkdirSync(ws);
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify({
    providers: [{ name: "fake", kind: "openai", api_base: `http://127.0.0.1:${pport}/v1`, api_key: "sk-test", model: "m" }],
    default_provider: "fake", default_model: "m",
    sandbox: { workspace: ws }, gateway: { port: gport, bind_addr: "127.0.0.1" } }));
  const gw = spawn(binary, ["gateway", "--port", String(gport), "--addr", "127.0.0.1"],
                   { cwd: home, env: Object.assign({}, process.env, { PASCLAW_HOME: home }), stdio: ["ignore", "pipe", "pipe"] });
  gw.stdout.on("data", d => gwLog += d); gw.stderr.on("data", d => gwLog += d);
  const base = `http://127.0.0.1:${gport}`;
  const api = async p => (await fetch(base + p)).json();
  await until(async () => (await fetch(base + "/v1/health")).ok, "the gateway");

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 }, acceptDownloads: true });
  const page = await ctx.newPage();
  const dialogs = [];
  page.on("dialog", d => { dialogs.push(d.message()); d.dismiss(); });
  page.on("pageerror", e => fail("page error: " + e.message));
  /* Which session each turn was sent under: the header the gateway saves
     and checkpoints by. */
  const sentUnder = new Map();   // question -> X-PasClaw-Session
  page.on("request", r => {
    if (!r.url().endsWith("/v1/chat/completions") || r.method() !== "POST") return;
    try {
      const msgs = JSON.parse(r.postData() || "{}").messages || [];
      sentUnder.set(lastUserText(msgs), r.headers()["x-pasclaw-session"] || "");
    } catch {}
  });

  const logText = () => page.textContent("#log");
  const button = () => page.textContent("#b");
  const send = async text => { await page.fill("#m", text); await page.press("#m", "Enter"); };
  const openChat = async title => {
    const li = page.locator("#session-list li", { hasText: title }).first();
    await li.waitFor({ timeout: 10000 });
    await li.click();
  };
  const sessionByTitle = async title => ((await api("/v1/sessions")).sessions || []).find(s => s.title === title);
  const saved = async id => ((await api("/v1/sessions/" + encodeURIComponent(id))).messages || [])
    .map(m => m.role + ":" + String(m.content || "").split("\n\n[current date/time")[0]);

  try {
    await page.goto(base + "/");
    await page.waitForSelector("#m");

    /* ---- two chats, each with a turn running ---- */
    await send("question A");
    await until(() => held.has("question A"), "the provider to be asked question A");
    if ((await button()).trim() !== "Stop") fail("while A runs the button reads " + (await button()));
    await until(async () => (await page.locator("#session-list li.running").count()) === 1, "chat A marked running in the list");

    await page.click("#session-new");
    if ((await button()).trim() !== "Send") fail("a new chat opened while A runs shows " + (await button()) + ", want Send");
    if (/question A/.test(await logText())) fail("the new chat shows chat A's transcript");
    await send("question B");
    await until(() => held.has("question B"), "the provider to be asked question B");
    await until(async () => (await page.locator("#session-list li.running").count()) === 2, "both chats marked running");
    ok("a second chat can be opened and asked while the first one's turn runs");

    await openChat("question A");
    await until(async () => /question A/.test(await logText()), "chat A's transcript");
    const aView = await logText();
    if (/question B/.test(aView)) fail("reopened chat A shows chat B's question: " + aView);
    if (!(await page.locator("#log .typing").count())) fail("reopened chat A does not show its turn still running");
    if ((await button()).trim() !== "Stop") fail("reopened chat A (running) shows " + (await button()) + ", want Stop");
    ok("chat A, reopened from the list, shows its own question and its turn still running");

    held.get("question B").release();
    const B = await until(async () => {
      const s = await sessionByTitle("question B");
      return s && (await saved(s.id)).some(x => x === "assistant:reply to question B streamed in pieces");
    }, "chat B's reply to be saved while A is open").then(() => sessionByTitle("question B"));
    await sleep(300);
    if (/reply to question B/.test(await logText())) fail("chat B's reply appeared in chat A");
    if (!(await page.locator("#log .typing").count())) fail("chat A lost its live bubble when B finished");
    await until(async () => (await page.locator("#session-list li.running").count()) === 1, "only chat A still marked running");
    ok("chat B's turn finished and was saved in the background, without touching the open chat A");

    held.get("question A").release();
    await until(async () => /reply to question A/.test(await logText()), "A's reply to stream into the open chat");
    await until(async () => (await button()).trim() === "Send", "the button back to Send");
    const A = await sessionByTitle("question A");
    await until(async () => (await saved(A.id)).length === 2, "chat A saved");
    const aSaved = await saved(A.id), bSaved = await saved(B.id);
    if (JSON.stringify(aSaved) !== JSON.stringify(["user:question A", "assistant:reply to question A streamed in pieces"]))
      fail("chat A saved as " + JSON.stringify(aSaved));
    if (JSON.stringify(bSaved) !== JSON.stringify(["user:question B", "assistant:reply to question B streamed in pieces"]))
      fail("chat B saved as " + JSON.stringify(bSaved));
    if (sentUnder.get("question A") !== A.id || sentUnder.get("question B") !== B.id)
      fail("turns sent under " + JSON.stringify([...sentUnder]) + ", want A=" + A.id + " B=" + B.id);
    ok("A's reply streamed into the open chat; each chat saved exactly its own question and reply, each turn sent under its own session");

    await openChat("question B");
    await until(async () => /reply to question B/.test(await logText()), "chat B's transcript");
    if (/question A/.test(await logText())) fail("chat B shows chat A's turns");
    ok("chat B, reopened, shows its own finished turn");

    /* ---- leaving a new chat while its session is still being made ---- */
    let releaseCreate;
    const createHeld = new Promise(r => releaseCreate = r);
    await page.route("**/v1/sessions", async route => {
      if (route.request().method() === "POST") await createHeld;
      await route.continue();
    });
    await page.click("#session-new");
    await send("question F");
    await sleep(300);                            // the create is held back
    await openChat("question B");                // ...and the operator moves on
    await until(async () => /reply to question B/.test(await logText()), "chat B open");
    releaseCreate();
    await until(() => held.has("question F"), "the provider to be asked question F");
    await page.unroute("**/v1/sessions");
    held.get("question F").release();
    const F = await until(async () => {
      const x = await sessionByTitle("question F");
      return x && (await saved(x.id)).length === 2;
    }, "chat F saved").then(() => sessionByTitle("question F"));
    if (sentUnder.get("question F") !== F.id)
      fail("question F was sent under " + JSON.stringify(sentUnder.get("question F")) + ", want its own id " + F.id);
    if (JSON.stringify(await saved(F.id)) !== JSON.stringify(["user:question F", "assistant:reply to question F streamed in pieces"]))
      fail("chat F saved as " + JSON.stringify(await saved(F.id)));
    if (/question F/.test(await logText())) fail("chat F's turn showed up in chat B");
    if (JSON.stringify(await saved(B.id)) !== JSON.stringify(bSaved)) fail("chat B changed: " + JSON.stringify(await saved(B.id)));
    await page.fill("#m", "");
    ok("a new chat left while its session was being made sent its own question under its own id; chat B was untouched");

    /* ---- Stop stops the open chat's turn only ---- */
    await page.click("#session-new");
    await send("question C");
    await until(() => held.has("question C"), "question C");
    await page.click("#session-new");
    await send("question D");
    await until(() => held.has("question D"), "question D");
    await page.click("#b");                      // Stop, in chat D
    await until(async () => (await button()).trim() === "Send", "D stopped");
    await until(async () => (await page.locator("#session-list li.running").count()) === 1, "only C still running");
    held.get("question C").release();
    await openChat("question C");
    await until(async () => /reply to question C/.test(await logText()), "C's reply after D was stopped");
    ok("Stop in one chat stopped that turn only; the other chat's turn finished");

    /* ---- deleting a chat whose turn is running ---- */
    await page.click("#session-new");
    await send("question E");
    await until(() => held.has("question E"), "question E");
    const E = await until(async () => await sessionByTitle("question E"), "chat E listed").then(() => sessionByTitle("question E"));
    await openChat("question B");
    const li = page.locator("#session-list li", { hasText: "question E" }).first();
    await li.hover();
    await li.locator(".del").click();
    await until(async () => !(await sessionByTitle("question E")), "chat E gone from the list");
    held.get("question E").release();
    await sleep(1500);
    if (await sessionByTitle("question E")) fail("chat E came back after it was deleted mid-turn");
    else ok("a chat deleted while its turn ran stayed deleted");
    void E;

    /* ---- the Files menu downloads what the agent wrote ---- */
    await page.click("#session-new");
    await send("please write the file");
    await until(async () => /the file is written/.test(await logText()), "the write_file turn");
    if (!fs.existsSync(path.join(ws, "out", "report.txt"))) fail("premise: the tool did not write out/report.txt in the workspace");
    await page.click("#chat-files-btn");
    const row = page.locator("#chat-files-menu .frow", { hasText: "report.txt" }).first();
    await row.waitFor({ timeout: 5000 });
    const before = dialogs.length;
    const [dl] = await Promise.all([page.waitForEvent("download", { timeout: 10000 }).catch(() => null), row.click()]);
    if (!dl) fail("clicking report.txt in the Files menu downloaded nothing" + (dialogs.length > before ? " -- the page said: " + dialogs[dialogs.length - 1] : ""));
    else {
      const got = fs.readFileSync(await dl.path(), "utf8");
      if (got !== "the report body\n") fail("the download held " + JSON.stringify(got));
      else ok("the Files menu downloaded out/report.txt, written with a relative path");
    }
  } catch (e) {
    fail(e.message);
  } finally {
    await browser.close().catch(() => {});
    gw.kill("SIGINT");
    await sleep(500);
    provider.close();
    try { fs.rmSync(home, { recursive: true, force: true }); } catch {}
  }
  if (failures) {
    console.log("---- gateway log (tail) ----\n" + gwLog.split("\n").slice(-15).join("\n"));
    console.log(failures + " failure(s)");
    process.exit(1);
  }
  console.log("webui sessions e2e: all checks passed");
  process.exit(0);
})();
