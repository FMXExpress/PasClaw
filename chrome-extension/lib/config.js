/* PasClaw for Chrome -- settings, gateway access and helpers shared by the
   service worker, the side panel and the options page. */

export const DEFAULTS = Object.freeze({
  gatewayUrl: "http://127.0.0.1:8088",
  token: "",
  model: "",
  mode: "build",
  serverHistory: true,
  pageCharLimit: 20000,
});

const SETTINGS_KEY = "settings";
const ORIGIN_RULE_ID = 1;

export async function getSettings() {
  const got = await chrome.storage.local.get(SETTINGS_KEY);
  return Object.assign({}, DEFAULTS, got[SETTINGS_KEY] || {});
}

export async function saveSettings(patch) {
  const next = Object.assign(await getSettings(), patch);
  next.gatewayUrl = normalizeGatewayUrl(next.gatewayUrl);
  await chrome.storage.local.set({ [SETTINGS_KEY]: next });
  return next;
}

export function onSettingsChanged(cb) {
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes[SETTINGS_KEY]) {
      cb(Object.assign({}, DEFAULTS, changes[SETTINGS_KEY].newValue || {}));
    }
  });
}

/* "localhost:8088" -> "http://localhost:8088"; strips a trailing slash and
   any path, since every route the extension uses is absolute. */
export function normalizeGatewayUrl(raw) {
  let s = String(raw || "").trim();
  if (!s) return DEFAULTS.gatewayUrl;
  if (!/^https?:\/\//i.test(s)) s = "http://" + s;
  try {
    return new URL(s).origin;
  } catch {
    return DEFAULTS.gatewayUrl;
  }
}

export function isLoopback(url) {
  try {
    const h = new URL(url).hostname;
    return h === "localhost" || h.endsWith(".localhost") || h === "127.0.0.1" || h === "[::1]";
  } catch {
    return false;
  }
}

export function originPattern(url) {
  return new URL(url).origin + "/*";
}

/* Loopback gateways are covered by the manifest's host_permissions; any other
   host must be granted at runtime. permissions.request needs a user gesture,
   so only call this from a click handler. */
export async function ensureHostPermission(url, { request = false } = {}) {
  const origins = [originPattern(url)];
  if (await chrome.permissions.contains({ origins })) return true;
  return request ? chrome.permissions.request({ origins }) : false;
}

/* A gateway with no token refuses any request whose Origin is not its own
   (PasClaw.Gateway.Auth.LocalRequestRefusal) -- the guard that keeps web pages
   from driving the agent. This extension is a client of the operator's own,
   like the CLI, so for requests that THIS extension sends to the configured
   gateway, the Origin header is dropped. Pages in tabs are untouched: the
   rule matches only this extension as the initiator. With a gateway token
   set the rule is irrelevant -- the token is the gate. */
export async function syncOriginRule(settings) {
  const s = settings || (await getSettings());
  const origin = normalizeGatewayUrl(s.gatewayUrl);
  await chrome.declarativeNetRequest.updateDynamicRules({
    removeRuleIds: [ORIGIN_RULE_ID],
    addRules: [{
      id: ORIGIN_RULE_ID,
      priority: 1,
      action: {
        type: "modifyHeaders",
        requestHeaders: [{ header: "origin", operation: "remove" }],
      },
      condition: {
        urlFilter: "|" + origin + "/",
        initiatorDomains: [chrome.runtime.id],
        resourceTypes: ["xmlhttprequest", "other"],
      },
    }],
  });
}

export class GatewayError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

/* fetch() against the configured gateway with the bearer token attached. */
export async function gwFetch(path, opts = {}, settings) {
  const s = settings || (await getSettings());
  const headers = new Headers(opts.headers || {});
  if (s.token) headers.set("Authorization", "Bearer " + s.token);
  const url = normalizeGatewayUrl(s.gatewayUrl) + path;
  let timer = null;
  let signal = opts.signal;
  if (opts.timeoutMs) {
    const ac = new AbortController();
    timer = setTimeout(() => ac.abort(new DOMException("timed out", "TimeoutError")), opts.timeoutMs);
    if (signal) signal.addEventListener("abort", () => ac.abort(signal.reason), { once: true });
    signal = ac.signal;
  }
  try {
    return await fetch(url, Object.assign({}, opts, { headers, signal, credentials: "omit" }));
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/* Read a failed response into one sentence for the user. */
export async function describeFailure(r) {
  let detail = "";
  try {
    const text = await r.text();
    try {
      const j = JSON.parse(text);
      detail = (j && j.error && (j.error.message || j.error)) || j.message || text;
    } catch {
      detail = text;
    }
  } catch {}
  detail = String(detail || "").trim().slice(0, 400);
  if (r.status === 401) return "The gateway needs a token (PASCLAW_GATEWAY_TOKEN). Add it in the extension settings.";
  return `HTTP ${r.status}${detail ? ": " + detail : ""}`;
}

export async function checkHealth(settings) {
  try {
    const r = await gwFetch("/v1/health", { timeoutMs: 4000 }, settings);
    if (!r.ok) return { ok: false, error: await describeFailure(r) };
    let body = {};
    try { body = await r.json(); } catch {}
    return { ok: true, body };
  } catch (e) {
    return { ok: false, error: e && e.name === "TimeoutError" ? "timed out" : "unreachable" };
  }
}

/* Injected into a tab with chrome.scripting.executeScript({func}). Must be
   self-contained: it is serialised, so it cannot close over anything. */
export function extractPageInTab(limit) {
  const clean = (s) => String(s || "").replace(/[ \t\f\v ]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
  const sel = clean(String(window.getSelection ? window.getSelection() : ""));
  const root = document.querySelector("article, main, [role=main]") || document.body;
  let text = clean(root ? root.innerText : "");
  if (root !== document.body && text.length < 400 && document.body) text = clean(document.body.innerText);
  const truncated = text.length > limit;
  if (truncated) text = text.slice(0, limit);
  const meta = document.querySelector('meta[name="description"], meta[property="og:description"]');
  return {
    title: document.title || "",
    url: location.href,
    description: meta ? clean(meta.getAttribute("content")).slice(0, 500) : "",
    selection: sel.slice(0, limit),
    text,
    truncated,
  };
}

export function newSessionId() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  const stamp = `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}T${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
  const rand = Array.from(crypto.getRandomValues(new Uint8Array(4)), (b) => b.toString(16).padStart(2, "0")).join("");
  return `chrome-${stamp}-${rand}`;
}
