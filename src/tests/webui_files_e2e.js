#!/usr/bin/env node
/* The web UI's Files tab, against the real gateway.

   A gateway starts in a home whose workspace holds folders, a text file, a
   Markdown file, a file over the 256 KB read cap, a binary file, a file
   whose name and content are HTML, and a config.json the server hides.
   Through headless Chromium:

     - the listing is GET /v1/fs's entries, folders first, then by name, each
       with its size and a modified time (exact on hover); config.json is not
       in either;
     - the breadcrumb starts at Workspace and each segment opens its folder;
       Backspace goes up with the keyboard and selects the folder it left;
     - a text file opens with its content, one line number per line, and
       Copy puts the content on the clipboard; Markdown renders;
     - the HTML name and content are drawn as text: no element is made from
       them and no dialog opens;
     - the file over the cap says it shows only the first 256 KB, and the
       binary file says it is binary and shows a hex dump;
     - a folder that cannot be listed shows the server's reason;
     - phone width: the folder sits above the file, no sideways scroll.

   Needs node with Playwright and a Chromium; skips without them.
   FILES_SHOTS=<dir> also writes dark, light and phone screenshots there.
   usage: node webui_files_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_files_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const shots = process.env.FILES_SHOTS || "";
if (shots) fs.mkdirSync(shots, { recursive: true });

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
function freePort() {
  return new Promise(r => { const s = http.createServer().listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => r(p)); }); });
}

const EVIL = "<img src=x onerror=alert(1)>.html";
const EVIL_BODY = "<script>alert(2)</script>\n<b>bold?</b>\n";
const TODO = Array.from({ length: 40 }, (_, i) => "line " + (i + 1) + ": a <b>tag</b> & an ampersand").join("\n") + "\n";

(async () => {
  const port = await freePort();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-files-"));
  const ws = path.join(home, "workspace");
  for (const d of ["notes", "src/deep", "Empty"]) fs.mkdirSync(path.join(ws, d), { recursive: true });
  fs.writeFileSync(path.join(ws, "notes/todo.txt"), TODO);
  fs.writeFileSync(path.join(ws, "README.md"), "# Project notes\n\nSome **bold** text.\n");
  fs.writeFileSync(path.join(ws, EVIL), EVIL_BODY);
  fs.writeFileSync(path.join(ws, "big.log"), ("y".repeat(99) + "\n").repeat(3000));   // 300 KB
  fs.writeFileSync(path.join(ws, "data.bin"), Buffer.from(Array.from({ length: 2048 }, (_, i) => (i * 37) % 256)));
  fs.writeFileSync(path.join(ws, "src/deep/x.txt"), "deep\n");
  fs.writeFileSync(path.join(ws, "src/a10.txt"), "a10\n");
  fs.writeFileSync(path.join(ws, "src/a9.txt"), "a9\n");
  fs.writeFileSync(path.join(ws, "config.json"), '{"api_key":"sk-hidden"}');
  const old = Date.now() / 1000 - 3 * 86400;
  fs.utimesSync(path.join(ws, "data.bin"), old, old);
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify({
    gateway: { port, bind_addr: "127.0.0.1" },
    providers: [{ name: "fake", kind: "openai", api_base: "http://127.0.0.1:9/v1", api_key: "sk-test", model: "m" }],
    default_provider: "fake", default_model: "m" }));
  const proc = spawn(binary, ["gateway", "--port", String(port), "--addr", "127.0.0.1", "--no-mcp"],
                     { cwd: home, env: Object.assign({}, process.env, { PASCLAW_HOME: home }), stdio: ["ignore", "pipe", "pipe"] });
  proc.stdout.on("data", d => gwLog += d); proc.stderr.on("data", d => gwLog += d);
  const base = `http://127.0.0.1:${port}`;
  await until(async () => (await fetch(base + "/v1/health")).ok, "the gateway");

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: "dark",
                                         permissions: ["clipboard-read", "clipboard-write"] });
  const page = await ctx.newPage();
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  let dialogs = 0;
  page.on("dialog", d => { dialogs++; d.dismiss(); });
  const shot = async name => { if (shots) await page.screenshot({ path: path.join(shots, name) }); };
  const names = () => page.$$eval("#fs-list .fsb-row .fsb-name span", s => s.map(x => x.textContent));
  const crumb = () => page.$$eval("#fs-crumb button", bs => bs.map(b => b.textContent));
  const row = name => page.locator("#fs-list .fsb-row").filter({ has: page.locator(".fsb-name span", { hasText: name }) }).first();
  const openFile = async name => { await row(name).click(); await until(async () => (await page.textContent("#fsb-vname")) === name, name + " in the viewer"); };

  try {
    await page.goto(base + "/#files");
    await page.waitForSelector("#fs-list .fsb-row");

    /* ---- the listing is the route's, folders first, then by name ---- */
    const j = await (await fetch(base + "/v1/fs")).json();
    if (!/workspace$/.test(j.path)) fail("GET /v1/fs did not land on the workspace: " + j.path);
    const want = j.entries.slice().sort((a, b) => (b.dir - a.dir) || a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" }))
                  .map(e => e.name);
    const got = await names();
    if (!eq(got, want)) fail("the listing " + JSON.stringify(got) + " is not the route's " + JSON.stringify(want));
    if (got.includes("config.json") || j.entries.some(e => e.name === "config.json")) fail("config.json is listed");
    const dirs = new Set(j.entries.filter(e => e.dir).map(e => e.name));
    if (!dirs.size || got.findIndex(n => !dirs.has(n)) !== dirs.size) fail("folders do not come first: " + JSON.stringify(got));
    const bin = row("data.bin");
    if ((await bin.locator(".fsb-size").textContent()) !== "2.0 KB") fail("data.bin's size reads " + await bin.locator(".fsb-size").textContent());
    if ((await bin.locator(".fsb-mod").textContent()) !== "3 d ago") fail("data.bin's modified time reads " + await bin.locator(".fsb-mod").textContent());
    if (!/^Modified .*\d/.test(await bin.locator(".fsb-mod").getAttribute("title") || "")) fail("no exact modified time on hover");
    if (!j.entries.every(e => typeof e.mtime === "number" && e.mtime > 0)) fail("an entry has no mtime");
    if (!eq(await crumb(), ["Workspace"])) fail("the crumb at the root reads " + JSON.stringify(await crumb()));
    ok("the listing is GET /v1/fs's, folders first then by name, with size and modified time; config.json hidden");

    /* ---- the breadcrumb ---- */
    await row("src").click();
    await until(async () => eq(await crumb(), ["Workspace", "src"]), "Workspace / src");
    if (!eq(await names(), ["deep", "a9.txt", "a10.txt"])) fail("src lists " + JSON.stringify(await names()));
    await row("deep").click();
    await until(async () => eq(await crumb(), ["Workspace", "src", "deep"]), "Workspace / src / deep");
    if (!eq(await names(), ["x.txt"])) fail("deep lists " + JSON.stringify(await names()));
    await page.click("#fs-crumb button:has-text('src')");
    await until(async () => eq(await crumb(), ["Workspace", "src"]), "back to src by its crumb");
    await page.click("#fs-crumb button:has-text('Workspace')");
    await until(async () => eq(await crumb(), ["Workspace"]) && eq(await names(), want), "back to Workspace by its crumb");
    /* Keyboard: into notes with Enter, out with Backspace. */
    await row("notes").focus();
    await page.keyboard.press("Enter");
    await until(async () => eq(await crumb(), ["Workspace", "notes"]), "Enter opens notes");
    await page.keyboard.press("Backspace");
    await until(async () => eq(await crumb(), ["Workspace"]), "Backspace goes up");
    await until(async () => (await page.getAttribute("#fs-list .fsb-row[aria-selected=true] .fsb-name span", "title")) === "notes", "notes selected after going up");
    ok("the breadcrumb opens each folder on the path; Enter and Backspace move in and out");

    /* ---- a text file ---- */
    await row("notes").click();
    await until(async () => (await names()).includes("todo.txt"), "notes listed");
    await openFile("todo.txt");
    await until(async () => (await page.$(".fsb-text")) !== null, "the text");
    if ((await page.textContent(".fsb-text")) !== TODO.replace(/\n$/, "")) fail("todo.txt's content differs");
    if ((await page.textContent(".fsb-ln")).split("\n").length !== 40) fail("not 40 line numbers");
    if (!/notes$/.test(await page.textContent("#fsb-vpath"))) fail("the header path is " + await page.textContent("#fsb-vpath"));
    await page.click("#fsb-copy");
    await until(async () => (await page.evaluate(() => navigator.clipboard.readText())) === TODO, "Copy to put the file on the clipboard");
    await shot("desktop-dark-text.png");
    ok("a text file opens with its content, 40 line numbers, its folder in the header, and Copy");

    await page.click("#fs-crumb button:has-text('Workspace')");
    await until(async () => eq(await names(), want), "the workspace again");
    await openFile("README.md");
    await until(async () => (await page.$(".fsb-md h1")) !== null, "README.md rendered");
    if ((await page.textContent(".fsb-md h1")) !== "Project notes") fail("the Markdown heading reads " + await page.textContent(".fsb-md h1"));
    await page.click("#fsb-mdseg [data-md=source]");
    await until(async () => /^# Project notes/.test(await page.textContent(".fsb-text") || ""), "the Markdown source");
    await page.click("#fsb-mdseg [data-md=preview]");
    ok("Markdown renders, and Source shows the text");

    /* ---- HTML in a name and in content stays text ---- */
    await openFile(EVIL);
    await until(async () => (await page.textContent(".fsb-text")) === EVIL_BODY.replace(/\n$/, ""), "the HTML file's text");
    const made = await page.evaluate(() => document.querySelectorAll("#tab-files img, #tab-files script, #fs-view b").length);
    if (made) fail(made + " element(s) made from the HTML name or content");
    if ((await page.getAttribute("#fs-list .fsb-row[aria-selected=true] .fsb-name span", "title")) !== EVIL) fail("the HTML name is not shown as text in the list");
    await sleep(300);
    if (dialogs) fail("a dialog opened");
    ok("an HTML file name and its content are drawn as text");

    /* ---- too large, and binary ---- */
    await openFile("big.log");
    await until(async () => /first 256 KB of 293\.0 KB/.test(await page.textContent(".fsb-note") || ""), "the too-large note");
    if ((await page.textContent(".fsb-text")).length < 250000) fail("the first 256 KB of big.log are not shown");
    await shot("desktop-dark-large.png");
    await openFile("data.bin");
    await until(async () => /Binary file/.test(await page.textContent(".fsb-note") || ""), "the binary note");
    await until(async () => /^00000000  00 25 4a/.test(await page.textContent(".hexdump") || ""), "the hex dump");
    if (!(await page.isDisabled("#fsb-copy"))) fail("Copy is on for a binary file");
    ok("a file over 256 KB says so and shows its start; a binary file says so and shows a hex dump");

    /* ---- a folder that cannot be listed ---- */
    await page.evaluate(p => fsbLoad(p), path.join(ws, "missing"));
    await until(async () => /Can't open this folder\s*not a directory/.test(await page.textContent("#fs-list") || ""), "the error state");
    await page.evaluate(() => fsbLoad(""));
    await until(async () => eq(await names(), want), "the workspace after the error");
    ok("a folder that cannot be listed shows the server's reason");

    /* ---- light theme, phone width ---- */
    if (shots) {
      await page.emulateMedia({ colorScheme: "light" });
      await page.evaluate(() => document.documentElement.classList.add("lite"));
      await openFile("README.md");
      await shot("desktop-light-markdown.png");
      await page.evaluate(() => document.documentElement.classList.remove("lite"));
    }
    await page.setViewportSize({ width: 390, height: 844 });
    await openFile("README.md");
    await sleep(200);
    const lay = await page.evaluate(() => {
      const s = document.querySelector(".fsb-side").getBoundingClientRect(), v = document.querySelector(".fsb-view").getBoundingClientRect();
      return { stacked: s.bottom <= v.top + 1 && v.height > 200, wide: document.documentElement.scrollWidth };
    });
    if (!lay.stacked) fail("at phone width the folder is not above the file: " + JSON.stringify(lay));
    if (lay.wide > 390) fail("sideways scroll at phone width: " + lay.wide);
    await shot("phone-dark-markdown.png");
    await page.click("#fsb-close");
    await until(async () => (await page.isHidden(".fsb-view")), "the viewer closed");
    await shot("phone-dark-folder.png");
    ok("phone width: the folder above the file, no sideways scroll, close gives the height back");

    if (failures) throw new Error(failures + " failure(s)");
    console.log("webui_files_e2e: OK");
  } catch (e) {
    if (!failures) console.log("FAIL: " + e.message);
    console.log("---- gateway log (tail) ----\n" + gwLog.split("\n").slice(-25).join("\n"));
    process.exitCode = 1;
  } finally {
    await browser.close();
    proc.kill();
    fs.rmSync(home, { recursive: true, force: true });
  }
})();
