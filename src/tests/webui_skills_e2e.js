#!/usr/bin/env node
/* The web UI's Skills tab, against the real gateway.

   One gateway has six installed skills in workspace/skills/ (knowledge,
   prompt and shell; one with a ClawHub install record whose files still
   match, one whose SKILL.md changed after its record was written, one
   with HTML in its name and description, one with a long description)
   and two skills the agent staged for approval. A second gateway has
   none. Through headless Chromium:

     - GET /v1/skills carries provenance and integrity only where an
       install recorded them;
     - the rows match the route: names in order, the kind, the source
       and the integrity pills;
     - HTML in a skill's name and description is drawn as text;
     - Show all appears for a long description and opens it;
     - the filter narrows the rows and says when nothing matches;
     - the staged skills show the SKILL.md each would save; Approve moves
       one into Installed, Reject asks in the row (Cancel keeps it) and
       then discards it;
     - Remove asks in the row, then deletes the skill's files;
     - install by name and the catalog's Install post the right target,
       and an install error is drawn as text (both against a stubbed
       route: a real install needs the network);
     - a failed list shows an error with Try again;
     - phone width: no sideways scroll;
     - with no skills, the empty state shows.

   Needs node with Playwright and a Chromium; skips without them.
   SKILLS_SHOTS=<dir> also writes screenshots there.
   usage: node webui_skills_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_skills_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const shots = process.env.SKILLS_SHOTS || "";
if (shots) fs.mkdirSync(shots, { recursive: true });

let failures = 0, gwLog = "";
const fail = msg => { console.log("FAIL: " + msg); failures++; throw new Error(msg); };
const ok = msg => console.log("  ok: " + msg);
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, what, ms = 12000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch {} await sleep(50); }
  fail("timed out waiting for " + what);
}
function freePort() {
  return new Promise(r => { const s = http.createServer().listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => r(p)); }); });
}

const XSS_NAME = '<img src=x onerror="window.__skXss=1">';
const XSS_DESC = '<b>bold</b> & <script>window.__skXss=2</script>';
const LONG_DESC = "Checks a deployment end to end before a release is promoted. "
  + "It reads health endpoints, recent logs, error budgets and rollout status in every region. ".repeat(5) + "END-OF-DESC";
const PEND_CONTENT = "---\nname: csv-cleanup\ndescription: Normalize CSV headers and drop duplicate rows.\n---\n"
  + "# CSV cleanup\n\n1. Trim and lower-case the headers.\n2. Drop rows that repeat exactly.\n";
const sha = b => crypto.createHash("sha256").update(b).digest("hex");

function writeSkill(home, dir, fm, body) {
  const d = path.join(home, "workspace", "skills", dir);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, "SKILL.md"),
    "---\n" + Object.entries(fm).map(([k, v]) => k + ": " + v).join("\n") + "\n---\n" + body);
  return d;
}
/* What a ClawHub install writes: every file's size and digest. */
function writeRecord(dir, slug, version) {
  const files = fs.readdirSync(dir).filter(f => f !== ".provenance.json").map(f => {
    const b = fs.readFileSync(path.join(dir, f));
    return { path: f, size: b.length, sha256: sha(b) };
  });
  fs.writeFileSync(path.join(dir, ".provenance.json"), JSON.stringify({ schema: 1, source: "clawhub", slug, version,
    archive_sha256: sha(slug + version), installed_at: "2026-11-20T09:30:00Z", files }));
}
function stage(home, id, name, content, created) {
  const d = path.join(home, "workspace", "skills", ".pending", id);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, "SKILL.md"), content);
  fs.writeFileSync(path.join(d, "meta.json"), JSON.stringify({ id, action: "create", name, source: "agent", created }));
}

async function startGateway(fill, tag) {
  const port = await freePort();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-skills-" + tag + "-"));
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify({
    gateway: { port, bind_addr: "127.0.0.1" },
    providers: [{ name: "fake", kind: "openai", api_base: "http://127.0.0.1:9/v1", api_key: "sk-test", model: "m" }],
    default_provider: "fake", default_model: "m" }));
  if (fill) fill(home);
  const proc = spawn(binary, ["gateway", "--port", String(port), "--addr", "127.0.0.1", "--no-mcp"],
                     { cwd: home, env: Object.assign({}, process.env, { PASCLAW_HOME: home }), stdio: ["ignore", "pipe", "pipe"] });
  proc.stdout.on("data", d => gwLog += d); proc.stderr.on("data", d => gwLog += d);
  const base = `http://127.0.0.1:${port}`;
  await until(async () => (await fetch(base + "/v1/health")).ok, "the " + tag + " gateway");
  return { base, home, proc };
}

