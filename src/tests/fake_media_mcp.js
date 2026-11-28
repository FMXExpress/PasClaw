#!/usr/bin/env node
/* A small MCP server (stdio, the initialize handshake) for
   webui_workflow_media_e2e.js. Two tools:

     predict  a rich input schema (text, integer, number, boolean, enum,
              an array, a nested object, an object nested deeper, a
              required field) that answers with a Replicate-shaped
              prediction as JSON text: its "output" is the "output"
              argument, so the test decides which media URLs it points at.
     say      answers with its "text" argument (markdown).

   usage: node fake_media_mcp.js */
const readline = require("readline");

const PREDICT = {
  name: "predict",
  description: "Make media (fake): answers with a prediction whose output is the output argument.",
  inputSchema: {
    type: "object",
    properties: {
      prompt:   { type: "string", description: "What to make." },
      steps:    { type: "integer", description: "Denoising steps.", default: 20 },
      guidance: { type: "number", description: "How closely to follow the prompt.", default: 7.5 },
      enhance:  { type: "boolean", description: "Rewrite the prompt first.", default: true },
      style:    { type: "string", enum: ["photo", "anime", "sketch"], default: "photo" },
      tags:     { type: "array", items: { type: "string" }, description: "Extra tags." },
      size:     { type: "object", description: "Output size in pixels.",
                  properties: { width: { type: "integer", default: 512 }, height: { type: "integer", default: 512 } } },
      extra:    { type: "object", properties: { lora: { type: "object", properties: { name: { type: "string" } } } } },
      image:    { type: ["string", "null"], format: "uri", description: "An image to start from." },
      output:   { description: "What the prediction answers with: a URL or a list of them.",
                  anyOf: [{ type: "string" }, { type: "array", items: { type: "string" } }] },
    },
    required: ["prompt"],
  },
};
const SAY = { name: "say", description: "Answer with the text given.",
              inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] } };

let initialized = false, seq = 0;
const send = o => process.stdout.write(JSON.stringify(o) + "\n");
const result = (id, r) => send({ jsonrpc: "2.0", id, result: r });
const error = (id, code, message) => send({ jsonrpc: "2.0", id, error: { code, message } });
const text = t => ({ content: [{ type: "text", text: t }] });

readline.createInterface({ input: process.stdin }).on("line", line => {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  const { id, method, params = {} } = msg;
  if (id === undefined) return;   // a notification
  if (method === "initialize") {
    initialized = true;
    return result(id, { protocolVersion: params.protocolVersion || "2025-06-18",
                        capabilities: { tools: {} }, serverInfo: { name: "fake-media", version: "1.0" } });
  }
  if (!initialized) return error(id, -32601, "Method not found: " + method);
  if (method === "ping") return result(id, {});
  if (method === "tools/list") return result(id, { tools: [PREDICT, SAY] });
  if (method === "tools/call") {
    const a = params.arguments || {};
    if (params.name === "say") return result(id, text(String(a.text || "")));
    if (params.name !== "predict") return error(id, -32602, "unknown tool " + params.name);
    const pid = "p" + (++seq);
    return result(id, text(JSON.stringify({
      id: pid, model: "fake/" + (a.image ? "upscale" : "image"), version: "0123456789abcdef", status: "succeeded",
      input: a, output: a.output === undefined ? null : a.output, error: null, logs: "",
      urls: { get: "https://api.replicate.example/v1/predictions/" + pid, web: "javascript:window.__wfXss=3" },
      metrics: { predict_time: 1.25 } })));
  }
  return error(id, -32601, "Method not found: " + method);
});
