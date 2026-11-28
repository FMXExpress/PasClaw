#!/usr/bin/env node
/* The Workflow tab's argument form and what a run produced, against the
   real gateway.

   The gateway runs fake_media_mcp.js as the MCP server "fakemedia": its
   predict tool has a rich input schema and answers with a Replicate-shaped
   prediction whose output is the URLs it is given; this test serves those
   (a PNG, an MP4's bytes, a WAV) from its own HTTP server. The workflow is
   gen (an image) -> up (an image, a video, an audio file) -> Outputs, and a
   say step that answers with markdown. Through headless Chromium:

     - a step's settings show one field per schema property, of the kind
       the property's type asks for, marked required, with the description
       as a hint and the default as the placeholder;
     - a form edit reaches the JSON and the save; a template in a number
       field is saved as the template; an edit of the JSON reaches the
       form; invalid JSON shows its error and leaves the form;
     - after a run: a thumbnail on each step's card and on the Outputs box,
       <img>/<video controls>/<audio controls> in the results, the
       prediction's summary line, markdown text rendered; the lightbox
       opens, Esc and the close button close it; the Outputs box opens
       its values; a step's card shows its last result;
     - a javascript: URL in a result is never media or a link, and every
       media element has referrerpolicy=no-referrer.

   Needs node with Playwright and a Chromium; skips without them.
   WF_SHOTS=<dir> also writes screenshots there.
   usage: node webui_workflow_media_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const zlib = require("zlib");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_workflow_media_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }
const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const shots = process.env.WF_SHOTS || "";
if (shots) fs.mkdirSync(shots, { recursive: true });
const FAKE = path.join(__dirname, "fake_media_mcp.js");

let gwLog = "", failures = 0;
const fail = msg => { console.log("FAIL: " + msg); failures++; throw new Error(msg); };
const ok = msg => console.log("  ok: " + msg);
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(fn, what, ms = 15000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch {} await sleep(50); }
  fail("timed out waiting for " + what);
}
function freePort() {
  return new Promise(r => { const s = http.createServer().listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => r(p)); }); });
}

/* ---- the media: a gradient PNG, a WAV tone, an MP4's worth of bytes ---- */
const CRC = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc32 = b => { let c = 0xffffffff; for (const x of b) c = CRC[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
function png(w, h, hue) {
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const o = y * (w * 3 + 1) + 1 + x * 3;
    raw[o] = (x * 255 / w) ^ hue; raw[o + 1] = y * 255 / h; raw[o + 2] = 160 + (hue & 63);
  }
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr),
                        chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}
function wav(secs = 0.4, rate = 8000) {
  const n = Math.floor(secs * rate), b = Buffer.alloc(44 + n * 2);
  b.write("RIFF", 0); b.writeUInt32LE(36 + n * 2, 4); b.write("WAVEfmt ", 8); b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(rate, 24); b.writeUInt32LE(rate * 2, 28);
  b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34); b.write("data", 36); b.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) b.writeInt16LE(Math.round(8000 * Math.sin(2 * Math.PI * 440 * i / rate)), 44 + i * 2);
  return b;
}
const FILES = {
  "/img.png": ["image/png", png(192, 128, 0)],
  "/big.png": ["image/png", png(384, 256, 90)],
  "/clip.mp4": ["video/mp4", Buffer.from("\0\0\0\x18ftypmp42\0\0\0\0mp42isom")],
  "/tone.wav": ["audio/wav", wav()],
};
const mediaServer = http.createServer((req, res) => {
  const f = FILES[req.url.split("?")[0]];
  if (!f) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "content-type": f[0], "content-length": f[1].length, "access-control-allow-origin": "*" });
  res.end(req.method === "HEAD" ? undefined : f[1]);
});