function fillSkills(home) {
  writeRecord(writeSkill(home, "daily-brief", { name: "daily-brief", kind: "prompt", prompt: "Brief me on $ARGUMENTS",
    description: "Summarize the inbox, calendar and GitHub notifications into a morning brief." }, "# Daily brief\n"), "daily-brief", "1.2.0");
  const dc = writeSkill(home, "deploy-check", { name: "deploy-check", kind: "shell", shell: "echo ok", description: LONG_DESC }, "Run first.\n");
  writeRecord(dc, "deploy-check", "0.4.1");
  fs.appendFileSync(path.join(dc, "SKILL.md"), "\nedited after install\n");
  writeSkill(home, "pdf-notes", { name: "pdf-notes", description: "How to read and annotate PDFs with fs_read." }, "# PDF notes\n");
  writeSkill(home, "html-name", { name: XSS_NAME, description: XSS_DESC }, "body\n");
  writeSkill(home, "git-hygiene", { name: "git-hygiene", description: "Branch, commit and rebase conventions for this team." }, "x\n");
  writeSkill(home, "release-notes", { name: "release-notes", kind: "prompt", prompt: "Write notes for $1",
    description: "Draft release notes from merged pull requests." }, "x\n");
  const h = new Date(Date.now() - 3 * 3600 * 1000).toISOString().replace(/\.\d+Z$/, "Z");
  stage(home, "p-approve", "csv-cleanup", PEND_CONTENT, h);
  stage(home, "p-reject", "scratch-draft", "---\nname: scratch-draft\ndescription: A half-finished idea.\n---\nTODO\n", h);
}

