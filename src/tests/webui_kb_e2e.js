#!/usr/bin/env node
/* The web UI's KB tab, against the real gateway.

   A gateway starts in an empty home. Through headless Chromium:

     - with nothing indexed, the tab shows its empty state (no strip), and a
       search says why it failed;
     - a file uploaded through the tab, one through POST /v1/kb/upload and a
       folder indexed with `pasclaw kb add` (holding a file whose name and
       content are HTML) appear after Refresh: the strip, the document rows
       (name inside its source, chunks) and the source rows are GET /v1/kb's;
     - a search lists GET /v1/kb/search's hits in order, each with its
       document, chunk and score, and the snippet with the matches marked;
     - the HTML name and snippet are drawn as text: no element is made from
       them and no alert opens;
     - uploading a name that is already there asks first, and Cancel keeps it;
     - a search with no hits says so;
     - phone width: the strip goes two by two, no sideways scroll.

   Needs node with Playwright and a Chromium; skips without them.
   KB_SHOTS=<dir> also writes dark, light and phone screenshots there.
   usage: node webui_kb_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn, spawnSync } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_kb_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const shots = process.env.KB_SHOTS || "";
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
const base = p => String(p).split(/[\\/]/).pop();
function freePort() {
  return new Promise(r => { const s = http.createServer().listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => r(p)); }); });
}

const EVIL = "<img src=x onerror=alert(1)>.md";
const EVIL_BODY = "# Notes\n\n<script>alert(2)</script> The gateway keeps <b>bold</b> notes.\n";
const GUIDE = "# Installing PasClaw\n\nDownload the release and run the gateway.\n\nThe gateway listens on port 18790.\n";
const NOTES = "Release notes\n\nThe gateway now indexes PDFs and Markdown into the knowledge base.\n";

(async () => {
  const port = await freePort();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-kb-"));
  fs.mkdirSync(path.join(home, "workspace"), { recursive: true });
  const lib = path.join(home, "library");
  fs.mkdirSync(path.join(lib, "guides"), { recursive: true });
  fs.writeFileSync(path.join(lib, EVIL), EVIL_BODY);
  fs.writeFileSync(path.join(lib, "guides", "routing.txt"), "How the gateway routes a request to a provider.\n");
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify({
    gateway: { port, bind_addr: "127.0.0.1" },
    providers: [{ name: "fake", kind: "openai", api_base: "http://127.0.0.1:9/v1", api_key: "sk-test", model: "m" }],
    default_provider: "fake", default_model: "m" }));
  const env = Object.assign({}, process.env, { PASCLAW_HOME: home });
  const proc = spawn(binary, ["gateway", "--port", String(port), "--addr", "127.0.0.1", "--no-mcp"],
                     { cwd: home, env, stdio: ["ignore", "pipe", "pipe"] });
  proc.stdout.on("data", d => gwLog += d); proc.stderr.on("data", d => gwLog += d);
  const url = `http://127.0.0.1:${port}`;
  await until(async () => (await fetch(url + "/v1/health")).ok, "the gateway");

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: "dark" });
  const page = await ctx.newPage();
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  const dialogs = [];
  page.on("dialog", d => { dialogs.push(d.type() + ": " + d.message()); d.dismiss(); });
  const shot = async name => { if (shots) await page.screenshot({ path: path.join(shots, name) }); };
  const texts = sel => page.$$eval(sel, es => es.map(e => e.textContent));
  const lite = async on => {
    await page.emulateMedia({ colorScheme: on ? "light" : "dark" });
    await page.evaluate(v => document.documentElement.classList.toggle("lite", v), on);
  };

  try {
    /* ---- empty ---- */
    await page.goto(url + "/#kb");
    await page.waitForSelector("#kb-docs .kb-empty");
    if ((await page.textContent("#kb-docs .kb-empty b")) !== "No documents yet") fail("the empty state's title reads " + await page.textContent("#kb-docs .kb-empty b"));
    if (!(await page.isHidden("#kb-strip"))) fail("the strip shows with nothing indexed");
    if (!eq(await texts("#tab-kb h2"), ["Knowledge base"])) fail("no Knowledge base heading");
    await page.fill("#kb-q", "gateway");
    await page.press("#kb-q", "Enter");
    await page.waitForSelector("#kb-results .kb-empty");
    if ((await page.textContent("#kb-results .kb-empty b")) !== "Nothing to search yet") fail("searching nothing reads " + await page.textContent("#kb-results .kb-empty b"));
    await shot("empty-desktop-dark.png");
    if (shots) {
      await lite(true);
      await shot("empty-desktop-light.png");
      await page.setViewportSize({ width: 390, height: 844 });
      await shot("empty-phone-light.png");
      await lite(false);
      await shot("empty-phone-dark.png");
      await page.setViewportSize({ width: 1280, height: 900 });
    }
    /* A search the server refuses shows its reason, as text, with a retry. */
    await page.route("**/v1/kb/search*", r => r.fulfill({ status: 503, contentType: "application/json",
                                                         body: JSON.stringify({ error: "knowledge base unavailable (<i>busy</i>)" }) }));
    await page.click("#kb-search-btn");
    await page.waitForSelector("#kb-results .kb-msg.err button");
    if ((await page.textContent("#kb-results .kb-msg span")) !== "Search failed: knowledge base unavailable (<i>busy</i>)") fail("the failed search reads " + await page.textContent("#kb-results .kb-msg span"));
    await page.unroute("**/v1/kb/search*");
    await page.fill("#kb-q", "");
    await page.press("#kb-q", "Enter");
    await until(async () => (await page.$$("#kb-results > *")).length === 0, "the results cleared");
    ok("empty: the empty state and no strip; a search says there is nothing to search, a failed one says why");

    /* ---- index: through the tab, through the route, and kb add ---- */
    await page.setInputFiles("#kb-file", { name: "install-guide.md", mimeType: "text/markdown", buffer: Buffer.from(GUIDE) });
    await page.click("#kb-upload-btn");
    await until(async () => /^Indexed install-guide\.md/.test(await page.textContent("#kb-status")), "the upload's status");
    await page.waitForSelector("#kb-docs .kb-doc.new");
    const up = await fetch(url + "/v1/kb/upload", { method: "POST", headers: { "content-type": "application/json" },
                                                   body: JSON.stringify({ name: "release-notes.txt", content: NOTES }) });
    if (!up.ok) fail("POST /v1/kb/upload: HTTP " + up.status);
    const add = spawnSync(binary, ["kb", "add", lib], { cwd: home, env, encoding: "utf8" });
    if (add.status !== 0) fail("pasclaw kb add failed: " + add.stdout + add.stderr);
    await page.click("#kb-refresh");
    await until(async () => (await page.$$("#kb-docs .kb-doc")).length === 4, "four document rows");

    const j = await (await fetch(url + "/v1/kb")).json();
    const st = j.stats;
    if (st.files !== 4 || j.documents.length !== 4 || st.sources !== 2) fail("GET /v1/kb is not what was indexed: " + JSON.stringify(j));
    const strip = await texts("#kb-strip .kb-num");
    if (!eq(strip, [String(st.files), String(st.chunks), String(st.sources), st.vector_ready ? "Hybrid" : "Keyword"]))
      fail("the strip " + JSON.stringify(strip) + " is not GET /v1/kb's stats " + JSON.stringify(st));
    const rel = d => d.path.slice(d.root.replace(/[\\/]+$/, "").length + 1);
    const want = j.documents.map(d => [rel(d), d.chunks === 1 ? "1 chunk" : d.chunks + " chunks"])
                  .sort((a, b) => a[0].localeCompare(b[0], undefined, { numeric: true, sensitivity: "base" }));
    const got = await page.$$eval("#kb-docs .kb-doc", rs => rs.map(r => [r.querySelector(".kb-name").textContent, r.querySelector(".kb-tag").textContent]));
    if (!eq(got, want)) fail("the document rows " + JSON.stringify(got) + " are not GET /v1/kb's " + JSON.stringify(want));
    if (!got.some(r => r[0] === "guides/routing.txt" || r[0] === "guides\\routing.txt")) fail("a document in a subfolder is not named inside its source");
    if (!j.documents.every(d => d.mtime > 0)) fail("a document has no mtime");
    const times = await page.$$eval("#kb-docs .kb-doc time", ts => ts.map(t => [t.textContent, t.title]));
    if (!times.every(([t, h]) => t === "just now" && /^Modified .*\d/.test(h))) fail("modified times read " + JSON.stringify(times));
    const roots = await texts("#kb-sources .kb-src code");
    if (!eq(roots, j.sources.map(s => s.root))) fail("the source rows " + JSON.stringify(roots) + " are not GET /v1/kb's");
    const srcMeta = await texts("#kb-sources .kb-src-main span");
    const wantMeta = j.sources.map(s => (s.files === 1 ? "1 document" : s.files + " documents") + " · " + (s.chunks === 1 ? "1 chunk" : s.chunks + " chunks"));
    if (!eq(srcMeta, wantMeta)) fail("the source counts " + JSON.stringify(srcMeta) + " are not " + JSON.stringify(wantMeta));
    if ((await page.textContent("#kb-docs-n")) !== "4") fail("the documents count reads " + await page.textContent("#kb-docs-n"));
    ok("the strip, document rows and source rows are GET /v1/kb's");

    /* ---- the HTML name is text ---- */
    if (!got.some(r => r[0] === EVIL)) fail("the HTML file name is not shown as text");
    if (await page.$$eval("#tab-kb img, #tab-kb script, #kb-docs b", es => es.length)) fail("an element was made from a name");

    /* ---- search ---- */
    await page.fill("#kb-q", "gateway");
    await page.press("#kb-q", "Enter");
    const s = await (await fetch(url + "/v1/kb/search?q=gateway")).json();
    if (s.hits.length < 3) fail("GET /v1/kb/search found " + s.hits.length + " hits");
    await until(async () => (await page.$$("#kb-results .kb-hit")).length === s.hits.length, s.hits.length + " hits");
    const hitNames = await texts("#kb-results .kb-hit .kb-name");
    if (!eq(hitNames.map(base), s.hits.map(h => base(h.path)))) fail("the hits " + JSON.stringify(hitNames) + " are not the route's, in order");
    const chunks = await texts("#kb-results .kb-hit .kb-tag");
    if (!eq(chunks, s.hits.map(h => "chunk " + (h.chunk + 1)))) fail("the hits' chunks read " + JSON.stringify(chunks));
    const ranks = await texts("#kb-results .kb-rank");
    if (!eq(ranks, s.hits.map((_, i) => String(i + 1)))) fail("the ranks read " + JSON.stringify(ranks));
    const scores = await page.$$eval("#kb-results .kb-score", es => es.map(e => [e.lastChild.textContent, e.title]));
    const best = Math.max(...s.hits.map(h => Math.abs(h.score)));
    if (!eq(scores.map(x => x[0]), s.hits.map(h => Math.round(Math.abs(h.score) / best * 100) + "%")) || !/^Score -?\d/.test(scores[0][1]))
      fail("the scores read " + JSON.stringify(scores));
    const marks = await texts("#kb-results .kb-snip mark");
    if (!marks.length || !marks.every(m => m.toLowerCase() === "gateway")) fail("the matches are not marked: " + JSON.stringify(marks));
    if ((await page.textContent("#kb-results-n")) !== s.hits.length + " results") fail("the result count reads " + await page.textContent("#kb-results-n"));
    const evilHit = s.hits.findIndex(h => base(h.path) === EVIL);
    if (evilHit < 0) fail("the HTML document is not a hit");
    const snip = await page.$$eval("#kb-results .kb-snip", ps => ps.map(p => p.textContent));
    if (!snip[evilHit].includes("<script>alert(2)</script>") || !snip[evilHit].includes("<b>bold</b>")) fail("the HTML snippet is not drawn as text: " + snip[evilHit]);
    if (await page.$$eval("#tab-kb img, #tab-kb script, #kb-results b", es => es.length)) fail("an element was made from a name or snippet");
    await sleep(300);
    if (dialogs.length) fail("a dialog opened: " + dialogs.join(" | "));
    ok("search: the route's hits in order, with document, chunk, rank and score, matches marked; HTML names and snippets are text");
    await shot("desktop-dark.png");
    await lite(true);
    await shot("desktop-light.png");
    await lite(false);

    /* ---- replacing an upload asks first ---- */
    await page.setInputFiles("#kb-file", { name: "install-guide.md", mimeType: "text/markdown", buffer: Buffer.from("changed\n") });
    await page.click("#kb-upload-btn");
    await until(async () => /^Not uploaded/.test(await page.textContent("#kb-status")), "the cancelled replace");
    if (dialogs.length !== 1 || !/^confirm: Replace “install-guide\.md”/.test(dialogs[0])) fail("replacing did not ask: " + JSON.stringify(dialogs));
    dialogs.length = 0;
    const again = await (await fetch(url + "/v1/kb/search?q=changed")).json();
    if (again.hits.length) fail("the cancelled replace uploaded anyway");
    ok("uploading a name already there asks first; Cancel keeps the old file");

    /* ---- no hits ---- */
    await page.fill("#kb-q", "zzqqxx");
    await page.press("#kb-q", "Enter");
    await page.waitForSelector("#kb-results .kb-empty");
    if (!/^No matches for “zzqqxx”/.test(await page.textContent("#kb-results .kb-empty b"))) fail("no hits reads " + await page.textContent("#kb-results .kb-empty b"));
    ok("a search with no hits says so");

    /* ---- phone width ---- */
    await page.fill("#kb-q", "gateway");
    await page.press("#kb-q", "Enter");
    await until(async () => (await page.$$("#kb-results .kb-hit")).length === s.hits.length, "the hits again");
    await page.setViewportSize({ width: 390, height: 844 });
    await sleep(200);
    const lay = await page.evaluate(() => {
      const pane = document.querySelector("#kb-pane"), cells = [...document.querySelectorAll("#kb-strip .kb-stat")].map(c => c.getBoundingClientRect());
      return { doc: document.documentElement.scrollWidth, pane: pane.scrollWidth - pane.clientWidth,
               twoByTwo: Math.abs(cells[0].top - cells[1].top) < 1 && cells[2].top > cells[0].top + 10 };
    });
    if (lay.doc > 390 || lay.pane > 0) fail("sideways scroll at phone width: " + JSON.stringify(lay));
    if (!lay.twoByTwo) fail("the strip is not two by two at phone width");
    await shot("phone-dark.png");
    await lite(true);
    await shot("phone-light.png");
    await page.evaluate(() => document.querySelector("#kb-docs").scrollIntoView());
    await shot("phone-light-documents.png");
    await lite(false);
    ok("phone width: the strip two by two, no sideways scroll");

    if (failures) throw new Error(failures + " failure(s)");
    console.log("webui_kb_e2e: OK");
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
