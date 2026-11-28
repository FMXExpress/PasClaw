#!/usr/bin/env node
/* The web UI's Chat page: what its visual pass added must keep working.

   Against the real binary, with a fake OpenAI-compatible provider in this
   script, driven through headless Chromium:

     - an empty chat shows the welcome (what the page is for, the keys);
       the first message puts it away;
     - a markdown table in a reply is drawn as a table: header cells,
       column alignment from the delimiter row, and HTML in a cell drawn
       as text, never as markup;
     - a code block's Copy button puts the code on the clipboard and says
       "Copied", keeping its icon;
     - a failed tool call is marked "failed" on its card;
     - a finished reply, redrawn as markdown, ends in view: the redraw
       used to scroll to each row before filling it, leaving the last
       reply below the fold;
     - Send turns into Stop (a different-looking button) while a reply runs;
     - a reply streaming in does not pull a reader who scrolled up back to
       the bottom; a "Latest" button appears instead, and takes them down.

   Needs node with Playwright and a Chromium; skips when Playwright is not
   installed. usage: node webui_chat_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_chat_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

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
const CODE = "begin\n  WriteLn('<hi>');\nend.";
const TABLE_REPLY = [
  "Compared:",
  "",
  "| Name | Score | Note |",
  "|:---|---:|:---:|",
  "| alpha | 10 | <b>bold?</b> |",
  "| beta | 2 | plain |",
  "",
  "```pascal", CODE, "```",
].join("\n");
let slowGo = false;           // the slow reply streams only once released
function lastUserText(msgs) {
  for (let i = msgs.length - 1; i >= 0; i--)
    if (msgs[i].role === "user") {
      const c = msgs[i].content;
      const t = Array.isArray(c) ? c.map(p => p.text || "").join(" ") : (c || "");
      return t.split("\n\n[current date/time")[0].trim();
    }
  return "";
}
function reply(res, stream, message, finish, pieces, gap) {
  if (!stream) {
    const out = JSON.stringify({ id: "c", object: "chat.completion", model: "m",
      choices: [{ index: 0, finish_reason: finish, message }], usage: { prompt_tokens: 3, completion_tokens: 3 } });
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(out);
  }
  res.writeHead(200, { "content-type": "text/event-stream" });
  const frame = o => res.write("data: " + JSON.stringify(o) + "\n\n");
  const end = () => {
    frame({ choices: [{ index: 0, delta: {}, finish_reason: finish }] });
    frame({ choices: [], usage: { prompt_tokens: 3, completion_tokens: 3 } });
    res.end("data: [DONE]\n\n");
  };
  if (message.tool_calls) {
    frame({ choices: [{ index: 0, delta: { role: "assistant", tool_calls: message.tool_calls.map((t, i) => Object.assign({ index: i }, t)) } }] });
    return end();
  }
  const parts = pieces || [message.content];
  let i = 0;
  const tick = () => {
    if (res.destroyed) return;
    if (i < parts.length) { frame({ choices: [{ index: 0, delta: { content: parts[i++] } }] }); setTimeout(tick, gap || 0); return; }
    end();
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
    if (last.role === "tool") return reply(res, body.stream, { role: "assistant", content: "looked" }, "stop");
    if (q === "table please") return reply(res, body.stream, { role: "assistant", content: TABLE_REPLY }, "stop");
    if (q === "fail a tool")
      return reply(res, body.stream, { role: "assistant", content: null, tool_calls: [{ id: "r1", type: "function",
        function: { name: "read_file", arguments: JSON.stringify({ path: "no-such-file.txt" }) } }] }, "tool_calls");
    if (q === "slow reply") {
      const wait = () => {
        if (res.destroyed) return;
        if (!slowGo) return setTimeout(wait, 30);
        const lines = Array.from({ length: 40 }, (_, k) => "streamed line " + k + "\n\n");
        reply(res, body.stream, { role: "assistant", content: lines.join("") }, "stop", lines, 40);
      };
      return wait();
    }
    reply(res, body.stream, { role: "assistant", content: "answer to " + q + "\n\n" + "a paragraph of filler text. ".repeat(12) }, "stop");
  });
});

function freePort() {
  return new Promise(r => { const s = http.createServer().listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => r(p)); }); });
}

(async () => {
  const pport = await freePort(), gport = await freePort();
  await new Promise(r => provider.listen(pport, "127.0.0.1", r));
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-chat-e2e-"));
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
  await until(async () => (await fetch(base + "/v1/health")).ok, "the gateway");

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 }, colorScheme: "dark",
                                         permissions: ["clipboard-read", "clipboard-write"] });
  const page = await ctx.newPage();
  page.on("pageerror", e => fail("page error: " + e.message));
  page.on("dialog", d => d.dismiss());
  const button = async () => (await page.textContent("#b")).trim();
  const send = async (text, wait = true) => {
    await page.fill("#m", text); await page.press("#m", "Enter");
    if (wait) { await sleep(150); await until(async () => (await button()) === "Send", "the reply to " + text); }
  };
  const visible = sel => page.locator(sel).isVisible();

  try {
    await page.goto(base + "/");
    await page.waitForSelector("#m");

    /* ---- the empty chat ---- */
    if (!(await visible("#chat-empty"))) fail("an empty chat shows no welcome");
    else if (!/Enter/.test(await page.textContent("#chat-empty"))) fail("the welcome does not name the keys");
    else ok("an empty chat shows the welcome");

    /* ---- a table, a code block ---- */
    await send("table please");
    if (await visible("#chat-empty")) fail("the welcome is still drawn over a conversation");
    const t = await page.evaluate(() => {
      const tb = document.querySelector("#log .md table");
      if (!tb) return null;
      return {
        th: [...tb.querySelectorAll("thead th")].map(c => c.textContent),
        align: [...tb.querySelectorAll("thead th")].map(c => getComputedStyle(c).textAlign),
        rows: tb.querySelectorAll("tbody tr").length,
        cell: tb.querySelector("tbody tr td:nth-child(3)").textContent,
        markup: !!tb.querySelector("tbody b"),
      };
    });
    if (!t) fail("a markdown table in a reply is not drawn as a table");
    else {
      if (t.th.join("|") !== "Name|Score|Note") fail("table header: " + t.th.join("|"));
      if (t.align.join("|") !== "left|right|center") fail("table alignment: " + t.align.join("|"));
      if (t.rows !== 2) fail("table rows: " + t.rows);
      if (t.markup || t.cell !== "<b>bold?</b>") fail("HTML in a table cell is not drawn as text: " + t.cell);
      if (!t.markup && t.rows === 2 && t.th.length === 3) ok("a markdown table is drawn as a table, its cells as text");
    }
    const copyBtn = page.locator("#log .code-wrap .copy-btn").first();
    await copyBtn.click();
    await until(async () => /Copied/.test(await copyBtn.textContent()), "Copied on the code block's button", 3000).catch(() => {});
    const clip = await page.evaluate(() => navigator.clipboard.readText());
    if (clip !== CODE) fail("the code block's Copy put this on the clipboard: " + JSON.stringify(clip));
    else if (!/Copied/.test(await copyBtn.textContent())) fail("the Copy button does not say Copied");
    else if (!(await copyBtn.locator("svg").count())) fail("the Copy button lost its icon");
    else ok("a code block's Copy copies the code and says Copied");

    /* ---- a failed tool call ---- */
    await page.click("#session-new");
    await send("fail a tool");
    const card = page.locator("#log details.tool-card.err").first();
    if (!(await card.count())) fail("the failed tool call has no error card");
    else if (!/failed/i.test(await card.locator("summary").textContent())) fail("the failed card does not say so");
    else ok("a failed tool call is marked failed on its card");

    /* ---- scrolling while a reply streams ---- */
    await page.click("#session-new");
    for (let k = 1; k <= 6; k++) await send("question " + k);
    await sleep(200);
    const gap = await page.evaluate(() => { const l = document.getElementById("log");
      return Math.round(l.scrollHeight - l.scrollTop - l.clientHeight); });
    if (gap > 2) fail("after the reply is redrawn the transcript stops " + gap + "px short of its end");
    else ok("a finished reply is redrawn with its last line in view");
    slowGo = false;
    await send("slow reply", false);
    await until(async () => (await button()) === "Stop", "Stop while the reply runs");
    if (!(await page.locator("#b.chat-stop").count())) fail("Stop looks the same as Send");
    else ok("Send turns into a distinct Stop while a reply runs");
    await page.evaluate(() => { document.getElementById("log").scrollTop = 0; });
    await until(() => visible("#chat-jump"), "the Latest button after scrolling up", 3000)
      .catch(() => fail("no Latest button after scrolling up"));
    slowGo = true;
    await until(async () => /streamed line 39/.test(await page.textContent("#log")), "the slow reply", 20000);
    const top = await page.evaluate(() => document.getElementById("log").scrollTop);
    if (top > 5) fail("a streaming reply pulled the reader down to " + top + "px");
    else ok("a streaming reply leaves a reader who scrolled up where they are");
    if (await visible("#chat-jump")) {
      await page.click("#chat-jump");
      await until(() => page.evaluate(() => { const l = document.getElementById("log");
        return l.scrollHeight - l.scrollTop - l.clientHeight < 80; }), "the bottom after Latest", 5000)
        .catch(() => fail("Latest did not scroll to the newest message"));
      await until(async () => !(await visible("#chat-jump")), "Latest hidden at the bottom", 3000)
        .catch(() => fail("Latest is still shown at the bottom"));
      ok("Latest takes the reader to the newest message");
    }
    await until(async () => (await button()) === "Send", "Send after the reply");
  } catch (e) {
    fail(String(e && e.stack || e));
  } finally {
    await browser.close().catch(() => {});
    gw.kill();
    provider.close();
    if (failures) console.log(gwLog.slice(-3000));
    fs.rmSync(home, { recursive: true, force: true });
  }
  if (failures) { console.log("webui_chat_e2e: " + failures + " failure(s)"); process.exit(1); }
  console.log("ok - web UI chat page tests passed");
  process.exit(0);
})();
