#!/usr/bin/env node
/* The web UI's Background tab, against the real gateway.

   A fake OpenAI-compatible provider in this script plays both the chat
   model and the subagent: "BG <task>" makes the chat model call
   spawn_background, "SH <cmd>" shell_background; a subagent task whose
   first word is HOLD-n waits until the test lets it go, then calls
   list_dir once and answers "answer for HOLD-n"; a follow-up ("FOLLOW ...")
   answers at once. Through headless Chromium:

     - before any job the tab shows an empty state naming the spawn tools;
     - a job started from the chat puts a running count on the tab button
       as soon as that turn ends, without opening the tab;
     - the tab lists it under Running with a status chip; opened, it shows
       the task as the chat shows a message, a typing indicator and Stop;
     - when it finishes it moves to Finished, the transcript draws its tool
       call as the chat's tool card and its answer, and the count goes;
     - a follow-up typed in the message box opens the new job, linked to
       the old one, which answers;
     - Stop on a running subagent says when it stops, then it reads
       cancelled; a shell job shows its output and exit code;
     - the list refreshes about every 2 s while the tab is open, and not at
       all while the page is hidden;
     - light theme: the chips take the light tokens; phone width: no
       sideways scroll, the open job replaces the list and Back returns.

   Needs node with Playwright and a Chromium; skips without them.
   BG_SHOTS=<dir> also writes dark, light and phone screenshots there.
   usage: node webui_background_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_background_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const shots = process.env.BG_SHOTS || "";

let failures = 0, gwLog = "";
const fail = msg => { console.log("FAIL: " + msg); failures++; throw new Error(msg); };
const ok = msg => console.log("  ok: " + msg);
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, what, ms = 15000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch {} await sleep(50); }
  fail("timed out waiting for " + what);
}

/* ---------------------------------------------------------------- provider */
const holds = new Map();       // "HOLD-1" -> released?
const subCalls = new Map();    // tag -> model calls made by that subagent
const text = m => { const c = (m && m.content) || ""; return Array.isArray(c) ? c.map(p => p.text || "").join(" ") : c; };
const clean = t => String(t).split("\n\n[current date/time")[0].trim();
function call(id, name, args) { return { id, type: "function", function: { name, arguments: JSON.stringify(args) } }; }
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
const provider = http.createServer((req, res) => {
  let raw = "";
  req.on("data", c => raw += c);
  req.on("end", () => {
    const body = JSON.parse(raw || "{}");
    const msgs = body.messages || [];
    const last = msgs[msgs.length - 1] || {};
    const system = msgs.filter(m => m.role === "system").map(text).join(" ");
    if (system.includes("focused sub-agent")) {
      const users = msgs.filter(m => m.role === "user").map(m => clean(text(m)));
      const latest = users[users.length - 1] || "", tag = (users[0] || "").split(" ")[0];
      if (latest.startsWith("FOLLOW")) return sendReply(res, body.stream, { role: "assistant", content: "follow-up answer for " + tag }, "stop");
      subCalls.set(tag, (subCalls.get(tag) || 0) + 1);
      if (last.role === "tool") return sendReply(res, body.stream, { role: "assistant", content: "answer for " + tag }, "stop");
      const go = () => sendReply(res, body.stream, { role: "assistant", content: "Looking around first.",
        tool_calls: [call("s1", "list_dir", { path: "." })] }, "tool_calls");
      if (!holds.has(tag)) return go();
      const wait = () => { if (res.destroyed) return; if (holds.get(tag)) return go(); setTimeout(wait, 30); };
      return wait();
    }
    if (last.role === "tool") return sendReply(res, body.stream, { role: "assistant", content: "Started it in the background." }, "stop");
    const q = clean(text(last)), verb = q.split(" ")[0], rest = q.slice(verb.length + 1);
    if (verb === "BG") return sendReply(res, body.stream, { role: "assistant", content: null,
      tool_calls: [call("p1", "spawn_background", { agent: "general-purpose", prompt: rest })] }, "tool_calls");
    if (verb === "SH") return sendReply(res, body.stream, { role: "assistant", content: null,
      tool_calls: [call("p1", "shell_background", { command: rest })] }, "tool_calls");
    sendReply(res, body.stream, { role: "assistant", content: "hello" }, "stop");
  });
});