const XSS = "javascript:window.__wfXss=1";
function spec(M) {
  return {
    id: "media", name: "media", description: "An image, upscaled, with a clip and a sound.",
    inputs: [{ name: "prompt", type: "string", required: true }, { name: "cfg", type: "string", required: true }],
    outputs: [{ name: "image", value: "{{nodes.up.output[0]}}", type: "string" },
              { name: "video", value: "{{nodes.up.output[1]}}", type: "string" },
              { name: "audio", value: "{{nodes.up.output[2]}}", type: "string" },
              { name: "first", value: "{{nodes.gen}}", type: "string" }],
    nodes: [
      { id: "gen", tool: "fakemedia__predict", x: 192, y: 48,
        args: { prompt: "{{inputs.prompt}}", steps: 20, output: [M + "/img.png", XSS] } },
      { id: "up", tool: "fakemedia__predict", x: 432, y: 48,
        args: { prompt: "upscale", image: "{{nodes.gen.output[0]}}",
                output: [M + "/big.png", M + "/clip.mp4", M + "/tone.wav"] } },
      { id: "note", tool: "fakemedia__say", x: 432, y: 264,
        args: { text: "**Done**: see [the image](" + M + "/big.png) and [this](" + XSS + ")." } }],
    edges: [{ from: "gen", to: "up" }],
  };
}

