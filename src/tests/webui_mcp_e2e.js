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

   Then, on the second gateway (MCP on, so a save connects what it adds):

     - Add server from the empty state: an empty form is refused inline (no
       name, no command), and nothing is saved;
     - the catalog lists what GET /v1/mcp/catalog has, and Use fills the
       form (a URL server, its token as a ${VAR} marker shown as text);
     - adding the fake server with a secret env value: config.json gets the
       value, the row appears and reaches Ready, and the value is in the
       page's HTML neither then nor after a reload;
     - a duplicate name and a name with other characters are refused;
     - Edit changes its args (the saved env value is kept, not shown), and
       the row says the change waits for a restart;
     - HTML in a server name (written by another client) renders as text;
     - Remove asks first; dismissed it keeps the server, accepted it takes
       it out of config.json, and the row says it runs until a restart.

   SHOTS=<dir> saves screenshots of the add form, the catalog and the list.

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
  let dialogs = [], dialogAnswer = "dismiss";
  page.on("dialog", d => { dialogs.push(d.message()); dialogAnswer === "accept" ? d.accept() : d.dismiss(); });
  const shots = process.env.SHOTS || "";
  if (shots) fs.mkdirSync(shots, { recursive: true });
  const shot = async name => { if (shots) await page.screenshot({ path: path.join(shots, name), fullPage: true }); };
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

    /* ---- add from the tab: inline checks first ---- */
    const SECRET = "s3cr3t-fake-value-77";
    const disk = () => JSON.parse(fs.readFileSync(path.join(B.home, "config.json"), "utf8")).mcp_servers || [];
    const perr = async () => (await page.locator("#mcp-form .set-err").allTextContents()).join(" | ");
    await page.goto(B.base + "/#mcp");
    await until(async () => /No MCP servers configured/.test(await page.textContent("#mcp-list")), "the empty state again");
    await page.click("#mcp-list .mcp-empty [data-mcp-add]");
    await until(() => page.isVisible("#mcp-panel #mcp-form"), "the add panel");
    await page.click("#mcp-save");
    await until(async () => /Give the server a name/.test(await perr()) && /command that starts/.test(await perr()), "the empty form's errors, got " + await perr());
    if (disk().length) fail("an empty form was saved");
    ok("an empty add form is refused inline, and nothing is saved");

    /* ---- the catalog ---- */
    const cat = (await (await fetch(B.base + "/v1/mcp/catalog")).json()).servers;
    if (!cat.length || cat.some(c => "env" in c)) fail("the catalog route: " + JSON.stringify(cat).slice(0, 200));
    await page.click("#mcp-cat > summary");
    await until(async () => (await page.locator("#mcp-cat .mcp-cat-row").count()) === cat.length, "a catalog row per entry");
    const hf = cat.find(c => c.name === "huggingface");
    const hfRow = page.locator('#mcp-cat .mcp-cat-row[data-name="huggingface"]');
    if ((await hfRow.locator(".mcp-cmd").textContent()) !== hf.cmd) fail("the catalog row's command");
    await shot("mcp-add-catalog.png");
    await hfRow.getByRole("button", { name: "Use huggingface" }).click();
    await until(async () => (await page.inputValue("#mcp-f-name")) === "huggingface", "the form filled from the catalog");
    if ((await page.inputValue("#mcp-f-cmd")) !== hf.cmd) fail("the catalog URL");
    if (!(await page.isChecked('#mcp-form input[type=radio][value=url]'))) fail("the catalog entry should pick the URL transport");
    const hfKey = page.locator("#mcp-f-env-k0"), hfVal = page.locator("#mcp-f-env-v0");
    if ((await hfKey.inputValue()) !== "Authorization" || (await hfVal.inputValue()) !== "Bearer ${HF_TOKEN}" || (await hfVal.getAttribute("type")) !== "text")
      fail("the catalog's token should be an Authorization variable holding ${HF_TOKEN}, shown as text");
    ok("the catalog lists " + cat.length + " entries with their command; Use fills the form (URL, Authorization: Bearer ${HF_TOKEN})");

    /* ---- add the fake server, with a secret ---- */
    await page.click("#mcp-add");
    await until(async () => (await page.inputValue("#mcp-f-name")) === "", "a fresh add form");
    await page.fill("#mcp-f-name", "fakemcp");
    await page.fill("#mcp-f-cmd", PY);
    await page.fill("#mcp-f-args", `"${FAKE}" --era modern`);
    await page.getByRole("button", { name: "Add a variable" }).click();
    await page.fill("#mcp-f-env-k0", "FAKE_SECRET");
    await page.fill("#mcp-f-env-v0", SECRET);
    if ((await page.getAttribute("#mcp-f-env-v0", "type")) !== "password") fail("an env value should be a password field");
    await shot("mcp-add-form.png");
    await page.click("#mcp-save");
    await until(async () => /Added “fakemcp”/.test(await page.textContent("#mcp-flash")), "the added message");
    const flash1 = await page.textContent("#mcp-flash");
    if (!/Connecting fakemcp now/.test(flash1)) fail("the add should connect at once: " + flash1);
    const d1 = disk();
    if (d1.length !== 1 || d1[0].name !== "fakemcp" || d1[0].env !== "FAKE_SECRET=" + SECRET || d1[0].cmd !== PY) fail("disk after add: " + JSON.stringify(d1));
    await until(async () => (await row("fakemcp").getAttribute("data-state")) === "ready", "fakemcp to reach Ready");
    if (await page.isVisible("#mcp-panel")) fail("the panel should close after a save");
    if ((await page.content()).includes(SECRET)) fail("the page holds the env secret after the add");
    await page.reload();
    await until(async () => (await row("fakemcp").count()) === 1, "the row after a reload");
    if ((await page.content()).includes(SECRET)) fail("the page holds the env secret after a reload");
    const cfgView = await (await fetch(B.base + "/v1/config?source=file")).text();
    if (cfgView.includes(SECRET) || !cfgView.includes("FAKE_SECRET=•••")) fail("GET /v1/config should show the variable's name and mask its value");
    ok("Add: saved with its env value on disk (" + d1[0].env.replace(SECRET, "<secret>") + "), connected live to Ready, the value never in the page");

    /* ---- duplicate and bad names, no command ---- */
    await page.click("#mcp-add");
    await page.fill("#mcp-f-name", "FakeMCP");
    await page.fill("#mcp-f-cmd", "x");
    await page.click("#mcp-save");
    await until(async () => /already called “FakeMCP”/.test(await perr()), "the duplicate-name error, got " + await perr());
    await page.fill("#mcp-f-name", "bad name");
    await until(async () => /letters, digits/.test(await perr()), "the allowed-characters error, got " + await perr());
    await page.fill("#mcp-f-name", "other");
    await page.fill("#mcp-f-cmd", "");
    await until(async () => /command that starts/.test(await perr()), "the no-command error, got " + await perr());
    if (disk().length !== 1) fail("an invalid server was saved");
    await page.click("#mcp-panel .mcp-panel-foot .icon-btn");
    ok("a duplicate name (any case), a name with a space and a missing command are refused inline");

    /* ---- edit its args ---- */
    await row("fakemcp").getByRole("button", { name: "Edit fakemcp" }).click();
    await until(async () => (await page.textContent("#mcp-panel-h")) === "Edit fakemcp", "the edit panel");
    if ((await page.inputValue("#mcp-f-env-k0")) !== "FAKE_SECRET" || (await page.inputValue("#mcp-f-env-v0")) !== "" ||
        !/Saved/.test(await page.getAttribute("#mcp-f-env-v0", "placeholder"))) fail("the saved env value should show as saved, empty");
    await page.fill("#mcp-f-args", `"${FAKE}" --era modern --silent-unknown`);
    await page.click("#mcp-save");
    await until(async () => /Saved “fakemcp”/.test(await page.textContent("#mcp-flash")), "the saved message");
    if (!/Restart the gateway to apply it/.test(await page.textContent("#mcp-flash"))) fail("an edit of a running server should wait for a restart: " + await page.textContent("#mcp-flash"));
    const d2 = disk();
    if (!/--silent-unknown$/.test(d2[0].args) || d2[0].env !== "FAKE_SECRET=" + SECRET) fail("disk after edit: " + JSON.stringify(d2));
    await until(async () => (await row("fakemcp").locator(".mcp-restart").count()) === 1, "the row's restart tag");
    ok("Edit: the args changed on disk, the env value kept; the row says Restart to apply");

    /* ---- HTML in a name, from another client ---- */
    const EVIL = "<img src=x onerror=window.__pwned=1>";
    const cfg = await (await fetch(B.base + "/v1/config?source=file")).json();
    cfg.mcp_servers.push({ name: EVIL, cmd: "nope", args: "", enabled: false });
    const put = await fetch(B.base + "/v1/config", { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify(cfg) });
    if (!put.ok) fail("PUT with the HTML name: " + put.status);
    await page.click("#mcp-refresh");
    await until(async () => (await page.locator("#mcp-list .mcp-srv").count()) === 2, "the HTML-named row");
    const names2 = await page.locator("#mcp-list .mcp-srv-name").allTextContents();
    if (!names2.includes(EVIL)) fail("the HTML name should read as text: " + JSON.stringify(names2));
    if (await page.locator("#mcp-list img").count() || await page.evaluate(() => window.__pwned)) fail("the HTML in a name became markup");
    if (disk()[0].env !== "FAKE_SECRET=" + SECRET) fail("another client's save lost the env value");
    ok("HTML in a server name is drawn as text");

    /* ---- remove, with the confirm ---- */
    dialogs = [];
    await row("fakemcp").getByRole("button", { name: "Remove fakemcp" }).click();
    await until(async () => dialogs.length === 1, "the confirm");
    if (!/Remove the MCP server “fakemcp”/.test(dialogs[0])) fail("the confirm text: " + dialogs[0]);
    await sleep(300);
    if (!disk().some(s => s.name === "fakemcp")) fail("a dismissed Remove removed the server");
    dialogAnswer = "accept";
    await row("fakemcp").getByRole("button", { name: "Remove fakemcp" }).click();
    await until(async () => !disk().some(s => s.name === "fakemcp"), "fakemcp gone from config.json");
    dialogAnswer = "dismiss";
    await until(async () => /Removed “fakemcp”/.test(await page.textContent("#mcp-flash")), "the removed message");
    await until(async () => /keeps running until the gateway restarts/.test(await row("fakemcp").textContent()), "the removed row's note");
    if (await row("fakemcp").getByRole("button", { name: "Edit fakemcp" }).count()) fail("a removed server still offers Edit");
    await shot("mcp-tab-list.png");
    ok("Remove asks first; dismissed keeps it, accepted takes it out of config.json; the row says it runs until a restart");

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