function freePort() {
  return new Promise(r => { const s = http.createServer().listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => r(p)); }); });
}

(async () => {
  const pport = await freePort(), gport = await freePort();
  await new Promise(r => provider.listen(pport, "127.0.0.1", r));
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-bg-e2e-"));
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify({
    providers: [{ name: "fake", kind: "openai", api_base: `http://127.0.0.1:${pport}/v1`, api_key: "sk-test", model: "m" }],
    default_provider: "fake", default_model: "m", gateway: { port: gport, bind_addr: "127.0.0.1" } }));
  const gw = spawn(binary, ["gateway", "--port", String(gport), "--addr", "127.0.0.1", "--no-mcp"],
                   { cwd: home, env: Object.assign({}, process.env, { PASCLAW_HOME: home }), stdio: ["ignore", "pipe", "pipe"] });
  gw.stdout.on("data", d => gwLog += d); gw.stderr.on("data", d => gwLog += d);
  const base = `http://127.0.0.1:${gport}`;
  const chatApi = async message => (await fetch(base + "/v1/chat", { method: "POST",
    headers: { "content-type": "application/json" }, body: JSON.stringify({ message }) })).json();
  await until(async () => (await fetch(base + "/v1/health")).ok, "the gateway");

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 }, colorScheme: "dark" });
  const page = await ctx.newPage();
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  page.on("dialog", d => d.dismiss());
  let bgRequests = 0;
  page.on("request", r => { if (/\/v1\/background$/.test(r.url())) bgRequests++; });
  const shot = async name => { if (shots) await page.screenshot({ path: path.join(shots, name) }); };
  const badge = async () => page.evaluate(() => { const b = document.getElementById("bg-badge"); return b.hidden ? "" : b.textContent; });
  const openTab = async name => { await page.click(`nav button[data-tab="${name}"]`); };
  const item = h => page.locator(`#bg-list .bg-item[data-h="${h}"]`);
  const jobs = async () => (await (await fetch(base + "/v1/background")).json()).jobs;

  try {
    await page.goto(base + "/");
    await page.waitForSelector("#m");

    /* ---- empty state ---- */
    await openTab("background");
    await until(async () => /No background jobs yet/.test(await page.textContent("#bg-list")), "the empty state");
    const empty = await page.textContent("#bg-list");
    if (!/spawn_background/.test(empty) || !/shell_background/.test(empty)) fail("the empty state does not say how jobs start: " + empty);
    if (await badge()) fail("a badge with nothing running");
    ok("the empty state says how jobs get started");

    /* ---- a job from the chat: the count reaches the tab button ---- */
    /* A fresh page that never opened the tab: with nothing running its idle
       poll is 15 s away, so a count inside 6 s comes from the end of the
       turn, not from the timer. */
    holds.set("HOLD-1", false);
    await page.goto(base + "/?fresh#chat");
    await page.waitForSelector("#m");
    await sleep(500);
    const sentAt = Date.now();
    await page.fill("#m", "BG HOLD-1 research the frobnicator");
    await page.press("#m", "Enter");
    await until(async () => (await badge()) === "1", "the running count on the tab after the turn", 6000);
    ok("the chat turn that started a job puts a running count on the tab (" + (Date.now() - sentAt) + " ms)");

    await openTab("background");
    const h1 = (await jobs())[0].handle;
    await item(h1).waitFor();
    if (!/Running\s*1/.test(await page.textContent("#bg-list"))) fail("the job is not under Running");
    if ((await item(h1).locator(".bg-chip").textContent()).trim() !== "running") fail("no running chip");
    await item(h1).click();
    await until(async () => /HOLD-1 research the frobnicator/.test(await page.textContent("#bg-detail")), "the task in the detail");
    if (!(await page.locator("#bg-detail .row.u .bub").count())) fail("the task is not drawn as a chat message");
    if (!(await page.locator("#bg-detail .typing").count())) fail("no typing indicator while it runs");
    if (!(await page.locator("#bg-stop").count())) fail("no Stop button for a running job");
    const chatLink = page.locator("#bg-detail .bg-dmeta a[data-chat]");
    if (!(await chatLink.count()) || !/HOLD-1 research/.test(await chatLink.textContent()))
      fail("the detail does not link the chat it was started in: " + (await page.textContent("#bg-detail .bg-dmeta")));
    await shot("web-ui-background-running.png");
    ok("a running job is listed under Running and opens with its task, a typing indicator and Stop");

    /* ---- the 2 s pace while the tab is open; none while the page is hidden ---- */
    let n0 = bgRequests;
    await sleep(4500);
    if (bgRequests - n0 < 2) fail("the open tab refreshed " + (bgRequests - n0) + " times in 4.5 s");
    await page.evaluate(() => { Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
                                document.dispatchEvent(new Event("visibilitychange")); });
    n0 = bgRequests;
    await sleep(4500);
    if (bgRequests !== n0) fail("the hidden page kept polling: " + (bgRequests - n0) + " requests");
    await page.evaluate(() => { Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
                                document.dispatchEvent(new Event("visibilitychange")); });
    await until(async () => bgRequests > n0, "a refresh when the page shows again", 3000);
    ok("refreshes about every 2 s while open, none while the page is hidden");

    /* ---- it finishes ---- */
    holds.set("HOLD-1", true);
    await until(async () => (await page.locator("#bg-detail .bg-chip.done").count()) === 1, "the done chip", 10000);
    await until(async () => /answer for HOLD-1/.test(await page.textContent("#bg-detail")), "the answer");
    if (!(await page.locator("#bg-detail details.tool-card").count())) fail("the tool call is not drawn as a tool card");
    if (!/list_dir/.test(await page.textContent("#bg-detail details.tool-card summary"))) fail("the tool card does not name list_dir");
    if (!(await page.locator("#bg-msg-text").count())) fail("no message box for a finished subagent");
    if (await page.locator("#bg-stop").count()) fail("Stop still shown for a finished job");
    await until(async () => /Finished\s*1/.test(await page.textContent("#bg-list")), "the job under Finished");
    await until(async () => (await badge()) === "", "the count going away");
    await shot("web-ui-background.png");
    ok("finished: moves to Finished, transcript with the chat's tool card and the answer, count gone");

    /* ---- a follow-up ---- */
    await page.fill("#bg-msg-text", "FOLLOW tell me more");
    await page.press("#bg-msg-text", "Enter");
    await until(async () => (await page.textContent("#bg-detail .bg-h")) !== h1, "the new job opening");
    const h2 = (await page.textContent("#bg-detail .bg-h")).trim();
    await until(async () => (await page.locator(`#bg-detail a[data-job="${h1}"]`).count()) === 1, "the link to the old job");
    await until(async () => /follow-up answer for HOLD-1/.test(await page.textContent("#bg-detail")), "the follow-up's answer", 10000);
    if (!/HOLD-1 research the frobnicator/.test(await page.textContent("#bg-detail"))) fail("the follow-up does not show the earlier conversation");
    ok("a follow-up opens the new job " + h2 + ", linked to " + h1 + ", which answers");

    /* ---- Stop a running subagent; a shell job's output ---- */
    holds.set("HOLD-2", false);
    await chatApi("BG HOLD-2 a long survey");
    await until(async () => (subCalls.get("HOLD-2") || 0) >= 1, "the second subagent's model call");
    const h3 = (await jobs()).find(j => j.state === "running").handle;
    await item(h3).waitFor({ timeout: 5000 });
    await item(h3).click();
    await page.waitForSelector("#bg-stop");
    await page.click("#bg-stop");
    await until(async () => /next step/.test(await page.textContent("#bg-detail .bg-note")), "the advisory note");
    await until(async () => (await page.locator("#bg-detail .bg-chip.stopping").count()) === 1, "the stopping chip");
    holds.set("HOLD-2", true);
    await until(async () => (await page.locator("#bg-detail .bg-chip.cancelled").count()) === 1, "the cancelled chip", 10000);
    ok("Stop says the subagent stops at its next step, then it reads cancelled");

    await chatApi("SH echo hi-from-the-shell");
    const hs = await (async () => { let h; await until(async () => { const j = (await jobs()).find(x => x.kind === "shell"); h = j && j.handle; return !!h; }, "the shell job"); return h; })();
    await item(hs).waitFor({ timeout: 5000 });
    await item(hs).click();
    await until(async () => /hi-from-the-shell/.test(await page.textContent("#bg-detail .bg-output")), "the shell output");
    await until(async () => /Exit code 0/.test(await page.textContent("#bg-detail")), "the exit code");
    if (await page.locator("#bg-msg-text").count()) fail("a message box for a shell job");
    ok("a shell job shows its command, output and exit code, and takes no message");

    /* A running shell job past 64 KB: the server sends a fixed-size tail, so
       the output's length stops changing while its content does. The open
       view must keep following it (it used to freeze on its first render). */
    await chatApi("SH head -c 70000 /dev/zero | tr '\\0' x; echo; seq 1 40 | while read i; do echo tick-$i; sleep 0.25; done");
    const ht = await (async () => { let h; await until(async () => { const j = (await jobs()).find(x => x.kind === "shell" && x.handle !== hs); h = j && j.handle; return !!h; }, "the long shell job"); return h; })();
    await item(ht).waitFor({ timeout: 5000 });
    await item(ht).click();
    await until(async () => /tick-\d+/.test(await page.textContent("#bg-detail .bg-output")), "the first ticks");
    const firstTick = Math.max(...((await page.textContent("#bg-detail .bg-output")).match(/tick-(\d+)/g) || ["tick-0"]).map(t => +t.slice(5)));
    await until(async () => {
      const ticks = ((await page.textContent("#bg-detail .bg-output")).match(/tick-(\d+)/g) || []).map(t => +t.slice(5));
      return ticks.length && Math.max(...ticks) >= firstTick + 8;
    }, "later ticks: the open view stopped following a shell job's output past 64 KB (stuck after tick-" + firstTick + ")", 9000);
    ok("a running shell job past 64 KB keeps updating in the open view");

    /* ---- light theme ---- */
    await item(h1).click();
    await page.waitForSelector("#bg-detail .bg-chip.done");
    const dark = await page.evaluate(() => getComputedStyle(document.querySelector("#bg-detail .bg-chip.done")).color);
    await page.click("#theme-btn");
    const lite = await page.evaluate(() => [document.documentElement.classList.contains("lite"),
      getComputedStyle(document.querySelector("#bg-detail .bg-chip.done")).color,
      getComputedStyle(document.body).backgroundColor]);
    if (!lite[0]) fail("the theme button did not switch to light");
    if (lite[1] !== "rgb(19, 108, 55)" || dark === lite[1]) fail("the done chip does not take the light ok token: " + dark + " / " + lite[1]);
    await shot("web-ui-background-light.png");
    await page.click("#theme-btn");
    ok("light theme: the chips follow the tokens");

    /* ---- phone width ---- */
    await page.setViewportSize({ width: 390, height: 844 });
    await page.click("#bg-detail .bg-back");
    const wide = await page.evaluate(() => [document.documentElement.scrollWidth, document.body.scrollWidth,
      getComputedStyle(document.querySelector("#bg-detail")).display, getComputedStyle(document.querySelector("#tab-background .bg-list")).display]);
    if (wide[0] > 390 || wide[1] > 390) fail("sideways scroll at phone width: " + wide);
    if (wide[2] !== "none" || wide[3] === "none") fail("at phone width the list should show alone: " + wide);
    await item(h1).click();
    await page.waitForSelector("#bg-detail .bg-back", { state: "visible" });
    const open = await page.evaluate(() => [document.documentElement.scrollWidth,
      getComputedStyle(document.querySelector("#tab-background .bg-list")).display]);
    if (open[0] > 390 || open[1] !== "none") fail("an open job at phone width: " + open);
    await shot("web-ui-background-phone.png");
    await page.click("#bg-detail .bg-back");
    await until(async () => (await page.evaluate(() => getComputedStyle(document.querySelector("#tab-background .bg-list")).display)) !== "none", "Back to the list");
    ok("phone width: no sideways scroll, the open job replaces the list, Back returns");

    if (failures) throw new Error(failures + " failure(s)");
    console.log("webui_background_e2e: OK");
  } catch (e) {
    if (!failures) console.log("FAIL: " + e.message);
    console.log("---- gateway log (tail) ----\n" + gwLog.split("\n").slice(-25).join("\n"));
    process.exitCode = 1;
  } finally {
    for (const k of holds.keys()) holds.set(k, true);
    await browser.close();
    gw.kill();
    provider.close();
    fs.rmSync(home, { recursive: true, force: true });
  }
})();