(async () => {
  const mport = await freePort();
  await new Promise(r => mediaServer.listen(mport, "127.0.0.1", r));
  const M = `http://127.0.0.1:${mport}`;
  const port = await freePort();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-wf-media-"));
  fs.mkdirSync(path.join(home, "workspace"), { recursive: true });
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify({
    gateway: { port, bind_addr: "127.0.0.1" },
    providers: [{ name: "fake", kind: "openai", api_base: "http://127.0.0.1:9/v1", api_key: "sk-test", model: "m" }],
    default_provider: "fake", default_model: "m", workflows_enabled: true,
    mcp_servers: [{ name: "fakemedia", cmd: process.execPath, args: `"${FAKE}"`, enabled: true, codemode: false }] }));
  const proc = spawn(binary, ["gateway", "--port", String(port), "--addr", "127.0.0.1"],
                     { cwd: home, env: Object.assign({}, process.env, { PASCLAW_HOME: home }), stdio: ["ignore", "pipe", "pipe"] });
  proc.stdout.on("data", d => gwLog += d); proc.stderr.on("data", d => gwLog += d);
  const base = `http://127.0.0.1:${port}`;
  const api = async (method, p, body) => {
    const r = await fetch(base + p, { method, headers: { "content-type": "application/json" },
                                      body: body === undefined ? undefined : JSON.stringify(body) });
    return [r.status, await r.json().catch(() => ({}))];
  };
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1360, height: 960 }, colorScheme: "dark" });
  const page = await ctx.newPage();
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  const shot = async (name, opts = {}) => { if (shots) await page.screenshot(Object.assign({ path: path.join(shots, name) }, opts)); };
  const argsJSON = async () => JSON.parse(await page.inputValue("#wfInspArgs"));
  const field = k => page.locator(`#wfInspBody [data-key="${k}"]`);

  try {
    await until(async () => (await fetch(base + "/v1/health")).ok, "the gateway");
    let tools = [];
    await until(async () => { tools = (await api("GET", "/v1/mcp/tools"))[1].tools || []; return tools.some(t => t.name === "fakemedia__predict"); },
                "the fake MCP server's tools", 20000);
    const [st, j] = await api("POST", "/v1/workflows", spec(M));
    if (st !== 200) fail("seed: " + st + " " + JSON.stringify(j));

    await page.goto(base + "/#workflow");
    await page.click('#wfList .wf-row[data-id="media"] .wf-rname');
    await until(async () => (await page.locator("#wfCanvas .wf-node").count()) === 3, "the media workflow's steps");

    /* ---- the form matches the schema ---- */
    await page.click('#wfCanvas .wf-node[data-node="gen"] .wf-ntool');
    await until(async () => (await page.locator("#wfInspBody .wf-sf").count()) > 0, "the argument form");
    const schema = tools.find(t => t.name === "fakemedia__predict").schema;
    const WANT = { prompt: "text", steps: "number", guidance: "number", enhance: "checkbox", style: "select",
                   tags: "list", size: "object", extra: "object", image: "text", output: "json",
                   "size.width": "number", "size.height": "number", "extra.lora": "json" };
    const got = await page.$$eval("#wfInspBody [data-key]", els => Object.fromEntries(els.map(e => [e.dataset.key, e.dataset.kind])));
    for (const k of Object.keys(schema.properties))
      if (got[k] !== WANT[k]) fail(`field ${k}: ${got[k]}, want ${WANT[k]} (all: ${JSON.stringify(got)})`);
    if (JSON.stringify(Object.keys(got).sort()) !== JSON.stringify(Object.keys(WANT).sort())) fail("the fields: " + JSON.stringify(got));
    const prompt = field("prompt");
    if ((await prompt.locator("textarea").count()) !== 1 || (await prompt.locator(".wf-req").count()) !== 1 ||
        !/What to make\./.test(await prompt.textContent())) fail("prompt: not a required textarea with its hint");
    if ((await field("steps").locator(".wf-req").count()) !== 0) fail("steps is marked required");
    if ((await field("steps").locator("input").inputValue()) !== "20" ||
        (await field("guidance").locator("input").getAttribute("placeholder")) !== "7.5") fail("steps' value / guidance's default placeholder");
    if (!(await field("enhance").locator("input[type=checkbox]").isChecked())) fail("enhance: the default (true) isn't shown");
    const opts = await field("style").locator("option").evaluateAll(os => os.map(o => o.value));
    if (JSON.stringify(opts) !== '["","photo","anime","sketch"]') fail("style's options: " + opts);
    if (JSON.parse(await field("output").locator("textarea").inputValue())[1] !== XSS) fail("output: the list isn't its JSON");
    ok("one field per schema property, of the kind its type asks for: required marked, description as hint, default as placeholder");

    /* ---- form -> JSON -> save; a template in a number field ---- */
    await field("steps").locator("input").fill("30");
    await field("style").locator("select").selectOption("anime");
    await field("tags").locator(".wf-sf-add").click();
    await field("tags").locator("input").last().fill("neon");
    await field("size.width").locator("input").fill("640");
    await field("guidance").locator("input").fill("{{inputs.cfg}}");
    await field("enhance").locator("input[type=checkbox]").uncheck();
    let a = await argsJSON();
    if (a.steps !== 30 || a.style !== "anime" || JSON.stringify(a.tags) !== '["neon"]' || JSON.stringify(a.size) !== '{"width":640}' ||
        a.guidance !== "{{inputs.cfg}}" || a.enhance !== false || a.prompt !== "{{inputs.prompt}}" || a.output[0] !== M + "/img.png")
      fail("a form edit didn't reach the JSON: " + JSON.stringify(a));
    if (!(await field("guidance").evaluate(e => e.classList.contains("wf-tplv")))) fail("the template isn't marked as one");
    await shot("workflow-args-form-desktop-dark.png");
    await page.click("#wfSave");
    await until(async () => (await page.textContent("#wf-state")) === "Saved", "the save");
    const saved = (await api("GET", "/v1/workflows/media"))[1].nodes.find(n => n.id === "gen").args;
    if (saved.steps !== 30 || saved.guidance !== "{{inputs.cfg}}" || saved.style !== "anime" || saved.enhance !== false ||
        JSON.stringify(saved.tags) !== '["neon"]' || saved.size.width !== 640 || saved.output.length !== 2)
      fail("the saved args: " + JSON.stringify(saved));
    ok("a form edit reaches the JSON and the save; a template in a number field is saved as the template");

    /* ---- JSON -> form; invalid JSON ---- */
    await page.click("#wfInspRawWrap > summary");
    const good = await page.inputValue("#wfInspArgs");
    await page.fill("#wfInspArgs", good.replace('"anime"', '"sketch"').replace('"steps": 30', '"steps": 12'));
    if ((await field("style").locator("select").inputValue()) !== "sketch" ||
        (await field("steps").locator("input").inputValue()) !== "12") fail("an edit of the JSON didn't reach the form");
    await page.fill("#wfInspArgs", '{"prompt": ');
    await until(async () => await page.isVisible("#wfInspArgsErr"), "the JSON error");
    if (!/Not valid JSON/.test(await page.textContent("#wfInspArgsErr"))) fail("the JSON error: " + await page.textContent("#wfInspArgsErr"));
    if ((await field("steps").locator("input").inputValue()) !== "12" || (await page.locator("#wfInspBody .wf-sf").count()) < 9)
      fail("invalid JSON wiped the form");
    await shot("workflow-args-invalid-json-desktop-dark.png");
    await page.fill("#wfInspArgs", good);
    if (await page.isVisible("#wfInspArgsErr")) fail("the JSON error stayed after valid JSON");
    ok("an edit of the JSON reaches the form; invalid JSON shows its error and leaves the form as it was");

    /* ---- a run ---- */
    await page.click("#wfRun");
    await until(async () => await page.isVisible("#wfRunInputs input[name=cfg]"), "the run's inputs");
    await page.fill("#wfRunInputs input[name=prompt]", "a red fox");
    await page.fill("#wfRunInputs input[name=cfg]", "8");
    await page.click("#wf-run-go");
    await until(async () => await page.isVisible("#wfResults .wf-sum.ok"), "the run to finish", 20000);
    const thumbs = await page.$$eval("#wfCanvas .wf-node", ns => ns.map(n => {
      const i = n.querySelector(".wf-nthumb img"); return [n.dataset.node, i ? i.src : "", i ? i.naturalWidth : 0,
        (n.querySelector(".wf-nthumb .n") || {}).textContent || ""]; }));
    await until(async () => (await page.$eval('#wfCanvas .wf-node[data-node="up"] .wf-nthumb img', i => i.complete && i.naturalWidth)) > 0, "the thumbnail to load");
    const tm = Object.fromEntries(thumbs.map(t => [t[0], t]));
    if (tm.gen[1] !== M + "/img.png" || tm.up[1] !== M + "/big.png" || tm.up[3] !== "+2" || tm.note[1] !== "")
      fail("the cards' thumbnails: " + JSON.stringify(thumbs));
    const outThumbs = await page.$$eval(".wf-io-output .wf-othumb", bs => bs.map(b => (b.querySelector("img,video") || {}).src || "audio"));
    if (JSON.stringify(outThumbs) !== JSON.stringify([M + "/big.png", M + "/clip.mp4", "audio", M + "/img.png"]))
      fail("the Outputs box's thumbnails: " + JSON.stringify(outThumbs));
    ok("after a run, a thumbnail on each step's card and on the Outputs box");

    const res = await page.evaluate(() => {
      const q = s => [...document.querySelectorAll("#wfResults " + s)];
      return { vids: q("video").map(v => [v.src, v.controls]), auds: q("audio").map(v => [v.src, v.controls]),
               imgs: q(".wf-media img").map(i => i.src), pred: q(".wf-pred").map(p => p.textContent),
               md: (document.querySelector('#wfResults .wf-step[data-node="note"] .wf-md') || {}).innerHTML || "" };
    });
    if (!res.vids.some(v => v[0] === M + "/clip.mp4" && v[1]) || !res.auds.some(v => v[0] === M + "/tone.wav" && v[1]) ||
        !res.imgs.includes(M + "/img.png") || !res.imgs.includes(M + "/big.png"))
      fail("the run's media: " + JSON.stringify(res));
    if (!res.pred.some(p => /succeeded/.test(p) && /fake\/image/.test(p) && /predict 1\.25 s/.test(p))) fail("the prediction's summary: " + res.pred);
    if (!/<strong>Done<\/strong>/.test(res.md) || !/href="http:\/\/127\.0\.0\.1/.test(res.md)) fail("the markdown result: " + res.md);
    ok("the results show <img>, <video controls> and <audio controls>, the prediction's status, model and time, and markdown");

    /* ---- javascript: is never media or a link; no referrer ---- */
    const sec = await page.evaluate(() => ({
      js: [...document.querySelectorAll("[src],[href]")].filter(e => /^\s*javascript:/i.test(e.getAttribute("src") || e.getAttribute("href") || "")).length,
      xss: window.__wfXss, shown: document.querySelector("#wfResults").textContent.includes("javascript:window.__wfXss"),
      noRef: [...document.querySelectorAll("#tab-workflow img, #tab-workflow video, #tab-workflow audio")]
        .filter(e => /^http/.test(e.getAttribute("src") || "")).every(e => e.getAttribute("referrerpolicy") === "no-referrer"),
    }));
    if (sec.js || sec.xss !== undefined || !sec.shown || !sec.noRef) fail("javascript: or referrer: " + JSON.stringify(sec));
    ok("a javascript: URL stays text (never media or a link); every media element has referrerpolicy=no-referrer");

    await page.evaluate(() => { document.querySelector("#wf-editor").scrollTop = 0; });
    await shot("workflow-canvas-thumbnails-desktop-dark.png");

    /* ---- the lightbox ---- */
    await page.click('#wfCanvas .wf-node[data-node="up"] .wf-nthumb');
    await until(async () => await page.isVisible("#wf-lb"), "the lightbox");
    const lb = await page.evaluate(() => { const a = document.querySelector("#wf-lb-open"), i = document.querySelector("#wf-lb img");
      return [i && i.src, a && a.href, a && a.target, a && a.rel]; });
    if (lb[0] !== M + "/big.png" || lb[1] !== M + "/big.png" || lb[2] !== "_blank" || !/noreferrer/.test(lb[3])) fail("the lightbox: " + lb);
    await until(async () => (await page.$eval("#wf-lb img", i => i.naturalWidth)) > 0, "the large image");
    await shot("workflow-lightbox-desktop-dark.png", { fullPage: false });
    await page.keyboard.press("Escape");
    await until(async () => await page.isHidden("#wf-lb"), "Esc to close the lightbox");
    if (await page.isHidden("#wf-editor")) fail("Esc left the editor");
    await page.click('.wf-io-output .wf-othumb:has(video)');
    await until(async () => await page.isVisible("#wf-lb video[controls]"), "the video, large");
    await page.click("#wf-lb-close");
    await until(async () => await page.isHidden("#wf-lb"), "the close button to close the lightbox");
    ok("a thumbnail opens the lightbox with a link to the original; Esc and the close button close it");

    /* ---- the Outputs box and a step's card open their values ---- */
    await page.click(".wf-io-output .wf-io-head");
    await until(async () => await page.isVisible("#wfOutPanel"), "the outputs panel");
    const outs = await page.$$eval("#wfOutPanel .wf-out1", rs => rs.map(r => [r.dataset.out,
      r.querySelector("img") ? "img" : r.querySelector("video[controls]") ? "video" : r.querySelector("audio[controls]") ? "audio" : "",
      !!r.querySelector(".wf-pred")]));
    if (JSON.stringify(outs) !== '[["image","img",false],["video","video",false],["audio","audio",false],["first","img",true]]')
      fail("the outputs panel: " + JSON.stringify(outs));
    await shot("workflow-outputs-panel-desktop-dark.png");
    await page.click('#wfCanvas .wf-node[data-node="gen"] .wf-ntool');
    await until(async () => await page.isVisible("#wfInspRun .wf-pred"), "the step's last result");
    if (await page.isVisible("#wfOutPanel")) fail("the outputs panel stayed open beside the step's settings");
    ok("the Outputs box opens each output's name and value; a step's card opens its last result");
  } catch (e) {
    if (!failures) { console.log("FAIL: " + (e && e.stack || e)); failures++; }
  } finally {
    await browser.close();
    proc.kill(); mediaServer.close();
    try { fs.rmSync(home, { recursive: true, force: true }); } catch {}
  }
  if (failures) {
    console.log("--- gateway log (tail) ---\n" + gwLog.split("\n").slice(-30).join("\n"));
    process.exit(1);
  }
  console.log("webui_workflow_media_e2e: all checks passed");
})();
