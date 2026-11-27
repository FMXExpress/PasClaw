#!/usr/bin/env node
/* The web UI's MCP tab, against the real gateway.

   One gateway has four MCP servers: the scripted fake server
   (fake_mcp_server.py --era modern), which connects; the same server told to
   wait ten minutes before it answers, which stays connecting; a command that
   does not exist, whose path holds HTML, which fails; and one turned off. A
   second gateway has none. Through headless Chromium:

     - a row per server in the route's order, each with the state the route
       gives (Ready, Connecting, Failed, Disabled), and the strip's counts;
     - the ready row shows the negotiated protocol, the server's name and
       version, and its tool count; its tool list holds the names
       GET /v1/mcp/tools gives for it;
     - the failed row shows the route's error as text: the HTML in it is not
       markup;
     - with no servers, the empty state, whose button opens Settings on the
       MCP servers section.

   Needs node with Playwright and a Chromium; skips without them.
   usage: node webui_mcp_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_mcp_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const FAKE = path.join(__dirname, "fake_mcp_server.py");
const PY = process.env.PYTHON || "python3";

let failures = 0, gwLog = "";
const fail = msg => { console.log("FAIL: " + msg); failures++; throw new Error(msg); };
const ok = msg => console.log("  ok: " + msg);
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, what, ms = 15000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch {} await sleep(100); }
  fail("timed out waiting for " + what);
}
function freePort() {
  return new Promise(r => { const s = http.createServer().listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => r(p)); }); });
}

async function startGateway(servers, tag) {
  const port = await freePort();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-mcp-" + tag + "-"));
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify({
    gateway: { port, bind_addr: "127.0.0.1" },
    providers: [{ name: "fake", kind: "openai", api_base: "http://127.0.0.1:9/v1", api_key: "sk-test", model: "m" }],
    default_provider: "fake", default_model: "m", mcp_servers: servers }));
  const proc = spawn(binary, ["gateway", "--port", String(port), "--addr", "127.0.0.1"],
                     { cwd: home, env: Object.assign({}, process.env, { PASCLAW_HOME: home }), stdio: ["ignore", "pipe", "pipe"] });
  proc.stdout.on("data", d => gwLog += d); proc.stderr.on("data", d => gwLog += d);
  const base = `http://127.0.0.1:${port}`;
  await until(async () => (await fetch(base + "/v1/health")).ok, "the " + tag + " gateway");
  return { base, home, proc };
}

(async () => {
  const BAD = "/nonexistent/<b>mcp</b>-server";
  const A = await startGateway([
    { name: "fakemcp", cmd: PY, args: `"${FAKE}" --era modern`, enabled: true, codemode: false },
    { name: "slowpoke", cmd: PY, args: `"${FAKE}" --era modern --start-delay 600`, enabled: true },
    { name: "broken", cmd: BAD, args: "--stdio", enabled: true },
    { name: "off", cmd: PY, args: "server.py", enabled: false },
  ], "servers");
  const B = await startGateway([], "empty");
  const mcp = async () => (await (await fetch(A.base + "/v1/mcp")).json()).servers;
  await until(async () => { const s = await mcp(); return s[0].state === "ready" && s[2].state === "failed"; },
              "fakemcp ready and broken failed on the route");
  const route = await mcp();
  const routeTools = (await (await fetch(A.base + "/v1/mcp/tools")).json()).tools
    .map(t => t.name).filter(n => n.startsWith("fakemcp__")).map(n => n.slice(9));
  if (!routeTools.length) fail("the route lists no tools for fakemcp");

  const browser = await chromium.launch();
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 900 } })).newPage();
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  page.on("dialog", d => d.dismiss());
  const row = name => page.locator(`#mcp-list .mcp-srv[data-name="${name}"]`);

  try {
    /* ---- servers and their states ---- */
    await page.goto(A.base + "/#mcp");
    await until(async () => (await page.locator("#mcp-list .mcp-srv").count()) === 4, "four server rows");
    const shown = await page.$$eval("#mcp-list .mcp-srv", rs => rs.map(r => [r.dataset.name, r.dataset.state,
      r.querySelector(".mcp-state").textContent]));
    const want = [["fakemcp", "ready", "Ready"], ["slowpoke", "connecting", "Connecting"],
                  ["broken", "failed", "Failed"], ["off", "disabled", "Disabled"]];
    if (JSON.stringify(shown) !== JSON.stringify(want)) fail("rows: " + JSON.stringify(shown));
    for (let i = 0; i < 3; i++)
      if (route[i].state !== want[i][1]) fail(`the route says ${route[i].name} is ${route[i].state}, the row ${want[i][1]}`);
    const strip = await page.$$eval("#mcp-strip .mcp-num", ns => ns.map(n => n.textContent));
    if (JSON.stringify(strip) !== JSON.stringify(["1", "1", "1", String(routeTools.length)])) fail("the strip: " + JSON.stringify(strip));
    ok("a row per server in the route's order, with its state; the strip " + strip.join("/"));

    /* ---- what the ready one negotiated, and its tools ---- */
    const facts = (await row("fakemcp").locator(".mcp-facts > div").evaluateAll(ds =>
      ds.map(d => d.querySelector("dt").textContent + " " + d.querySelector("dd").textContent).join(" | "))).replace(/\s+/g, " ");
    const r0 = route[0];
    for (const want of [r0.protocol_version, "via " + r0.negotiation, r0.server_name + " " + r0.server_version, "Tools " + routeTools.length])
      if (!facts.includes(want)) fail(`the ready row's facts lack ${JSON.stringify(want)}: ${facts}`);
    await row("fakemcp").locator(".mcp-tools > summary").click();
    const names = await row("fakemcp").locator(".mcp-tool-list code").allTextContents();
    if (JSON.stringify(names) !== JSON.stringify(routeTools)) fail("tool names: " + JSON.stringify(names));
    ok(`the ready row: ${r0.protocol_version} via ${r0.negotiation}, ${r0.server_name} ${r0.server_version}, ${names.length} tools listed`);

    /* ---- the failed one's error, as text ---- */
    const err = row("broken").locator(".mcp-err-text");
    if ((await err.textContent()) !== route[2].error) fail(`the error reads ${JSON.stringify(await err.textContent())}, the route ${JSON.stringify(route[2].error)}`);
    if (!route[2].error.includes("<b>")) fail("the route's error does not hold the HTML: " + route[2].error);
    if (await row("broken").locator("b:has-text('mcp')").count()) fail("the HTML in the error became markup");
    if (await row("broken").locator(".mcp-cmd b").count()) fail("the HTML in the command became markup");
    ok("the failed row shows the route's error as text: " + JSON.stringify(route[2].error));

    /* ---- no servers: the empty state, and its way to Settings ---- */
    await page.evaluate(() => localStorage.setItem("pasclaw.settings.section", "agent"));
    await page.goto(B.base + "/#mcp");
    await until(async () => /No MCP servers configured/.test(await page.textContent("#mcp-list")), "the empty state");
    if (await page.isVisible("#mcp-strip")) fail("the strip shows with no servers");
    await page.click("#mcp-list .mcp-empty [data-mcp-settings]");
    await until(async () => (await page.getAttribute('#set-nav button[data-sec="mcp"]', "aria-current")) === "true",
                "Settings on MCP servers");
    ok("no servers: the empty state, and its button opens Settings on MCP servers");

    if (failures) throw new Error(failures + " failure(s)");
    console.log("webui_mcp_e2e: OK");
  } catch (e) {
    if (!failures) console.log("FAIL: " + e.message);
    console.log("---- gateway log (tail) ----\n" + gwLog.split("\n").slice(-25).join("\n"));
    process.exitCode = 1;
  } finally {
    await browser.close();
    for (const g of [A, B]) { g.proc.kill(); fs.rmSync(g.home, { recursive: true, force: true }); }
  }
})();
