#!/usr/bin/env node
/* The web UI's Relay tab, against the real gateway.

   One gateway has a provider of kind relay as its default; fake workers in
   this script connect to it the way real ones do, by holding a GET of
   /v1/relay/poll open with the relay token and X-Relay-Capabilities, and
   answer the jobs it streams (one is held, one fails). A second gateway has
   no relay provider. Through headless Chromium:

     - the provider line says relay is configured and is the default; on the
       second gateway it says none is, and its link opens Settings on the
       providers section even when Settings last showed another;
     - with no worker, an empty state that leads to Add a worker; a chat
       sent then shows as queued;
     - a worker that connects is a row with its id, its models as chips,
       Online, its request count and "seen just now" with the exact time on
       hover; the strip shows it online, the held job in flight, then the
       completed and failed counts as the gateway reports them, failed in
       the danger colour only once it is above zero;
     - a worker id and models holding HTML, and an Activity line holding
       HTML, are drawn as text;
     - the gateway runs on UTC and the browser 14 hours ahead, and a live
       worker still reads "seen just now"; a worker the gateway has not
       heard from for a while reads Stale and "1 min ago"; an older
       gateway's zone-less last_seen still reads as a relative time; a
       gateway with the relay off says so;
     - the status refresh stops while another tab is open;
     - snippets: the URL override reaches every one; while the token is
       hidden they carry <PASCLAW_RELAY_TOKEN> and the real token is nowhere
       on the page, Reveal puts it in, Copy puts a snippet (and the token)
       on the clipboard; the options switch with the mouse and arrow keys;
     - opening the tab fetches nothing from esm.run; with no WebGPU (as in
       headless Chromium) the in-browser worker says so and Connect is off,
       and with a GPU stubbed in, Connect is on;
     - when the workers disconnect, the empty state comes back;
     - light theme: the tokens follow; phone width: no sideways scroll with
       any option open.

   Needs node with Playwright and a Chromium; skips without them.
   RELAY_SHOTS=<dir> also writes dark, light, phone and in-browser-worker
   screenshots there.
   usage: node webui_relay_e2e.js <pasclaw-binary> */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

let chromium;
try { ({ chromium } = require("playwright")); }
catch { console.log("  skip: webui_relay_e2e needs Playwright (require('playwright') failed)"); process.exit(0); }

const binary = process.argv[2] && path.resolve(process.argv[2]);
if (!binary || !fs.existsSync(binary)) { console.log("  skip: needs the pasclaw binary"); process.exit(0); }
const shots = process.env.RELAY_SHOTS || "";
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

/* A gateway of its own, in a home of its own. */
async function startGateway(config, tag) {
  const port = await freePort();
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pasclaw-webui-relay-" + tag + "-"));
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify(Object.assign({
    gateway: { port, bind_addr: "127.0.0.1" } }, config)));
  const proc = spawn(binary, ["gateway", "--port", String(port), "--addr", "127.0.0.1", "--no-mcp"],
                     { cwd: home, env: Object.assign({}, process.env, { PASCLAW_HOME: home, TZ: "UTC" }), stdio: ["ignore", "pipe", "pipe"] });
  proc.stdout.on("data", d => gwLog += d); proc.stderr.on("data", d => gwLog += d);
  const base = `http://127.0.0.1:${port}`;
  await until(async () => (await fetch(base + "/v1/health")).ok, "the " + tag + " gateway");
  return { base, port, home, proc };
}

/* A worker as the relay sees one: a held-open GET of /v1/relay/poll that
   names itself and its models, and a POST per answer. onJob decides. */
function fakeWorker(base, token, id, caps, onJob) {
  const headers = { Authorization: "Bearer " + token, "X-Relay-Worker-Id": id, Accept: "text/event-stream" };
  if (caps) headers["X-Relay-Capabilities"] = caps;
  const req = http.request(base + "/v1/relay/poll", { headers });
  let buf = "";
  req.on("response", res => {
    res.setEncoding("utf8");
    res.on("data", d => {
      buf += d;
      let i;
      while ((i = buf.indexOf("\n\n")) >= 0) {
        const frame = buf.slice(0, i); buf = buf.slice(i + 2);
        for (const line of frame.split("\n"))
          if (line.startsWith("data: ")) { let job; try { job = JSON.parse(line.slice(6)); } catch { continue; } onJob(job); }
      }
    });
    res.on("error", () => {});
  });
  req.on("error", () => {});
  req.end();
  return req;
}
async function respond(base, token, id, body) {
  await fetch(base + "/v1/relay/respond/" + id, { method: "POST",
    headers: { Authorization: "Bearer " + token, "content-type": "application/json" }, body: JSON.stringify(body) });
}

