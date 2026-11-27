#!/usr/bin/env node
/* The web UI's Memory tab, against the real gateway.

   A gateway starts in a home whose workspace/memory/ holds MEMORY.md
   (Markdown with a table and code), two daily notes (one five days old), a
   long note, and a note whose name and content are HTML; three facts go in
   through POST /v1/memory/facts, one of them HTML. Through headless
   Chromium:

     - Notes lists GET /v1/memory's files, newest first, each with its size
       and modified time; the tab's counts and the footer match the routes;
     - a note opens with its name, size and age; Markdown renders, Source
       shows the text GET /v1/memory/<name> returns, and Copy copies it;
     - search shows GET /v1/memory/search's matches with the matched words
       marked, a match opens its note, and Clear brings the list back;
     - Facts lists GET /v1/memory/facts with kind, scope and id, says that
       distillation is off, Remember adds one, Forget removes one, and
       Export downloads the Markdown; Search setup reads the provision state;
     - the HTML name, note and fact are drawn as text: no element is made
       from them and no dialog opens;
     - a note that cannot be read shows the server's reason;
     - with no notes and no facts, both empty states show;
     - phone width: the list sits above the note, no sideways scroll.

   Needs node with Playwright and a Chromium; skips without them.
   MEMORY_SHOTS=<dir> also writes dark, light, phone and empty screenshots.
   usage: node webui_memory_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_memory_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const shots = process.env.MEMORY_SHOTS || "";
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

const EVIL = "<img src=x onerror=alert(1)>.md";
const EVIL_BODY = "<script>alert(2)</script>\n\n<b>bold?</b> <img src=x onerror=alert(4)>\n";
const EVIL_FACT = "<img src=x onerror=alert(3)> likes <b>tags</b>";
const MEMORY = "# Long-term memory\n\n## Preferences\n\n- Prefers **Free Pascal** for CI builds.\n- Writes commit messages in the imperative.\n\n" +
               "| Project | Status |\n|---|---|\n| PasClaw | active |\n\n```pascal\nwriteln('hello');\n```\n";
const LONG = "# A long note\n\n" + Array.from({ length: 80 }, (_, i) => "Paragraph " + (i + 1) + ": the agent keeps this between chats.").join("\n\n") + "\n";
const FACTS = ["The user's name is Sam.", "Deploys go out on Thursdays.", EVIL_FACT];

(async () => {
  const port = await freePort();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-memory-"));
  const mem = path.join(home, "workspace", "memory");
  fs.mkdirSync(mem, { recursive: true });
  fs.writeFileSync(path.join(mem, "MEMORY.md"), MEMORY);
  fs.writeFileSync(path.join(mem, "2026-11-20.md"), "# 2026-11-20\n\n- Reviewed the gazebo plans.\n");
  fs.writeFileSync(path.join(mem, "2026-11-27.md"), "# 2026-11-27\n\nWorking on the Memory tab.\n");
  fs.writeFileSync(path.join(mem, "long-note.md"), LONG);
  fs.writeFileSync(path.join(mem, EVIL), EVIL_BODY);
  const old = Date.now() / 1000 - 5 * 86400;
  fs.utimesSync(path.join(mem, "2026-11-20.md"), old, old);
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify({
    gateway: { port, bind_addr: "127.0.0.1" },
    providers: [{ name: "fake", kind: "openai", api_base: "http://127.0.0.1:9/v1", api_key: "sk-test", model: "m" }],
    default_provider: "fake", default_model: "m" }));
  const proc = spawn(binary, ["gateway", "--port", String(port), "--addr", "127.0.0.1", "--no-mcp"],
                     { cwd: home, env: Object.assign({}, process.env, { PASCLAW_HOME: home }), stdio: ["ignore", "pipe", "pipe"] });
  proc.stdout.on("data", d => gwLog += d); proc.stderr.on("data", d => gwLog += d);
  const base = `http://127.0.0.1:${port}`;
  await until(async () => (await fetch(base + "/v1/health")).ok, "the gateway");
  const getJ = async p => (await fetch(base + p)).json();
  for (const text of FACTS) {
    const r = await fetch(base + "/v1/memory/facts", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ text }) });
    if (!r.ok) fail("could not seed a fact: HTTP " + r.status);
  }

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: "dark", acceptDownloads: true,
                                         permissions: ["clipboard-read", "clipboard-write"] });
  const page = await ctx.newPage();
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  let dialogs = 0;
  page.on("dialog", d => { dialogs++; d.dismiss(); });
  /* A short settle first: the tab underline animates. */
  const shot = async name => { if (shots) { await sleep(250); await page.screenshot({ path: path.join(shots, name) }); } };
  const names = () => page.$$eval("#mem-list .mem-row .mem-name span", s => s.map(x => x.textContent));
  const row = name => page.locator("#mem-list .mem-row").filter({ has: page.locator(".mem-name span", { hasText: name }) }).first();
  const openNote = async name => { await row(name).click(); await until(async () => (await page.textContent("#mem-vname")) === name, name + " in the reader"); };
  const sub = async s => { await page.click(`#mem-subtabs [data-sub=${s}]`); await until(async () => page.isVisible("#subpane-" + s), s + " shown"); };
  const factTexts = () => page.$$eval("#facts-list .mem-fact-text", s => s.map(x => x.textContent));

  try {
    await page.goto(base + "/#memory");
    await page.waitForSelector("#mem-list .mem-row");

    /* ---- the list is the route's, newest first ---- */
    const j = await getJ("/v1/memory");
    if (!j.files.every(f => typeof f.mtime === "number" && f.mtime > 0)) fail("a file has no mtime: " + JSON.stringify(j.files));
    const want = j.files.slice().sort((a, b) => (b.mtime - a.mtime) || a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" }))
                  .map(f => f.name);
    if (!eq(await names(), want)) fail("the list " + JSON.stringify(await names()) + " is not the route's " + JSON.stringify(want));
    if (want[want.length - 1] !== "2026-11-20.md") fail("the five-day-old note is not last: " + JSON.stringify(want));
    const oldRow = row("2026-11-20.md");
    if ((await oldRow.locator(".mem-mod").textContent()) !== "5 d ago") fail("the old note's age reads " + await oldRow.locator(".mem-mod").textContent());
    if (!/^Modified .*\d/.test(await oldRow.locator(".mem-mod").getAttribute("title") || "")) fail("no exact modified time on hover");
    const memSize = j.files.find(f => f.name === "MEMORY.md").size;
    if (memSize !== Buffer.byteLength(MEMORY)) fail("the route's MEMORY.md size is " + memSize);
    if ((await row("MEMORY.md").locator(".mem-size").textContent()) !== memSize + " B") fail("MEMORY.md's size reads " + await row("MEMORY.md").locator(".mem-size").textContent());
    if ((await page.textContent("#mem-n-notes")) !== String(want.length)) fail("the Notes count reads " + await page.textContent("#mem-n-notes"));
    if (!new RegExp("^" + want.length + " notes · ").test(await page.textContent("#mem-foot"))) fail("the footer reads " + await page.textContent("#mem-foot"));
    if (!/No note open/.test(await page.textContent("#mem-view"))) fail("the reader does not say no note is open");
    ok("Notes lists GET /v1/memory's files newest first, with size, age and counts");

    /* ---- a note ---- */
    await openNote("MEMORY.md");
    await until(async () => (await page.$("#mem-view .mem-md h1")) !== null, "MEMORY.md rendered");
    if ((await page.textContent("#mem-view .mem-md h1")) !== "Long-term memory") fail("the heading reads " + await page.textContent("#mem-view .mem-md h1"));
    if (!(await page.$("#mem-view .mem-md table")) || !(await page.$("#mem-view .mem-md pre code"))) fail("the table or the code block did not render");
    if (!/^workspace\/memory · \d+ B · modified /.test(await page.textContent("#mem-vmeta"))) fail("the reader's meta reads " + await page.textContent("#mem-vmeta"));
    if ((await page.getAttribute("#mem-list .mem-row[aria-current=true]", "data-name")) !== "MEMORY.md") fail("the open note is not marked in the list");
    const r1 = await getJ("/v1/memory/MEMORY.md");
    await page.click("#mem-mdseg [data-md=source]");
    await until(async () => (await page.textContent("#mem-view .mem-src")) === r1.content, "Source to show the route's content");
    await page.click("#mem-copy");
    await until(async () => (await page.evaluate(() => navigator.clipboard.readText())) === r1.content, "Copy to put the note on the clipboard");
    await page.click("#mem-mdseg [data-md=preview]");
    await until(async () => (await page.$("#mem-view .mem-md h1")) !== null, "Preview again");
    await shot("desktop-dark-notes.png");
    ok("a note opens with its meta; Markdown renders, Source is the route's text, Copy copies it");

    /* ---- search ---- */
    const sj = await getJ("/v1/memory/search?q=gazebo");
    const wantHits = sj.hits.map(h => path.basename(h.path));
    if (!eq(wantHits, ["2026-11-20.md"])) fail("the search route found " + JSON.stringify(wantHits));
    await page.fill("#mem-q", "gazebo");
    await page.press("#mem-q", "Enter");
    await until(async () => eq(await names(), wantHits), "the search's matches");
    if ((await page.textContent("#mem-list .mem-snip mark")).toLowerCase() !== "gazebo") fail("the matched word is not marked");
    if (!/^1 match for “gazebo”/.test(await page.textContent("#mem-hits-n"))) fail("the matches line reads " + await page.textContent("#mem-hits-n"));
    if (await page.isVisible("#mem-cols")) fail("the column header shows with search results");
    await row("2026-11-20.md").click();
    await until(async () => (await page.textContent("#mem-vname")) === "2026-11-20.md", "a match to open its note");
    await page.fill("#mem-q", "zzzunfound");
    await page.press("#mem-q", "Enter");
    await until(async () => /No matches/.test(await page.textContent("#mem-list")), "the no-matches state");
    await page.click("#mem-clear");
    await until(async () => eq(await names(), want), "Clear to bring the list back");
    ok("search lists the route's matches with the word marked, opens a match, and Clear restores the list");

    /* ---- HTML in a name and in content stays text ---- */
    await openNote(EVIL);
    await until(async () => /alert\(2\)/.test(await page.textContent("#mem-view") || ""), "the HTML note's text");
    if ((await page.getAttribute("#mem-list .mem-row[aria-current=true] .mem-name span", "title")) !== EVIL) fail("the HTML name is not shown as text in the list");
    if ((await page.textContent("#mem-vname")) !== EVIL) fail("the HTML name is not shown as text in the reader");
    const made = await page.evaluate(() => document.querySelectorAll("#tab-memory img, #tab-memory script, #mem-view b, #mem-list b").length);
    if (made) fail(made + " element(s) made from the HTML name or content");
    await page.click("#mem-mdseg [data-md=source]");
    await until(async () => (await page.textContent("#mem-view .mem-src")) === EVIL_BODY, "the HTML note's source");
    await page.click("#mem-mdseg [data-md=preview]");
    ok("an HTML note name and its content are drawn as text");

    /* ---- a note that cannot be read ---- */
    await page.evaluate(() => memOpen("gone.md"));
    await until(async () => /Can't open this note\s*not found/.test(await page.textContent("#mem-view") || ""), "the error state");
    await page.evaluate(() => memClose());
    ok("a note that cannot be read shows the server's reason");

    /* ---- facts ---- */
    await sub("facts");
    const fj = await getJ("/v1/memory/facts");
    await until(async () => eq(await factTexts(), fj.facts.map(f => f.text)), "the facts to match the route");
    if (fj.facts.length !== FACTS.length) fail("the route has " + fj.facts.length + " facts");
    if ((await page.textContent("#mem-n-facts")) !== String(fj.facts.length)) fail("the Facts count reads " + await page.textContent("#mem-n-facts"));
    const meta0 = await page.textContent("#facts-list .mem-fact .mem-fact-meta");
    if (meta0.indexOf(fj.facts[0].kind) < 0 || meta0.indexOf(fj.facts[0].scope) < 0 || meta0.indexOf("#" + fj.facts[0].id) < 0)
      fail("the first fact's meta reads " + meta0);
    if (fj.enabled || !(await page.isVisible("#facts-off"))) fail("the distillation-off note is not shown (enabled=" + fj.enabled + ")");
    const madeF = await page.evaluate(() => document.querySelectorAll("#facts-list img, #facts-list b").length);
    if (madeF) fail(madeF + " element(s) made from the HTML fact");
    await shot("desktop-dark-facts.png");

    await page.fill("#facts-text", "Prefers tea over coffee.");
    await page.click("#facts-add-btn");
    await until(async () => (await factTexts()).includes("Prefers tea over coffee."), "the new fact in the list");
    if (!(await getJ("/v1/memory/facts")).facts.some(f => f.text === "Prefers tea over coffee.")) fail("Remember did not reach the route");
    if ((await page.inputValue("#facts-text")) !== "") fail("the input was not cleared");

    const victim = (await getJ("/v1/memory/facts")).facts.find(f => f.text === "Deploys go out on Thursdays.");
    await page.click(`#facts-list .mem-fact[data-id="${victim.id}"] .mem-forget`);
    await until(async () => !(await factTexts()).includes(victim.text), "the forgotten fact to leave the list");
    if ((await getJ("/v1/memory/facts")).facts.some(f => f.id === victim.id)) fail("Forget did not reach the route");
    if (!new RegExp("Forgot fact #" + victim.id).test(await page.textContent("#facts-msg"))) fail("no note after Forget: " + await page.textContent("#facts-msg"));

    const [dl] = await Promise.all([page.waitForEvent("download"), page.click("#facts-export")]);
    if (dl.suggestedFilename() !== "memory-facts.md") fail("the export is named " + dl.suggestedFilename());
    const exported = fs.readFileSync(await dl.path(), "utf8");
    if (exported.indexOf("Prefers tea over coffee.") < 0 || exported.indexOf(victim.text) >= 0) fail("the export does not match the facts:\n" + exported);
    ok("Facts lists the route's facts with kind, scope and id; Remember, Forget and Export work");

    /* ---- search setup ---- */
    await sub("setup");
    const pj = await getJ("/v1/memory/provision");
    await until(async () => (await page.isChecked("#ms-vector")) === !!pj.vector_search_enabled &&
                             /downloaded|not downloaded/.test(await page.textContent("#ms-embed-note")), "the setup to load");
    ok("Search setup reads GET /v1/memory/provision");

    await sleep(300);
    if (dialogs) fail("a dialog opened");

    /* ---- light theme ---- */
    if (shots) {
      await page.emulateMedia({ colorScheme: "light" });
      await page.evaluate(() => document.documentElement.classList.add("lite"));
      await sub("notes");
      await openNote("MEMORY.md");
      await until(async () => (await page.$("#mem-view .mem-md h1")) !== null, "MEMORY.md in light");
      await shot("desktop-light-notes.png");
      await sub("facts");
      await shot("desktop-light-facts.png");
      await page.evaluate(() => document.documentElement.classList.remove("lite"));
      await page.emulateMedia({ colorScheme: "dark" });
    }

    /* ---- phone width ---- */
    await page.setViewportSize({ width: 390, height: 844 });
    await sub("notes");
    await openNote("long-note.md");
    await until(async () => (await page.$("#mem-view .mem-md h1")) !== null, "the long note");
    await sleep(200);
    const lay = await page.evaluate(() => {
      const s = document.querySelector(".mem-side").getBoundingClientRect(), v = document.querySelector(".mem-view").getBoundingClientRect();
      return { stacked: s.bottom <= v.top + 1 && v.height > 200, wide: document.documentElement.scrollWidth };
    });
    if (!lay.stacked) fail("at phone width the list is not above the note: " + JSON.stringify(lay));
    if (lay.wide > 390) fail("sideways scroll at phone width on Notes: " + lay.wide);
    await shot("phone-dark-notes.png");
    for (const s of ["facts", "setup"]) {
      await sub(s);
      const w = await page.evaluate(() => document.documentElement.scrollWidth);
      if (w > 390) fail("sideways scroll at phone width on " + s + ": " + w);
    }
    await sub("facts");
    await shot("phone-dark-facts.png");
    await sub("notes");
    await page.click("#mem-close");
    await until(async () => page.isHidden(".mem-view"), "the reader closed");
    ok("phone width: the list above the note, no sideways scroll, close gives the height back");

    /* ---- empty ---- */
    for (const f of fs.readdirSync(mem)) fs.rmSync(path.join(mem, f), { force: true });
    for (const f of (await getJ("/v1/memory/facts")).facts) await fetch(base + "/v1/memory/facts/" + f.id, { method: "DELETE" });
    await page.click("#mem-refresh");
    await until(async () => /No notes yet/.test(await page.textContent("#mem-list") || ""), "the notes empty state");
    if ((await page.textContent("#mem-n-notes")) !== "0") fail("the Notes count reads " + await page.textContent("#mem-n-notes"));
    if ((await page.textContent("#mem-foot")) !== "") fail("the footer reads " + await page.textContent("#mem-foot"));
    await shot("phone-dark-empty.png");
    await sub("facts");
    await until(async () => /No facts yet/.test(await page.textContent("#facts-list") || ""), "the facts empty state");
    if (!(await page.isDisabled("#facts-export"))) fail("Export is on with no facts");
    await page.setViewportSize({ width: 1280, height: 900 });
    await sub("notes");
    await shot("desktop-dark-empty.png");
    ok("with no notes and no facts, both empty states show");

    if (failures) throw new Error(failures + " failure(s)");
    console.log("webui_memory_e2e: OK");
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
