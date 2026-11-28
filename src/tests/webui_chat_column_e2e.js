#!/usr/bin/env node
/* The web UI's Chat tab right column, against the real gateway.

   A fake OpenAI-compatible provider in this script records each chat
   request and plays both the chat model and the subagent: "BG <task>"
   makes the chat model call spawn_background; a subagent task whose first
   word is HOLD-n waits until the test lets it go, then answers. A Desktop
   project "demo-app" with an html app (one that keeps a value through its
   pasclaw.js state store) and its project chat (session desktop-demo-app,
   filed the way the desktop files it) are set up through the gateway's
   own routes. Through headless Chromium:

     - the column opens and closes from its button and Ctrl+., and a reload
       keeps it the way it was left; a folded pane stays folded;
     - Parameters opens the column on its pane, and what is typed there
       reaches the next chat request (system prompt, temperature, max
       tokens);
     - the context button opens the column on the Context pane, which
       shows what POST /v1/context answers for the chat's own request
       body; the button keeps its "6k · 7.5%" summary;
     - a background job started in this chat appears in the Background
       pane, runs, and finishes there; a job of another chat does not;
       a job opens on the Background tab; a new chat says "No background
       work in this chat";
     - the Desktop project chat shows its app, framed from /apps/demo-app/
       with the desktop's sandbox (no allow-same-origin), and the app's
       state store answers through the column; a plain chat has no App
       pane;
     - at 1280 px both columns fit beside the transcript; at 1024 px
       opening the right column puts the chat list away until it closes;
     - at phone width the column is a drawer over the transcript, with no
       sideways scroll, and a tap beside it puts it away.

   Needs node with Playwright and a Chromium; skips without them.
   RC_SHOTS=<dir> also writes screenshots there (dark and light with every
   pane, the app pane, phone).
   usage: node webui_chat_column_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_chat_column_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const shots = process.env.RC_SHOTS || "";

let failures = 0, gwLog = "";
const fail = msg => { console.log("FAIL: " + msg); failures++; };
const ok = msg => console.log("  ok: " + msg);
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, what, ms = 15000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch {} await sleep(50); }
  throw new Error("timed out waiting for " + what);
}
function check(cond, good, bad) { if (cond) ok(good); else fail(bad); return !!cond; }

/* ---------------------------------------------------------------- provider */
const holds = new Map();       // "HOLD-1" -> released?
const chatBodies = [];         // every chat-model request body, newest last
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
      const tag = (users[0] || "").split(" ")[0];
      const go = () => sendReply(res, body.stream, { role: "assistant", content: "answer for " + tag }, "stop");
      if (!holds.has(tag)) return go();
      const wait = () => { if (res.destroyed) return; if (holds.get(tag)) return go(); setTimeout(wait, 30); };
      return wait();
    }
    chatBodies.push(body);
    if (last.role === "tool") return sendReply(res, body.stream, { role: "assistant", content: "Started it in the background." }, "stop");
    const q = clean(text(last)), verb = q.split(" ")[0], rest = q.slice(verb.length + 1);
    if (verb === "BG") return sendReply(res, body.stream, { role: "assistant", content: null,
      tool_calls: [call("p1", "spawn_background", { agent: "general-purpose", prompt: rest })] }, "tool_calls");
    sendReply(res, body.stream, { role: "assistant", content: "answer to " + q }, "stop");
  });
});

function freePort() {
  return new Promise(r => { const s = http.createServer().listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => r(p)); }); });
}

/* An html app that keeps a value through the SDK's state store: framed,
   the SDK asks its parent (the column) rather than fetching. */
const APP_HTML = `<!doctype html><html><head><meta charset="utf-8"><title>Demo</title>
<script src="pasclaw.js"></script></head><body style="font:14px sans-serif;padding:12px">
<h1 style="font-size:18px;margin:0 0 6px">Demo app</h1><p id="out">loading</p>
<script>
pasclaw.set("greeting", "hello from the state store")
  .then(function () { return pasclaw.get("greeting"); })
  .then(function (v) { document.getElementById("out").textContent = "state: " + v; },
        function (e) { document.getElementById("out").textContent = "error: " + e.message; });
</script></body></html>`;