(async () => {
  const A = await startGateway({ providers: [{ name: "relay", kind: "relay" }], default_provider: "relay", default_model: "" }, "relay");
  const B = await startGateway({ providers: [{ name: "fake", kind: "openai", api_base: "http://127.0.0.1:9/v1", api_key: "sk-test", model: "m" }],
                                 default_provider: "fake", default_model: "m" }, "norelay");
  const token = (await (await fetch(A.base + "/v1/relay/worker-token")).json()).token;
  if (!token) fail("no relay worker token from the gateway");
  const status = async () => (await fetch(A.base + "/v1/relay/status")).json();
  const chat = message => fetch(A.base + "/v1/chat", { method: "POST", headers: { "content-type": "application/json" },
                                                         body: JSON.stringify({ message }) }).then(r => r.text()).catch(() => "");
  const workers = [];

  const browser = await chromium.launch();
  /* The gateway runs on UTC and the browser 14 hours ahead, as a gateway in
     a container and a browser elsewhere can be: "seen just now" must still
     read "just now". */
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, colorScheme: "dark",
                                         timezoneId: "Pacific/Kiritimati",
                                         permissions: ["clipboard-read", "clipboard-write"] });
  const page = await ctx.newPage();
  page.on("pageerror", e => { console.log("FAIL: page error: " + e.message); failures++; });
  page.on("dialog", d => d.dismiss());
  let statusRequests = 0, thirdParty = [];
  page.on("request", r => {
    const u = r.url();
    if (/\/v1\/relay\/status$/.test(u)) statusRequests++;
    if (!u.startsWith(A.base) && !u.startsWith(B.base) && !u.startsWith("data:") && !u.startsWith("blob:")) thirdParty.push(u);
  });
  const shot = async (name, loc) => { if (shots) await (loc || page).screenshot({ path: path.join(shots, name) }); };
  const text = sel => page.textContent(sel);
  const num = async id => (await text("#relay-stat-" + id)).trim();
  const color = sel => page.evaluate(s => getComputedStyle(document.querySelector(s)).color, sel);
  const row = id => page.locator("#relay-workers .rl-w").filter({ has: page.locator(".rl-w-id", { hasText: id }) });
  const codes = () => page.$$eval("#relay-add pre code", cs => cs.map(c => c.textContent));
  const pressedOpt = () => page.$eval("#relay-seg [aria-selected=true]", b => b.dataset.opt);

  try {
    await page.goto(A.base + "/#relay");
    await page.waitForSelector("#relay-pane");

    /* ---- the provider line ---- */
    await until(async () => (await page.getAttribute("#relay-provider", "data-state")) === "ok", "the provider line");
    const pl = (await text("#relay-provider")).replace(/\s+/g, " ").trim();
    if (!/Relay provider relay is configured and is the default/.test(pl)) fail("the provider line says: " + pl);
    ok("the provider line: relay is configured and is the default");

    /* ---- no worker yet: the empty state, then a queued request ---- */
    await until(async () => /No workers connected/.test(await text("#relay-workers")), "the empty state");
    if (!/Add a worker/.test(await text("#relay-workers .rl-empty"))) fail("the empty state does not point to Add a worker");
    if ((await num("workers")) !== "0") fail("workers online is " + (await num("workers")) + " with none connected");
    await page.click("#relay-workers [data-goto-add]");
    await until(async () => (await page.evaluate(() => document.activeElement && document.activeElement.id)) === "relay-add-h", "focus on Add a worker");
    ok("no worker: the empty state, and its link takes focus to Add a worker");

    let held = null;
    const chat1 = chat("first question");
    await until(async () => (await status()).pending_requests === 1, "the chat's request in the queue");
    await until(async () => (await num("pending")) === "1", "queued 1 in the strip");
    ok("a request waiting for a worker shows as queued");

    /* ---- a worker connects ---- */
    const onJob = job => {
      const all = JSON.stringify(job.messages || []);
      if (all.includes("FAIL")) return respond(A.base, token, job.id, { error: "the fake worker failed on purpose" });
      if (all.includes("first question") && !held) { held = job; return; }        // held until released below
      respond(A.base, token, job.id, { content: "hello from the fake worker", finish_reason: "stop",
                                       usage: { prompt_tokens: 3, completion_tokens: 3 } });
    };
    workers.push(fakeWorker(A.base, token, "gpu-box-1", "Qwen2.5-Coder-7B-Instruct,llama-3.1-8b", onJob));
    await until(() => !!held, "the worker to receive the queued job");
    await until(async () => (await num("inflight")) === "1" && (await num("pending")) === "0", "in flight 1, queued 0");
    await until(async () => (await row("gpu-box-1").count()) === 1, "the worker's row");
    const r1 = row("gpu-box-1");
    const chips = await r1.locator(".rl-model").allTextContents();
    if (JSON.stringify(chips) !== JSON.stringify(["Qwen2.5-Coder-7B-Instruct", "llama-3.1-8b"])) fail("model chips: " + JSON.stringify(chips));
    if ((await r1.locator(".rl-w-state").textContent()) !== "Online") fail("the worker is not Online");
    if ((await r1.getAttribute("data-state")) !== "online") fail("the row is not in the online state");
    await until(async () => /^1 request$/.test((await r1.locator(".rl-w-served").textContent()).trim()), "1 request on the row");
    const seen = await r1.locator(".rl-w-seen");
    const seenText = (await seen.textContent()).trim();
    if (!/^seen (just now|\d+ s ago)$/.test(seenText)) fail("last seen reads " + JSON.stringify(seenText));
    const hover = await seen.getAttribute("title"), dt = await seen.getAttribute("datetime");
    if (!/^Last seen .*\d{1,2}:\d{2}/.test(hover || "")) fail("no exact time on hover: " + hover);
    if (!dt || Math.abs(Date.parse(dt) - Date.now()) > 15000) fail("the datetime is not about now: " + dt);
    if ((await num("workers")) !== "1" || !/^worker online$/.test((await text("#relay-stat-workers-lbl")).trim())) fail("the strip does not say 1 worker online");
    ok("a worker: a row with its id, model chips, Online, 1 request, " + JSON.stringify(seenText) + " (" + hover + " on hover); strip 1 online, 1 in flight");

    /* ---- completed, failed ---- */
    if (await page.$eval("#relay-stat-failed-cell", e => e.classList.contains("bad"))) fail("failed is marked with nothing failed");
    const textColor = await color("#relay-stat-completed");
    if ((await color("#relay-stat-failed")) !== textColor) fail("failed at 0 is not drawn like the other numbers");
    await respond(A.base, token, held.id, { content: "hello from gpu-box-1", finish_reason: "stop", usage: { prompt_tokens: 3, completion_tokens: 3 } });
    await chat1;
    chat("FAIL this one on purpose");
    await until(async () => (await status()).total_failed > 0, "a failed relay request", 20000);
    await sleep(1500);
    const st = await status();
    await until(async () => (await num("completed")) === String(st.total_completed) && (await num("failed")) === String(st.total_failed),
                "the strip to match the gateway's counts (" + st.total_completed + " completed, " + st.total_failed + " failed)");
    if (!(await page.$eval("#relay-stat-failed-cell", e => e.classList.contains("bad")))) fail("failed above zero is not marked");
    const danger = await color("#relay-stat-failed");
    if (danger !== "rgb(255, 123, 114)") fail("failed above zero is not the danger colour: " + danger);
    if ((await color("#relay-stat-completed")) === danger) fail("completed took the danger colour too");
    ok("completed " + st.total_completed + " and failed " + st.total_failed + " as the gateway counts them; failed turns the danger colour only above zero");

    /* ---- HTML from workers is text ---- */
    const evilId = "<img src=x onerror=window.__pwned=1>";
    workers.push(fakeWorker(A.base, token, evilId, "<b>bold</b>,<img src=x onerror=window.__pwned=2>", onJob));
    await until(async () => (await page.locator("#relay-workers .rl-w").count()) === 2, "the second worker's row");
    const evil = await page.evaluate(() => {
      const rows = [...document.querySelectorAll("#relay-workers .rl-w")];
      const r = rows.find(x => x.querySelector(".rl-w-id").textContent.startsWith("<img"));
      return r && { id: r.querySelector(".rl-w-id").textContent, chips: [...r.querySelectorAll(".rl-model")].map(c => c.textContent),
                    imgs: document.querySelectorAll("#relay-workers img, #relay-workers b:not(.rl-w-served b)").length, pwned: window.__pwned };
    });
    if (!evil) fail("the worker with an HTML id has no row");
    if (evil.id !== evilId) fail("the HTML worker id is drawn as " + JSON.stringify(evil.id));
    if (JSON.stringify(evil.chips) !== JSON.stringify(["<b>bold</b>", "<img src=x onerror=window.__pwned=2>"])) fail("the HTML models are drawn as " + JSON.stringify(evil.chips));
    if (evil.imgs || evil.pwned) fail("HTML from a worker became elements: " + JSON.stringify(evil));
    await page.evaluate(() => _inbLog("<img src=x onerror=window.__pwned=3> went wrong", "err"));
    const logged = await page.evaluate(() => {
      const li = document.querySelector("#relay-inb-log li.err");
      return li && { msg: li.querySelector(".msg").textContent, lv: li.querySelector(".lv").textContent,
                     t: li.querySelector("time").textContent, img: !!li.querySelector("img"),
                     open: document.querySelector("#relay-inb-activity").open, pwned: window.__pwned };
    });
    if (!logged || logged.img || logged.pwned || !/^<img src=x/.test(logged.msg)) fail("an Activity line with HTML: " + JSON.stringify(logged));
    if (logged.lv !== "error" || !/\d{1,2}:\d{2}:\d{2}/.test(logged.t) || !logged.open) fail("an error line has no level, time or did not open Activity: " + JSON.stringify(logged));
    if ((await color("#relay-inb-log li.err .lv")) !== danger) fail("the error level is not in the danger colour");
    ok("a worker id, its models and an Activity line holding HTML are drawn as text; the error line has a time, a level and opened Activity");

    /* ---- stale, an older gateway's last_seen, the relay off (the status is stood in for) ---- */
    /* An older gateway's last_seen: local time with no zone, here 20 s ago
       on the browser's clock and in its zone. */
    const zoneLess = await page.evaluate(() => { const d = new Date(Date.now() - 20000), pad = n => String(n).padStart(2, "0");
      return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`; });
    let fake = null;
    await page.route("**/v1/relay/status", r => fake ? r.fulfill(fake) : r.continue());
    fake = { status: 200, contentType: "application/json", body: JSON.stringify({ pending_requests: 0, inflight_requests: 0,
      connected_workers: 2, total_enqueued: 9, total_completed: 7, total_failed: 0, workers: [
        { id: "old-box", caps: ["m1"], requests_seen: 3, last_seen: "x", last_seen_age_ms: 95000 },
        { id: "zone-less", caps: [], requests_seen: 0, last_seen: zoneLess } ] }) };
    await until(async () => (await row("old-box").count()) === 1, "the stood-in status", 8000);
    const old = row("old-box");
    if ((await old.locator(".rl-w-state").textContent()) !== "Stale" || (await old.getAttribute("data-state")) !== "stale") fail("a worker unheard of for 95 s is not Stale");
    if ((await old.locator(".rl-w-seen").textContent()).trim() !== "seen 1 min ago") fail("95 s ago reads " + (await old.locator(".rl-w-seen").textContent()));
    if ((await color("#relay-workers .rl-w[data-state=stale] .rl-w-state")) !== "rgb(224, 172, 74)") fail("Stale is not in the warn colour");
    const zl = (await row("zone-less").locator(".rl-w-seen").textContent()).trim();
    if (!/^seen ([12]\d|3\d|4\d) s ago$/.test(zl)) fail("a zone-less last_seen 20 s ago reads " + zl);
    if ((await row("zone-less").locator(".rl-model").textContent()) !== "Any model") fail("a worker with no models does not say Any model");
    const lbl = (await text("#relay-stat-workers-lbl")).trim();
    if ((await num("workers")) !== "1" || lbl !== "worker online · 1 stale") fail("the strip with a stale worker: " + (await num("workers")) + " " + lbl);
    if (await page.$eval("#relay-stat-failed-cell", e => e.classList.contains("bad"))) fail("failed back at 0 still marked");
    ok("a worker unheard of for 95 s reads Stale and \"seen 1 min ago\"; a zone-less last_seen reads \"" + zl + "\"; no models reads Any model");
    fake = { status: 503, contentType: "application/json", body: '{"error":"relay disabled"}' };
    await until(async () => /turned off on this gateway/.test(await text("#relay-workers")), "the relay-off message", 8000);
    if ((await num("workers")) !== "—") fail("numbers kept with the relay off");
    fake = null;
    await page.unroute("**/v1/relay/status");
    await until(async () => (await page.locator("#relay-workers .rl-w").count()) === 2, "the real workers back", 8000);
    ok("the relay off on the gateway is said in words");

    /* ---- the refresh pauses while another tab is open ---- */
    let n0 = statusRequests;
    await sleep(3500);
    if (statusRequests - n0 < 1) fail("the open tab did not refresh in 3.5 s");
    await page.click('nav button[data-tab="chat"]');
    await sleep(300);
    n0 = statusRequests;
    await sleep(4000);
    if (statusRequests !== n0) fail("the status kept refreshing on another tab: " + (statusRequests - n0));
    await page.click('nav button[data-tab="relay"]');
    await until(async () => statusRequests > n0, "a refresh on coming back", 3000);
    ok("refreshes while the tab is open, not while another tab is");

    /* ---- snippets and the token ---- */
    await page.click("#relay-tab-cli");
    if (!(await page.isVisible("#relay-opt-cli")) || (await page.isVisible("#relay-opt-browser"))) fail("pasclaw relay did not show its panel alone");
    let cs = await codes();
    const flags = await page.textContent("#relay-snip-cli pre code");
    if (!flags.includes("--gateway-url " + A.base) || !flags.includes("--gateway-token <PASCLAW_RELAY_TOKEN>")) fail("the flags snippet: " + flags);
    if (cs.some(c => c.includes(token))) fail("a snippet holds the real token while it is hidden");
    if (cs.filter(c => c.includes("<PASCLAW_RELAY_TOKEN>")).length !== 4) fail("not every snippet carries the placeholder");
    const tokVal = await page.inputValue("#relay-token");
    if (tokVal.includes(token) || !/^•+$/.test(tokVal)) fail("the token field shows " + tokVal);
    if ((await page.evaluate(() => document.body.innerText)).includes(token)) fail("the real token is on the page while hidden");
    await page.fill("#relay-url", "https://relay.example.test/");
    cs = await codes();
    if (cs.some(c => c.includes(A.base)) || cs.filter(c => c.includes("https://relay.example.test")).length !== 4 || cs.some(c => c.includes("example.test/\""))) fail("the URL override did not reach every snippet: " + cs.join("\n---\n"));
    ok("snippets: the placeholder while hidden, the URL override in all four");
    await shot("relay-snippets-hidden.png", page.locator("#relay-add"));

    await page.click("#relay-token-toggle");
    if ((await page.inputValue("#relay-token")) !== token) fail("Reveal did not show the token");
    if ((await page.textContent("#relay-token-toggle")).trim() !== "Hide") fail("the button does not say Hide once revealed");
    cs = await codes();
    if (cs.filter(c => c.includes(token)).length !== 4 || cs.some(c => c.includes("<PASCLAW_RELAY_TOKEN>"))) fail("Reveal did not put the token in every snippet");
    await page.click("#relay-snip-cli .code-wrap:nth-child(1) .rl-copy");
    const clip1 = await page.evaluate(() => navigator.clipboard.readText());
    if (clip1 !== (await page.textContent("#relay-snip-cli .code-wrap:nth-child(1) pre code")) || !clip1.includes(token) || !clip1.includes("https://relay.example.test"))
      fail("Copy put on the clipboard: " + clip1);
    if (!/Copied/.test(await page.textContent("#relay-snip-cli .code-wrap:nth-child(1) .rl-copy"))) fail("the Copy button does not say Copied");
    await page.click("#relay-token-toggle");
    if ((await page.inputValue("#relay-token")).includes(token) || (await codes()).some(c => c.includes(token))) fail("Hide left the token showing");
    await page.click("#relay-token-copy");
    if ((await page.evaluate(() => navigator.clipboard.readText())) !== token) fail("the token's Copy did not copy the token");
    ok("Reveal puts the real token in, Hide takes it out; Copy copies the snippet, and the token's Copy the token while hidden");

    await page.focus("#relay-tab-cli");
    await page.keyboard.press("ArrowRight");
    if ((await pressedOpt()) !== "python" || (await page.evaluate(() => document.activeElement.id)) !== "relay-tab-python") fail("ArrowRight did not move to Python");
    if (!/llama_cpp/.test(await page.textContent("#relay-opt-python")) || !(await page.isVisible("#relay-opt-python"))) fail("the Python panel did not open");
    await page.keyboard.press("End");
    if ((await pressedOpt()) !== "cog" || !(await page.isVisible("#relay-opt-cog"))) fail("End did not move to Replicate");
    await page.keyboard.press("ArrowRight");
    if ((await pressedOpt()) !== "browser") fail("ArrowRight from the last did not wrap");
    await page.keyboard.press("Home");
    if ((await pressedOpt()) !== "browser" || (await page.getAttribute("#relay-tab-cli", "tabindex")) !== "-1") fail("Home, or the roving tabindex");
    await page.fill("#relay-url", "");
    if (!(await page.textContent("#relay-snip-cli pre code")).includes(A.base)) fail("an empty URL does not fall back to the page's address");
    ok("the options switch by click and by arrow keys, Home and End, with one tab stop");

    /* ---- the in-browser worker ---- */
    if (thirdParty.length) fail("the tab fetched from elsewhere before Connect: " + thirdParty.join(", "));
    await until(async () => await page.isVisible("#relay-gpu-off"), "the WebGPU notice");
    if (!(await page.isDisabled("#relay-inb-connect"))) fail("Connect is on with no WebGPU");
    if (!(await text("#relay-gpu-why")).trim()) fail("the WebGPU notice gives no reason");
    if (!/WebGPU isn't available in this browser/.test(await text("#relay-gpu-off"))) fail("the notice: " + (await text("#relay-gpu-off")));
    const opts = await page.$$eval("#relay-inb-model option", os => os.map(o => o.textContent));
    if (!opts.some(o => /tool-calls supported/.test(o))) fail("the model list lost its tool-call notes");
    if (!/Text only/.test(await text("#relay-inb-model-note"))) fail("the default model's note: " + (await text("#relay-inb-model-note")));
    await page.selectOption("#relay-inb-model", "Hermes-3-Llama-3.1-8B-q4f16_1-MLC");
    if (!/Takes tool calls/.test(await text("#relay-inb-model-note"))) fail("a Hermes model's note: " + (await text("#relay-inb-model-note")));
    await page.click("#relay-gpu-off [data-opt-go=cli]");
    if ((await pressedOpt()) !== "cli") fail("the notice's pasclaw relay link did not switch option");
    await page.click("#relay-tab-browser");
    await shot("relay-browser-worker.png", page.locator("#relay-add"));
    if (thirdParty.length) fail("fetched from elsewhere: " + thirdParty.join(", "));
    ok("no WebGPU: the notice with its reason, Connect off, tool-call notes kept; nothing fetched from esm.run");

    const gpuPage = await ctx.newPage();
    await gpuPage.addInitScript(() => {
      Object.defineProperty(Navigator.prototype, "gpu", { configurable: true, get: () => ({ requestAdapter: async () => ({}) }) });
    });
    await gpuPage.goto(A.base + "/#relay");
    await gpuPage.waitForSelector("#relay-inb-connect");
    await sleep(800);
    if (await gpuPage.isDisabled("#relay-inb-connect")) fail("Connect is off with a GPU");
    if (await gpuPage.isVisible("#relay-gpu-off")) fail("the WebGPU notice shows with a GPU");
    await gpuPage.close();
    ok("with a GPU stubbed in, Connect is on and there is no notice");

    /* ---- light theme ---- */
    await page.click("#theme-btn");
    const lite = await page.evaluate(() => [document.documentElement.classList.contains("lite"),
      getComputedStyle(document.body).backgroundColor,
      getComputedStyle(document.querySelector("#relay-stat-failed")).color,
      getComputedStyle(document.querySelector("#relay-workers .rl-w[data-state=online] .rl-w-state")).color,
      getComputedStyle(document.querySelector(".rl-strip")).backgroundColor]);
    if (!lite[0]) fail("the theme button did not switch to light");
    if (lite[1] !== "rgb(245, 246, 248)" || lite[4] !== "rgb(255, 255, 255)") fail("the light surfaces: " + lite);
    if (lite[2] !== "rgb(184, 43, 38)") fail("failed does not take the light danger token: " + lite[2]);
    if (lite[3] !== "rgb(19, 108, 55)") fail("Online does not take the light ok token: " + lite[3]);
    await page.evaluate(() => document.querySelector("#relay-pane").scrollTo(0, 0));
    if (shots) { await page.mouse.move(640, 600); await sleep(400); }     // past the colour transitions
    await shot("relay-light.png");
    await page.click("#theme-btn");
    await page.evaluate(() => document.querySelector("#relay-pane").scrollTo(0, 0));
    if (shots) { await page.mouse.move(640, 600); await sleep(400); }
    await shot("relay-dark.png");
    ok("light theme: surfaces, danger and ok follow the tokens");

    /* ---- phone width ---- */
    await page.setViewportSize({ width: 390, height: 844 });
    for (const opt of ["browser", "cli", "python", "cog"]) {
      await page.click("#relay-tab-" + opt);
      const w = await page.evaluate(() => { const p = document.querySelector("#relay-pane");
        return [document.documentElement.scrollWidth, document.body.scrollWidth, p.scrollWidth, p.clientWidth]; });
      if (w[0] > 390 || w[1] > 390 || w[2] > w[3]) fail("sideways scroll at phone width with " + opt + " open: " + w);
    }
    await page.click("#relay-tab-browser");
    await page.evaluate(() => document.querySelector("#relay-pane").scrollTo(0, 0));
    await shot("relay-phone.png");
    await page.setViewportSize({ width: 1280, height: 900 });
    ok("phone width: no sideways scroll with any option open");

    /* ---- the workers leave ---- */
    workers.forEach(w => w.destroy());
    await until(async () => (await status()).connected_workers === 0, "the gateway to drop the workers", 15000);
    await until(async () => /No workers connected/.test(await text("#relay-workers")) && (await num("workers")) === "0",
                "the empty state after they disconnect", 8000);
    ok("when the workers disconnect the empty state comes back");

    /* ---- a gateway with no relay provider ---- */
    const p2 = await ctx.newPage();
    p2.on("pageerror", e => { console.log("FAIL: page error (second gateway): " + e.message); failures++; });
    /* Settings opens on the section it showed last: Agent, here. */
    await p2.goto(B.base + "/#chat");
    await p2.evaluate(() => localStorage.setItem("pasclaw.settings.section", "agent"));
    await p2.goto(B.base + "/#relay");
    await until(async () => (await p2.getAttribute("#relay-provider", "data-state")) === "warn", "the not-configured line");
    const pl2 = (await p2.textContent("#relay-provider")).replace(/\s+/g, " ");
    if (!/No relay provider is configured/.test(pl2)) fail("the not-configured line: " + pl2);
    await p2.click("#relay-provider a[data-settings]");
    await until(async () => await p2.evaluate(() => document.querySelector("#tab-settings").classList.contains("active")), "the Settings tab");
    await until(async () => (await p2.getAttribute('#set-nav button[data-sec="models"]', "aria-current")) === "true", "Settings on Models & providers");
    await p2.close();
    ok("no relay provider: the line says so, and its link opens Settings on Models & providers");

    if (failures) throw new Error(failures + " failure(s)");
    console.log("webui_relay_e2e: OK");
  } catch (e) {
    if (!failures) console.log("FAIL: " + e.message);
    console.log("---- gateway log (tail) ----\n" + gwLog.split("\n").slice(-25).join("\n"));
    process.exitCode = 1;
  } finally {
    workers.forEach(w => w.destroy());
    await browser.close();
    for (const g of [A, B]) { g.proc.kill(); fs.rmSync(g.home, { recursive: true, force: true }); }
  }
})();
