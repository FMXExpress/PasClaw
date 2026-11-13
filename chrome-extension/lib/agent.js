/* PasClaw for Chrome -- the Browse-mode agent loop.

   The gateway's /v1/responses route passes client-defined tools straight
   to the model and hands the calls back instead of running them (the
   path Codex CLI uses). This loop:
     1. sends the conversation plus TOOL_DEFS,
     2. runs each function_call it gets back in the tab, asking the user
        first for anything that changes the page,
     3. sends the results back as function_call_output items,
   until the model answers in plain text, the step budget runs out, or the
   user stops it.

   In this mode PasClaw's own server-side tools and system prompt are not
   used (the passthrough skips them); the model works only with the page. */

import { gwFetch, describeFailure } from "./config.js";
import { TOOL_DEFS, SYSTEM_PROMPT, READ_ONLY, runTool } from "./page-tools.js";

export const MAX_STEPS = 30;

function parseArgs(s) {
  try { const v = JSON.parse(s || "{}"); return v && typeof v === "object" ? v : {}; } catch { return {}; }
}

/* history: earlier Browse-mode input items in this chat (mutated: the new
   turn's items are appended). hooks:
     onText(text)                       assistant text arrived
     onCall({ id, name, args })         a call is about to be considered
     approve({ id, name, args }) -> Promise<boolean>   only for mutating calls
     onResult({ id, name, args, output, denied })
     onStep(n) */
export async function runBrowseTask({ settings, model, tabId, userText, history, signal, hooks }) {
  const items = history;
  items.push({ role: "user", content: userText });
  const texts = [];

  for (let step = 1; step <= MAX_STEPS; step++) {
    if (signal.aborted) throw new DOMException("stopped", "AbortError");
    hooks.onStep && hooks.onStep(step);

    const body = {
      input: [{ role: "system", content: SYSTEM_PROMPT }, ...items],
      tools: TOOL_DEFS,
      tool_choice: "auto",
      max_output_tokens: 4096,
    };
    if (model) body.model = model;

    const r = await gwFetch("/v1/responses", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal,
    }, settings);
    if (!r.ok) throw new Error(await describeFailure(r));
    const j = await r.json();
    if (j.error && j.error.message) throw new Error(j.error.message);
    if (!Array.isArray(j.output)) throw new Error("The gateway's /v1/responses reply has no output. Update PasClaw to a build with tool passthrough.");

    const calls = [];
    for (const it of j.output) {
      if (it.type === "message") {
        const t = (it.content || []).map((c) => c.text || "").join("").trim();
        if (t) { texts.push(t); items.push({ role: "assistant", content: t }); hooks.onText && hooks.onText(t); }
      } else if (it.type === "function_call") {
        calls.push(it);
      }
    }
    if (!calls.length) return { text: texts.join("\n\n"), steps: step };

    for (const c of calls) {
      const call = { id: c.call_id || c.id, name: c.name, args: parseArgs(c.arguments) };
      const echo = { type: "function_call", call_id: call.id, name: c.name, arguments: c.arguments || "{}" };
      if (c.provider_signature) echo.provider_signature = c.provider_signature;
      items.push(echo);

      if (signal.aborted) {
        items.push({ type: "function_call_output", call_id: call.id, output: "Stopped by the user." });
        throw new DOMException("stopped", "AbortError");
      }
      hooks.onCall && hooks.onCall(call);
      let output;
      let denied = false;
      if (!TOOL_DEFS.some((t) => t.name === call.name)) {
        output = `Error: unknown tool ${call.name}.`;
      } else if (!READ_ONLY.has(call.name) && !(await hooks.approve(call))) {
        if (signal.aborted) {
          items.push({ type: "function_call_output", call_id: call.id, output: "Stopped by the user." });
          throw new DOMException("stopped", "AbortError");
        }
        denied = true;
        output = "The user denied this action. Do not retry it; ask or explain instead.";
      } else {
        output = await runTool(tabId, call.name, call.args, { pageChars: Math.min(settings.pageCharLimit || 6000, 12000) });
      }
      items.push({ type: "function_call_output", call_id: call.id, output });
      hooks.onResult && hooks.onResult({ ...call, output, denied });
    }
  }
  const t = `I stopped after ${MAX_STEPS} steps without finishing. Tell me how you'd like to continue.`;
  texts.push(t);
  items.push({ role: "assistant", content: t });
  hooks.onText && hooks.onText(t);
  return { text: texts.join("\n\n"), steps: MAX_STEPS };
}

/* Page snapshots are large and go stale. Before a finished task's items
   become history for the next one, shrink old get_page results. */
export function compactHistory(items, keepLast = 80) {
  const out = items.map((it) =>
    it.type === "function_call_output" && /^URL: /.test(it.output || "") && it.output.length > 400
      ? { ...it, output: it.output.split("\n").slice(0, 2).join("\n") + "\n(older page snapshot omitted)" }
      : it);
  if (out.length <= keepLast) return out;
  /* Cut at a user turn so no function_call loses its output. */
  let start = out.length - keepLast;
  while (start < out.length && out[start].role !== "user") start++;
  return out.slice(start);
}