(async () => {
  const A = await startGateway(fillSkills, "skills");
  const B = await startGateway(null, "empty");
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: "dark" });
  const page = await ctx.newPage();
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  page.on("dialog", d => { console.log("FAIL: unexpected dialog: " + d.message()); failures++; d.dismiss(); });
  const shot = async name => { if (shots) await page.screenshot({ path: path.join(shots, name), fullPage: true }); };
  const routeSkills = async () => (await (await fetch(A.base + "/v1/skills")).json()).skills;
  const routePending = async () => (await (await fetch(A.base + "/v1/skills/pending")).json()).pending;
  const instRows = () => page.locator("#skills-pane .sk-inst");
  const rowNamed = n => page.locator("#skills-pane .sk-inst").filter({ has: page.locator(".sk-name", { hasText: n }) });

  try {
    /* ---- the route ---- */
    const route = await routeSkills();
    if (!Array.isArray(route) || route.length !== 6) fail("GET /v1/skills: " + JSON.stringify(route));
    const by = n => route.find(s => s.name === n);
    const db = by("daily-brief"), dc = by("deploy-check"), pn = by("pdf-notes");
    if (!db.provenance || db.provenance.source !== "clawhub" || db.provenance.version !== "1.2.0" || db.integrity !== "ok")
      fail("daily-brief provenance: " + JSON.stringify(db));
    if (dc.integrity !== "modified") fail("deploy-check integrity: " + dc.integrity);
    if ("provenance" in pn || "integrity" in pn) fail("a skill with no record has provenance: " + JSON.stringify(pn));
    ok("GET /v1/skills: provenance and integrity where an install recorded them, absent elsewhere");

    await page.goto(A.base + "/#skills");
    await until(async () => (await instRows().count()) === 6, "the skill rows");
    await until(async () => (await page.locator("#sk-pending .sk-pend").count()) === 2, "the staged rows");
    await shot("skills-desktop-dark.png");

    /* ---- the rows match the route ---- */
    const rows = await page.$$eval("#skills-pane .sk-inst", rs => rs.map(r => ({
      name: r.querySelector(".sk-name").textContent,
      kind: r.querySelector(".sk-kind").textContent,
      src: (r.querySelector(".sk-src") || {}).textContent || "",
      integ: (r.querySelector(".sk-integrity") || {}).textContent || "",
      desc: r.querySelector(".sk-desc").textContent })));
    const kinds = { "": "Knowledge", prompt: "Prompt", shell: "Shell" };
    route.forEach((s, i) => {
      const r = rows[i];
      if (r.name !== s.name) fail(`row ${i} name ${JSON.stringify(r.name)}, route ${JSON.stringify(s.name)}`);
      if (r.kind !== kinds[s.kind]) fail(`row ${s.name} kind ${r.kind}`);
      if (r.desc !== (s.description || "No description.")) fail(`row ${s.name} description ${JSON.stringify(r.desc)}`);
      const wantSrc = s.provenance ? "ClawHub v" + s.provenance.version : "";
      if (r.src !== wantSrc) fail(`row ${s.name} source ${JSON.stringify(r.src)}`);
      const wantInteg = { ok: "Unchanged since install", modified: "Changed since install" }[s.integrity] || "";
      if (r.integ !== wantInteg) fail(`row ${s.name} integrity ${JSON.stringify(r.integ)}`);
    });
    if ((await page.textContent("#sk-n")).trim() !== "6") fail("the count reads " + await page.textContent("#sk-n"));
    ok("rows match the route: names in order, kind, source and integrity pills");

    /* ---- HTML is text ---- */
    const html = await page.evaluate(() => [window.__skXss,
      document.querySelectorAll("#tab-skills .sk-list img, #tab-skills .sk-list b:not(.sk-confirm b), #tab-skills .sk-list script").length]);
    if (html[0] !== undefined || html[1] !== 0) fail("HTML in a skill rendered as markup: " + html);
    if (!rows.some(r => r.name === XSS_NAME && r.desc === XSS_DESC)) fail("the HTML name or description is not shown verbatim");
    ok("HTML in a skill's name and description is drawn as text");

    /* ---- Show all, details ---- */
    const dcRow = rowNamed("deploy-check");
    const more = dcRow.locator(".sk-more");
    if (!(await more.isVisible())) fail("no Show all on a long description");
    if (await rowNamed("pdf-notes").locator(".sk-more").isVisible()) fail("Show all on a one-line description");
    const clipped = await dcRow.locator(".sk-desc").evaluate(d => d.scrollHeight > d.clientHeight + 1);
    await more.click();
    const open = await dcRow.locator(".sk-desc").evaluate(d => d.scrollHeight <= d.clientHeight + 1);
    if (!clipped || !open || (await more.textContent()) !== "Show less") fail("Show all did not open the description");
    await rowNamed("daily-brief").locator(".sk-det summary").click();
    const facts = (await rowNamed("daily-brief").locator(".sk-facts").textContent()).replace(/\s+/g, " ");
    if (!facts.includes(db.path) || !/ClawHub · daily-brief · v1\.2\.0/.test(facts)) fail("details: " + facts);
    await shot("skills-details-desktop-dark.png");
    ok("a long description is clamped and Show all opens it; Details shows the file and source");

    /* ---- filter ---- */
    if (!(await page.isVisible("#sk-filter"))) fail("no filter with six skills");
    await page.fill("#sk-filter", "DEPLOY");
    if ((await page.locator("#skills-pane .sk-inst:visible").count()) !== 1 || (await page.textContent("#sk-n")) !== "1 of 6")
      fail("the filter did not narrow to deploy-check");
    await page.fill("#sk-filter", "zzz-nothing");
    if (!(await page.isVisible("#skills-pane .sk-nomatch")) || (await page.locator("#skills-pane .sk-inst:visible").count()) !== 0)
      fail("no message when nothing matches the filter");
    await page.fill("#sk-filter", "");
    if ((await page.locator("#skills-pane .sk-inst:visible").count()) !== 6 || await page.isVisible("#skills-pane .sk-nomatch"))
      fail("clearing the filter did not bring the rows back");
    ok("the filter narrows rows by name or description and says when nothing matches");

    /* ---- staged: preview, approve ---- */
    const pre = await page.locator('#sk-pending .sk-pend[data-id="p-approve"] .sk-pre').textContent();
    if (pre !== PEND_CONTENT) fail("the staged SKILL.md preview: " + JSON.stringify(pre));
    const staged = (await page.locator('#sk-pending .sk-pend[data-id="p-approve"] .sk-time').textContent());
    if (staged !== "staged 3 h ago") fail("staged time reads " + staged);
    await page.click('#sk-pending .sk-pend[data-id="p-approve"] .sk-approve');
    await until(async () => (await routePending()).length === 1, "the approved skill to leave the queue");
    await until(async () => (await rowNamed("csv-cleanup").count()) === 1, "csv-cleanup among the installed");
    if (!/Approved csv-cleanup/.test(await page.textContent("#skill-status"))) fail("status after approve: " + await page.textContent("#skill-status"));
    ok("the staged SKILL.md is shown as text; Approve moves it into Installed");

    /* ---- reject asks first ---- */
    const rej = page.locator('#sk-pending .sk-pend[data-id="p-reject"]');
    await rej.locator(".sk-reject").click();
    if (!(await rej.locator(".sk-confirm").isVisible())) fail("Reject did not ask first");
    await shot("skills-reject-confirm-desktop-dark.png");
    await rej.locator(".sk-cancel").click();
    if (await rej.locator(".sk-confirm").isVisible() || (await routePending()).length !== 1) fail("Cancel did not keep the staged skill");
    await rej.locator(".sk-reject").click();
    await rej.locator(".sk-go").click();
    await until(async () => (await routePending()).length === 0, "the rejected skill to go");
    await until(async () => await page.isHidden("#sk-pend-sec"), "the staged section to close");
    await shot("skills-installed-desktop-dark.png");
    ok("Reject asks in the row; Cancel keeps it, confirming discards it");

    /* ---- remove asks first ---- */
    const pnRow = rowNamed("pdf-notes");
    await pnRow.locator(".sk-remove").click();
    if (!(await pnRow.locator(".sk-confirm").isVisible())) fail("Remove did not ask first");
    if (!(await routeSkills()).some(s => s.name === "pdf-notes")) fail("Remove deleted before the confirm");
    await shot("skills-remove-confirm-desktop-dark.png");
    await pnRow.locator(".sk-go").click();
    await until(async () => !(await routeSkills()).some(s => s.name === "pdf-notes"), "pdf-notes to be removed");
    await until(async () => (await rowNamed("pdf-notes").count()) === 0, "the pdf-notes row to go");
    if (fs.existsSync(path.join(A.home, "workspace", "skills", "pdf-notes"))) fail("pdf-notes' folder is still there");
    ok("Remove asks in the row, then deletes the skill's files");

    /* ---- install by name and from the catalog (stubbed routes) ---- */
    const posted = [];
    await page.route("**/v1/skills", async r => {
      if (r.request().method() !== "POST") return r.continue();
      const t = JSON.parse(r.request().postData() || "{}").target;
      posted.push(t);
      if (t === "bad/target") return r.fulfill({ status: 502, contentType: "application/json",
        body: JSON.stringify({ error: "<i>no such repo</i>" }) });
      return r.fulfill({ status: 200, contentType: "application/json",
        body: JSON.stringify({ installed: t.replace(/^.*[:/]/, ""), note: "installed" }) });
    });
    await page.route("**/v1/skills/search?**", r => r.fulfill({ status: 200, contentType: "application/json",
      body: JSON.stringify({ results: [
        { slug: "weather", display_name: "<u>Weather</u>", summary: "Forecasts by city.", version: "2.0.0", source: "clawhub", score: 1 },
        { slug: "daily-brief", display_name: "Daily brief", summary: "Already here.", version: "1.2.0", source: "hub", score: .5 }] }) }));
    await page.fill("#skill-target", "bad/target");
    await page.click("#skill-install-btn");
    await until(async () => /Couldn't install bad\/target: <i>no such repo<\/i>/.test(await page.textContent("#skill-status")), "the install error");
    if (await page.locator("#skill-status i").count()) fail("the install error rendered as markup");
    await page.fill("#skill-target", "owner/repo");
    await page.click("#skill-install-btn");
    await until(async () => /Installed repo\./.test(await page.textContent("#skill-status")), "the install success");
    if ((await page.inputValue("#skill-target")) !== "") fail("the install field was not cleared");
    await page.fill("#skill-q", "weather");
    await page.click("#skill-search-btn");
    await until(async () => (await page.locator("#skill-catalog .sk-cat").count()) === 2, "the catalog results");
    if ((await page.textContent("#skill-catalog .sk-cat .sk-name")) !== "<u>Weather</u>" || await page.locator("#skill-catalog u").count())
      fail("a catalog name rendered as markup");
    if (!(await page.locator("#skill-catalog .sk-cat").nth(1).locator(".sk-install").isDisabled())) fail("an installed skill offers Install");
    await shot("skills-catalog-desktop-dark.png");
    await page.locator("#skill-catalog .sk-cat").first().locator(".sk-install").click();
    await until(async () => /Installed weather\./.test(await page.textContent("#skill-status"))
                            && (await page.locator("#skill-catalog .sk-cat").first().locator(".sk-install").textContent()) === "Installed"
                            && await page.isEnabled("#sk-refresh"), "the catalog install");
    if (JSON.stringify(posted) !== JSON.stringify(["bad/target", "owner/repo", "clawhub:weather"])) fail("posted targets: " + posted);
    ok("install by name and the catalog's Install post the right target; errors are text");
    await page.unrouteAll({ behavior: "wait" });

    /* ---- a failed list ---- */
    await page.route("**/v1/skills", r => r.request().method() === "GET"
      ? r.fulfill({ status: 500, contentType: "application/json", body: '{"error":"disk on fire"}' }) : r.continue());
    await page.click("#sk-refresh");
    await until(async () => /Couldn't load the skills: disk on fire/.test(await page.textContent("#skills-pane")), "the error state");
    await page.unrouteAll({ behavior: "wait" });
    await page.click("#skills-pane [data-sk-retry]");
    await until(async () => (await instRows().count()) === 6, "the rows after Try again");
    ok("a failed list shows the error and Try again reloads");

    /* ---- light theme, phone width ---- */
    await page.click("#skill-status .sk-status-x");
    if (!(await page.isHidden("#skill-status"))) fail("the status banner did not dismiss");
    await page.click("#theme-btn");
    await sleep(400);
    await shot("skills-desktop-light.png");
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto(A.base + "/#skills");
    await until(async () => (await instRows().count()) === 6, "the rows again");
    const sw = await page.evaluate(() => [document.documentElement.scrollWidth, document.querySelector("#sk-pane").scrollWidth,
                                          document.querySelector("#sk-pane").clientWidth]);
    if (sw[0] > 390 || sw[1] > sw[2]) fail("sideways scroll at phone width: " + sw);
    await shot("skills-phone-light.png");
    await page.click("#theme-btn");
    await sleep(400);
    await shot("skills-phone-dark.png");
    ok("phone width: no sideways scroll");

    /* ---- no skills ---- */
    await page.goto(B.base + "/#skills");
    await until(async () => await page.isVisible("#skills-pane .sk-empty"), "the empty state");
    const empty = (await page.textContent("#skills-pane")).replace(/\s+/g, " ");
    if (!/No skills installed/.test(empty) || (await instRows().count()) !== 0) fail("empty state: " + empty);
    if (!(await page.isHidden("#sk-pend-sec")) || !(await page.isHidden("#sk-filter-wrap"))) fail("the staged section or filter shows with no skills");
    const sw2 = await page.evaluate(() => document.documentElement.scrollWidth);
    if (sw2 > 390) fail("sideways scroll in the empty state: " + sw2);
    await shot("skills-empty-phone-dark.png");
    await page.click("#theme-btn");
    await sleep(400);
    await shot("skills-empty-phone-light.png");
    await page.setViewportSize({ width: 1280, height: 900 });
    await shot("skills-empty-desktop-light.png");
    await page.click("#theme-btn");
    await sleep(400);
    await shot("skills-empty-desktop-dark.png");
    ok("with no skills, the empty state shows");
  } catch (e) {
    if (!failures) { console.log("FAIL: " + (e && e.stack || e)); failures++; }
  } finally {
    await browser.close();
    A.proc.kill(); B.proc.kill();
    for (const g of [A, B]) try { fs.rmSync(g.home, { recursive: true, force: true }); } catch {}
  }
  if (failures) {
    console.log("--- gateway log (tail) ---\n" + gwLog.split("\n").slice(-30).join("\n"));
    process.exit(1);
  }
  console.log("webui_skills_e2e: all checks passed");
})();
