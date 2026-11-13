/* PasClaw for Chrome -- options page. */

import {
  getSettings, saveSettings, normalizeGatewayUrl, ensureHostPermission, gwFetch, describeFailure,
} from "./lib/config.js";

const $ = (id) => document.getElementById(id);
const result = $("result");

function show(msg, ok) {
  result.textContent = msg;
  result.className = ok === undefined ? "" : ok ? "ok" : "bad";
}

function formValues() {
  return {
    gatewayUrl: normalizeGatewayUrl($("gatewayUrl").value),
    token: $("token").value.trim(),
    pageCharLimit: Math.max(1000, Math.min(200000, parseInt($("pageCharLimit").value, 10) || 20000)),
    serverHistory: $("serverHistory").checked,
  };
}

async function fill() {
  const s = await getSettings();
  $("gatewayUrl").value = s.gatewayUrl;
  $("token").value = s.token;
  $("pageCharLimit").value = s.pageCharLimit;
  $("serverHistory").checked = s.serverHistory;
}

/* Both handlers ask for host access first thing: permissions.request only
   works while the click's user gesture is still live. */
async function grantFor(url) {
  const ok = await ensureHostPermission(url, { request: true }).catch(() => false);
  if (!ok) show(`Chrome did not grant access to ${url}. The extension cannot reach that gateway without it.`, false);
  return ok;
}

$("form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const v = formValues();
  if (!(await grantFor(v.gatewayUrl))) return;
  const s = await saveSettings(v);
  $("gatewayUrl").value = s.gatewayUrl;
  show("Saved.", true);
});

$("test").addEventListener("click", async () => {
  const v = formValues();
  if (!(await grantFor(v.gatewayUrl))) return;
  await saveSettings(v);           // the Origin rule follows the saved URL
  show("Testing " + v.gatewayUrl + " …");
  try {
    const h = await gwFetch("/v1/health", { timeoutMs: 5000 }, v);
    if (!h.ok) return show("Health check failed: " + (await describeFailure(h)), false);
    const health = await h.json().catch(() => ({}));
    /* /v1/health is exempt from the token; /v1/status is not, so it also
       proves the token and the Origin handling. */
    const st = await gwFetch("/v1/status", { timeoutMs: 5000 }, v);
    if (!st.ok) return show("Gateway is up, but /v1/status failed: " + (await describeFailure(st)), false);
    const status = await st.json().catch(() => ({}));
    const lines = ["Connected and saved."];
    if (health.version) lines.push("PasClaw " + health.version);
    const prov = status.provider || status.default_provider;
    const model = status.model || status.default_model;
    if (prov || model) lines.push(`Default: ${[prov, model].filter(Boolean).join(" / ")}`);
    show(lines.join("\n"), true);
  } catch (err) {
    show(`Could not reach ${v.gatewayUrl}. Is \`pasclaw gateway\` running there?`, false);
  }
});

$("show").addEventListener("click", () => {
  const t = $("token");
  t.type = t.type === "password" ? "text" : "password";
  $("show").textContent = t.type === "password" ? "Show" : "Hide";
});

fill();