(async () => {
  const pport = await freePort(), gport = await freePort();
  await new Promise(r => provider.listen(pport, "127.0.0.1", r));
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-rc-e2e-"));
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify({
    providers: [{ name: "fake", kind: "openai", api_base: `http://127.0.0.1:${pport}/v1`, api_key: "sk-test", model: "m" }],
    default_provider: "fake", default_model: "m", context_window: 64000,
    gateway: { port: gport, bind_addr: "127.0.0.1" } }));
  const gw = spawn(binary, ["gateway", "--port", String(gport), "--addr", "127.0.0.1", "--no-mcp"],
                   { cwd: home, env: Object.assign({}, process.env, { PASCLAW_HOME: home }), stdio: ["ignore", "pipe", "pipe"] });
  gw.stdout.on("data", d => gwLog += d); gw.stderr.on("data", d => gwLog += d);
  const base = `http://127.0.0.1:${gport}`;
  const api = async (p, opts) => {
    const r = await fetch(base + p, opts);
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(p + ": http " + r.status + " " + JSON.stringify(j));
    return j;
  };
  const post = (p, body, headers) => api(p, { method: "POST",
    headers: Object.assign({ "content-type": "application/json" }, headers || {}), body: JSON.stringify(body) });
  await until(async () => (await fetch(base + "/v1/health")).ok, "the gateway");

  /* ---- a Desktop project with an html app, and its project chat ---- */
  const proj = await post("/v1/projects", { title: "Demo App", name: "demo-app" });
  if (proj.name !== "demo-app") throw new Error("project slug: " + proj.name);
  const appDir = [path.join(home, "workspace", "projects", "demo-app", "app")]
    .find(d => fs.existsSync(path.dirname(d)));
  if (!appDir) throw new Error("the project directory is not under " + path.join(home, "workspace", "projects"));
  fs.mkdirSync(appDir, { recursive: true });
  fs.writeFileSync(path.join(appDir, "app.json"), JSON.stringify({ name: "Demo App", kind: "html", entry: "index.html" }));
  fs.writeFileSync(path.join(appDir, "index.html"), APP_HTML);
  const appInfo = await api("/v1/apps/demo-app");
  if (!appInfo.exists || !appInfo.servable) throw new Error("the demo app is not servable: " + JSON.stringify(appInfo));
  /* The desktop files a project's conversation as desktop-<slug>. */
  await post("/v1/chat/completions", { messages: [{ role: "user", content: "make me an app" }],
    session_context: true, session_title: "Desktop: demo-app" }, { "X-PasClaw-Session": "desktop-demo-app" });

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 }, colorScheme: "dark" });
  const page = await ctx.newPage();
  page.on("pageerror", e => fail("page error: " + e.message));
  page.on("dialog", d => d.dismiss());
  const button = async () => (await page.textContent("#b")).trim();
  const send = async q => {
    await page.fill("#m", q); await page.press("#m", "Enter");
    await sleep(150); await until(async () => (await button()) === "Send", "the reply to " + q);
  };
  const colOpen = () => page.evaluate(() => !document.querySelector("#rc-col").classList.contains("collapsed")
                                            && document.querySelector("#rc-col").getBoundingClientRect().width > 0);
  const openChat = async title => {
    await page.locator("#session-list li", { hasText: title }).first().click();
    await until(async () => !(await page.evaluate(() => document.querySelector("#log").dataset.loading)), "chat " + title + " to load");
  };

  try {
    await page.goto(base + "/");
    await page.waitForSelector("#m");
    /* The page opens the newest chat, the project's: start a plain one. */
    await page.click("#session-new");

    /* ---- open, close, remembered ---- */
    check(!(await colOpen()), "the column starts closed", "the column is open on a first visit");
    check(!(await page.locator("#chat-params").isVisible()) && !(await page.locator("#ctx-panel").isVisible()),
      "no popdown sits under the toolbar", "a parameters or context panel shows with the column closed");
    await page.click("#rc-toggle");
    check(await colOpen(), "the toolbar button opens the column", "the toolbar button did not open the column");
    check((await page.getAttribute("#rc-toggle", "aria-expanded")) === "true" &&
          (await page.evaluate(() => document.querySelector("#rc-toggle").classList.contains("on"))),
      "the button says the column is open", "the column button's state does not follow the column");
    const panes = await page.evaluate(() => [...document.querySelectorAll("#rc-panes .rc-pane")]
      .filter(s => !s.hidden).map(s => s.dataset.pane));
    check(panes.join(",") === "background,context,params", "a plain chat's panes: Background, Context, Parameters",
      "panes shown for a plain chat: " + panes.join(","));
    await page.reload(); await page.waitForSelector("#m");
    check(await colOpen(), "a reload keeps the column open", "the column did not stay open across a reload");
    await page.click("#rc-close");
    check(!(await colOpen()), "the close button closes it", "the close button did not close the column");
    await page.reload(); await page.waitForSelector("#m");
    check(!(await colOpen()), "a reload keeps it closed", "the column came back open after it was closed");
    await page.focus("#m");
    await page.keyboard.press("Control+.");
    check(await colOpen(), "Ctrl+. opens it", "Ctrl+. did not open the column");
    await page.keyboard.press("Control+.");
    check(!(await colOpen()), "Ctrl+. closes it again", "Ctrl+. did not close the column");
    /* A folded pane stays folded. */
    await page.click("#rc-toggle");
    await page.click("#rc-pane-params .rc-pane-btn");
    await page.reload(); await page.waitForSelector("#m");
    const folded = await page.evaluate(() => ({
      exp: document.querySelector("#rc-pane-params .rc-pane-btn").getAttribute("aria-expanded"),
      hid: document.querySelector("#rc-body-params").hidden }));
    check(folded.exp === "false" && folded.hid, "a folded pane is remembered across a reload",
      "the folded Parameters pane came back unfolded: " + JSON.stringify(folded));
    await page.click("#rc-close");

    /* ---- Parameters ---- */
    await page.click("#session-new");
    await page.click("#params-toggle");
    await until(() => page.locator("#p-temp").isVisible(), "the Parameters pane");
    check(await colOpen(), "Parameters opens the column", "Parameters did not open the column");
    check(await page.evaluate(() => document.querySelector("#params-toggle").classList.contains("on")),
      "the Parameters button reads as on", "the Parameters button is not marked on");
    await until(async () => page.evaluate(() => {
      const s = document.querySelector("#rc-pane-params").getBoundingClientRect(),
            b = document.querySelector("#rc-panes").getBoundingClientRect();
      return s.top >= b.top - 2 && s.top < b.bottom - 40;
    }), "the Parameters pane scrolled into view", 3000).then(() => ok("the Parameters pane is unfolded and scrolled to"),
      e => fail(e.message));
    await page.fill("#p-system", "SYS-MARK: answer tersely.");
    await page.fill("#p-temp", "0.3");
    await page.fill("#p-maxtok", "77");
    check((await page.textContent("#rc-params-sum")).includes("temp 0.3"), "the pane's head sums up the parameters",
      "the Parameters pane head says " + JSON.stringify(await page.textContent("#rc-params-sum")));
    const before = chatBodies.length;
    await send("hello there");
    const sent = chatBodies.slice(before).find(b => (b.messages || []).some(m => clean(text(m)) === "hello there"));
    if (!sent) fail("the chat request did not reach the provider");
    else {
      const sys = (sent.messages || []).filter(m => m.role === "system").map(text).join(" ");
      check(sent.temperature === 0.3 && sent.max_tokens === 77 && sys.includes("SYS-MARK"),
        "the pane's system prompt, temperature and max tokens reach the next chat request",
        "the chat request carried temperature=" + sent.temperature + " max_tokens=" + sent.max_tokens +
        " system has mark=" + sys.includes("SYS-MARK"));
    }
    await page.click("#p-reset");
    const plainId = await page.evaluate(() => activeSessionId);

    /* ---- Context ---- */
    await page.click("#rc-close");
    await page.click("#ctx-toggle");
    await page.waitForSelector("#ctx-legend li", { timeout: 15000 });
    check(await page.evaluate(() => document.querySelector("#ctx-toggle").classList.contains("on")) && await colOpen(),
      "the context button opens the column on the Context pane", "the context button did not open its pane");
    await sleep(600);
    const cmp = await page.evaluate(async () => {
      await ctxRefresh();
      const body = chatRequestBody(); body.text = true;
      const r = await gwFetch("/v1/context", { method: "POST", headers: { "content-type": "application/json" },
                                               body: JSON.stringify(body) });
      const rep = await r.json();
      const total = rep.total_tokens, win = (rep.window && rep.window.tokens) || 0;
      return {
        want: fmtTok(total) + (win ? " · " + ctxPct(total, win) : ""),
        btn: document.querySelector("#ctx-toggle .ctx-btn-n").textContent,
        head: document.querySelector("#rc-ctx-sum").textContent,
        total: document.querySelector("#ctx-total b") && document.querySelector("#ctx-total b").textContent,
        wantTotal: fmtTok(total),
        legend: [...document.querySelectorAll("#ctx-legend li")].map(li => li.querySelector(".n").textContent),
        wantLegend: (rep.categories || []).filter(c => c.tokens > 0).map(c => c.tokens.toLocaleString())
          .concat(win > total ? [(win - total).toLocaleString()] : []),
      };
    });
    check(cmp.btn === cmp.want && /\d/.test(cmp.btn) && / · /.test(cmp.btn),
      "the context button keeps its summary (" + cmp.btn + ")", "the context button reads " + JSON.stringify(cmp.btn) + ", /v1/context gives " + JSON.stringify(cmp.want));
    check(cmp.head === cmp.want && cmp.total === cmp.wantTotal && cmp.legend.join("|") === cmp.wantLegend.join("|"),
      "the Context pane shows what /v1/context answers for the chat's request",
      "the Context pane differs from /v1/context: " + JSON.stringify(cmp));

    /* ---- Background: this chat's jobs only ---- */
    holds.set("HOLD-1", false);
    holds.set("HOLD-9", false);
    await send("BG HOLD-1 index the docs");
    /* Another chat's job, running at the same time. */
    await post("/v1/chat/completions", { messages: [{ role: "user", content: "BG HOLD-9 someone else's job" }] },
               { "X-PasClaw-Session": "other-chat" });
    if ((await page.getAttribute("#rc-pane-background .rc-pane-btn", "aria-expanded")) === "false")
      await page.click("#rc-pane-background .rc-pane-btn");
    await until(async () => (await page.locator("#rc-bg-list .rc-bg-item").count()) > 0, "the job in the Background pane");
    const row = page.locator("#rc-bg-list .rc-bg-item").first();
    check(/running/.test(await row.locator(".bg-chip").textContent()) && /HOLD-1/.test(await row.textContent()),
      "a job started in this chat shows in the Background pane, running", "the pane's job: " + (await row.textContent()));
    await sleep(2500);   // the other chat's job is up by now; the pane must still leave it out
    const listed = await page.locator("#rc-bg-list .rc-bg-item").allTextContents();
    check(listed.length === 1 && !listed.some(t => /HOLD-9/.test(t)),
      "another chat's job is not listed", "the pane lists another chat's job: " + JSON.stringify(listed));
    check(/1 running/.test(await page.textContent("#rc-bg-count")), "the pane's head counts it running",
      "the Background pane head reads " + JSON.stringify(await page.textContent("#rc-bg-count")));
    holds.set("HOLD-1", true);
    await until(async () => /done/.test(await page.locator("#rc-bg-list .rc-bg-item .bg-chip").first().textContent()),
      "the job to finish in the pane", 12000)
      .then(() => ok("it updates in place and finishes"), e => fail(e.message));
    const handle = await page.getAttribute("#rc-bg-list .rc-bg-item", "data-h");
    await page.click("#rc-bg-list .rc-bg-item");
    await until(() => page.evaluate(h => document.querySelector("#tab-background").classList.contains("active") &&
        !!document.querySelector(`#bg-list .bg-item.active[data-h="${h}"]`), handle), "the job open on the Background tab")
      .then(() => ok("a job opens on the Background tab"), e => fail(e.message));
    holds.set("HOLD-9", true);
    await page.click('nav button[data-tab="chat"]');
    await page.click("#session-new");
    await until(async () => /No background work in this chat/.test(await page.textContent("#rc-bg-list")), "the empty state", 4000)
      .then(() => ok("a new chat says No background work in this chat"), e => fail(e.message));

    /* ---- the Desktop project chat's app ---- */
    holds.set("HOLD-2", false);
    await post("/v1/chat/completions", { messages: [{ role: "user", content: "BG HOLD-2 build the settings page" }],
      session_context: true }, { "X-PasClaw-Session": "desktop-demo-app" });
    await page.evaluate(() => refreshSessions());
    await openChat("Desktop: demo-app");
    await until(() => page.locator("#rc-app-wrap iframe").count(), "the app frame");
    const fr = await page.evaluate(() => {
      const f = document.querySelector("#rc-app-wrap iframe");
      return { src: f.getAttribute("src"), sandbox: f.getAttribute("sandbox"),
               pane: !document.querySelector("#rc-pane-app").hidden,
               order: [...document.querySelectorAll("#rc-panes .rc-pane")].filter(s => !s.hidden).map(s => s.dataset.pane).join(",") };
    });
    check(fr.pane && /^\/apps\/demo-app\/(\?|$)/.test(fr.src), "the project chat shows its app, framed from /apps/demo-app/",
      "the app frame: " + JSON.stringify(fr));
    check(fr.sandbox === "allow-scripts allow-forms" && !/same-origin/.test(fr.sandbox),
      "the frame is sandboxed like the desktop's, never same-origin", "the frame's sandbox is " + JSON.stringify(fr.sandbox));
    check(fr.order === "app,background,context,params", "the App pane comes first", "pane order: " + fr.order);
    const appFrame = () => page.frames().find(f => f.url().includes("/apps/demo-app/"));
    await until(async () => { const f = appFrame(); return f && /state: hello from the state store/.test(await f.textContent("#out")); },
      "the app to read its state through the column", 10000)
      .then(() => ok("the app runs, and its state store answers through the column"), e => fail(e.message));
    await until(async () => /HOLD-2/.test(await page.textContent("#rc-bg-list")), "the project chat's job", 6000).catch(() => {});
    if (shots) {
      fs.mkdirSync(shots, { recursive: true });
      await page.locator("#rc-pane-app").screenshot({ path: path.join(shots, "app-pane.png") });
      /* Tall enough for every pane at once. */
      await page.setViewportSize({ width: 1280, height: 1640 });
      await sleep(300);
      await page.screenshot({ path: path.join(shots, "desktop-dark.png") });
      await page.evaluate(() => { document.documentElement.classList.add("lite"); document.documentElement.style.colorScheme = "light"; });
      await sleep(200);
      await page.screenshot({ path: path.join(shots, "desktop-light.png") });
      await page.evaluate(() => { document.documentElement.classList.remove("lite"); document.documentElement.style.colorScheme = ""; });
      await page.setViewportSize({ width: 1280, height: 860 });
    }
    const appBefore = await page.getAttribute("#rc-app-wrap iframe", "src");
    await sleep(20);
    await page.click("#rc-app-reload");
    await until(async () => (await page.getAttribute("#rc-app-wrap iframe", "src")) !== appBefore, "a reloaded frame", 4000)
      .then(() => ok("Reload loads the app afresh"), e => fail(e.message));
    const openHref = await page.getAttribute("#rc-app-open", "href");
    check(openHref === "/desktop", "\"Open in a window\" goes to the desktop (apps share this origin here)",
      "the open-in-a-window link is " + openHref);
    holds.set("HOLD-2", true);

    /* A plain chat has no App pane. */
    await page.evaluate(id => activateSession(id), plainId);
    await until(() => page.evaluate(() => document.querySelector("#rc-pane-app").hidden &&
                                         !document.querySelector("#rc-app-wrap iframe")), "the App pane to go", 4000)
      .then(() => ok("a plain chat has no App pane and no frame"), e => fail(e.message));

    /* ---- room for both columns ---- */
    const lay = await page.evaluate(() => ({
      left: document.querySelector("aside.sessions").getBoundingClientRect().width,
      right: document.querySelector("#rc-col").getBoundingClientRect().width,
      chat: document.querySelector(".chat-pane").getBoundingClientRect().width,
      form: document.querySelector("form.send").getBoundingClientRect().width,
      sx: document.documentElement.scrollWidth - innerWidth }));
    check(lay.left > 150 && lay.right > 250 && lay.chat >= 600 && lay.form >= 560 && lay.sx <= 0,
      `at 1280 px both columns fit beside the transcript (chat ${Math.round(lay.chat)} px)`,
      "1280 px layout: " + JSON.stringify(lay));
    await page.setViewportSize({ width: 1024, height: 800 });
    await page.click("#rc-close");
    await page.click("#rc-toggle");
    const mid = await page.evaluate(() => ({
      left: document.querySelector("aside.sessions").classList.contains("collapsed"),
      chat: document.querySelector(".chat-pane").getBoundingClientRect().width }));
    await page.click("#rc-close");
    const back = await page.evaluate(() => !document.querySelector("aside.sessions").classList.contains("collapsed"));
    check(mid.left && mid.chat >= 600 && back, "at 1024 px opening it puts the chat list away, and closing brings it back",
      "1024 px: " + JSON.stringify(mid) + " list back=" + back);
    await page.setViewportSize({ width: 1280, height: 860 });
    if (!(await colOpen())) await page.click("#rc-toggle");

    /* ---- phone ---- */
    const phone = await browser.newContext({ viewport: { width: 390, height: 780 }, colorScheme: "dark", isMobile: true, hasTouch: true });
    const pp = await phone.newPage();
    pp.on("pageerror", e => fail("phone page error: " + e.message));
    await pp.goto(base + "/");
    await pp.waitForSelector("#m");
    const pClosed = await pp.evaluate(() => document.querySelector("#rc-col").classList.contains("collapsed"));
    check(pClosed, "on a phone the column starts closed",
      "the phone opened with the drawer over the chat");
    await pp.click("#rc-toggle");
    await sleep(200);
    const dr = await pp.evaluate(() => {
      const c = document.querySelector("#rc-col").getBoundingClientRect(),
            l = document.querySelector("#log").getBoundingClientRect();
      return { pos: getComputedStyle(document.querySelector("#rc-col")).position, right: c.right, left: c.left,
               w: c.width, logW: l.width, iw: innerWidth,
               sx: document.documentElement.scrollWidth - innerWidth,
               tab: document.querySelector("#tab-chat").scrollWidth - document.querySelector("#tab-chat").clientWidth };
    });
    check(dr.pos === "absolute" && Math.abs(dr.right - dr.iw) < 2 && dr.left > 0 && dr.logW >= dr.iw - 2,
      "on a phone it is a drawer from the right, over the transcript", "phone drawer: " + JSON.stringify(dr));
    check(dr.sx <= 0 && dr.tab <= 0, "no sideways scroll on a phone", "phone sideways scroll: " + JSON.stringify(dr));
    if (shots) {
      const f = () => pp.frames().find(x => x.url().includes("/apps/demo-app/"));
      await until(async () => f() && /state:/.test(await f().textContent("#out")), "the phone's app", 5000).catch(() => {});
      await pp.screenshot({ path: path.join(shots, "phone.png") });
    }
    await pp.mouse.click(20, 400);
    await sleep(150);
    check(await pp.evaluate(() => document.querySelector("#rc-col").classList.contains("collapsed")),
      "a tap beside the drawer puts it away", "the drawer stayed open after a tap on the transcript");
    await phone.close();
  } catch (e) {
    fail(e.message);
  } finally {
    await browser.close();
    gw.kill();
    provider.close();
    for (const h of holds.keys()) holds.set(h, true);
    try { fs.rmSync(home, { recursive: true, force: true }); } catch {}
  }
  if (failures) {
    console.log("--- gateway log (tail) ---\n" + gwLog.split("\n").slice(-30).join("\n"));
    console.log("webui chat column e2e: " + failures + " failure(s)");
    process.exit(1);
  }
  console.log("webui chat column e2e: all checks passed");
  process.exit(0);
})();
