# Design: agent-built + manual workflows (Replicate MCP chaining)

Status: **implemented** (all phases landed on branch `claude/workflows`).
Phase 0 (structured MCP output), Phase 1 (engine + store + gateway endpoints +
agent tools), Phase 2 (Workflow tab: node editor + palette + SVG graph + run),
and Phase 3 (agent authoring via workflow_save + the `## Workflows` prompt
section) are wired and tested. The node editor is a form+graph editor (add
nodes from the MCP-tool palette, edit args, connect edges, live SVG preview,
run with per-node status); free-form drag-and-drop canvas positioning is the
one deferred follow-up.

**Async tools (open question 2 — resolved).** Replicate's hosted MCP
`create_prediction` is async: it returns a pending prediction id/status, not
the finished image (the REST API is async by default; sync `Prefer: wait` mode
exists but caps at ~60s). The engine handles both cases:
- **Sync/fast:** a node whose tool blocks and returns the final output needs no
  extra config — the engine just uses what the tool returns.
- **Async/slow:** add an optional per-node `await` block — a fully generic
  poll-until-terminal step (configurable poll tool, args with `{{self.SELECTOR}}`
  referencing the create result, `status_selector`, `success[]`/`failure[]`
  sets, `interval_ms`, `timeout_ms`). The node's stored result becomes the
  completed poll response, so downstream selectors read the finished output.
  Nothing here is Replicate-specific.

## Goal

Let an operator chain tool calls — starting with the Replicate MCP (e.g.
`generate → upscale`) — two ways:

1. **Manually**, via a drag-and-drop node editor in the web UI ("Workflow" tab).
2. **By asking the agent** ("build me a generate→upscale workflow"), which
   authors a saved workflow the operator can inspect, run, and edit.

A saved workflow is a persisted artifact that can be run headless (no LLM turn),
from the UI, from the agent, or from cron.

## The one hard constraint (why Phase 0 exists)

MCP tool results are **flattened to a text string** before anything above the
client sees them. `TMCPHttpClient.CallTool` / `TMCPStdioClient.CallTool` keep
only `content[]` blocks of `type:"text"`, concatenate their `.text`, and free
the JSON-RPC envelope in place (`src/pkg/mcp/PasClaw.MCP.HttpClient.pas:416`,
`PasClaw.MCP.StdioClient.pas:393`). `structuredContent`, `type:"image"`,
`type:"resource"` blocks, and the raw `result` object are all discarded.

Consequences for chaining:

- A `generate` step's image URL usually arrives *inside* a text block, so it is
  technically reachable — but only by string-scraping a URL out of prose, which
  is brittle.
- If a tool returns its output only in `structuredContent` or a non-text block,
  it is **lost entirely** — there is no structured path today.

So typed edge data flow (upstream output field → downstream input field) is not
possible without extending the one MCP choke point. That extension is Phase 0.

## Node types

A node's `tool` can be:
- an **MCP tool** (`server__tool`, e.g. `replicate__create_prediction`) → the MCP bridge;
- the special **`llm`** node → any configured provider (with its API key): `args {provider, model, prompt, system?}` → a one-shot `Chat` → the reply text (bare `{{nodes.ID}}` downstream = that text; or `{{nodes.ID.text}}`);
- **any other registered tool** (`web_fetch`, …) → the tool registry.

Routing lives in `PasClaw.Workflow.Dispatch.WorkflowDispatch`; the registry and provider config are set once at startup (`SetWorkflowRegistry` from the shared RegisterSkills hook, `SetWorkflowConfig` from the gateway / agent) — the same module-global pattern `ConfigureSandbox` uses, because the engine's caller is a plain function pointer.

## Architecture

```
Workflow artifact  →  $PASCLAW_HOME/workspace/workflows/<id>.json   (nodes[] + edges[])
        │ registered as
        ▼
Callable tool      →  workflow_<name>            (agent + cron can invoke, like skill_<name>)
        │ executed by
        ▼
Engine (in-process)→  topo-sort nodes; each node = Registry.RunTool('replicate__x', argsJSON)
        │ edges map
        ▼
Data flow          →  upstream ResultJSON → selector → downstream arg    (needs Phase 0)
        │ observed via
        ▼
SSE                →  GET /v1/workflows/<id>/run   (reuse gwSseUrl pattern)
```

Key existing seams this reuses (no new plumbing):

- **Single-tool call, no LLM:** `TToolRegistry.RunTool(Name, ArgsJSON, out Err)`
  (`src/pkg/tools/PasClaw.Tools.Registry.pas:400`). MCP tools are named
  `replicate__<tool>` (double underscore; `PasClaw.MCP.Bridge.pas:303`) and
  carry their `inputSchema` verbatim on `TTool.Schema`.
- **JSON-file-per-item store:** mirror the sessions store
  (`$PASCLAW_HOME/workspace/sessions/*.json`; CRUD in `HandleSessionItem`,
  `PasClaw.Gateway.Server.pas:3052`). Whole `workspace/` rides the export zip
  automatically (`Server.pas:196`).
- **"Saved thing becomes a callable tool":** shell/prompt skills register as
  `skill_<name>` in `PasClaw.Skills.Loader`; workflows register as
  `workflow_<name>` the same way.
- **Agent-authored + operator-approved staging:** the skills `.pending/`
  approve/reject pipeline (`PasClaw.Skills.Pending.pas`) is reused verbatim for
  agent-authored workflows.
- **UI tab contract:** nav button + `#tab-workflow` pane + `tabLoaders.workflow`
  in `src/pkg/gateway/webui.html` (rebuild `.res` via `make` after editing).

## Workflow JSON schema (v1)

```jsonc
{
  "id": "gen-upscale",               // stable id == filename stem
  "name": "gen_upscale",             // -> registers workflow_gen_upscale
  "description": "Generate an image then upscale it 4x",
  "inputs": [                        // workflow-level params (fill at run time)
    { "name": "prompt", "type": "string", "required": true }
  ],
  "nodes": [
    { "id": "gen",  "tool": "replicate__create_prediction",
      "args": { "model": "black-forest-labs/flux-schnell",
                "input": { "prompt": "{{inputs.prompt}}" } } },
    { "id": "up",   "tool": "replicate__create_prediction",
      "args": { "model": "nightmareai/real-esrgan",
                "input": { "image": "{{nodes.gen.output.url}}", "scale": 4 } } }
  ],
  "edges": [
    { "from": "gen", "to": "up" }    // ordering + data dependency
  ]
}
```

- `{{inputs.X}}` — a workflow input.
- `{{nodes.<id>.<selector>}}` — a value pulled from an upstream node's result.
  `<selector>` is a small dotted/JSONPath-lite path evaluated against that
  node's **structured** result (Phase 0). `output.url`, `output[0]`,
  `content[?type=image].url` are the target shapes.
- Missing/ambiguous selector → the run fails that node with a clear error
  (fail-fast; no silent empty-string substitution).

## Phase 0 — structured MCP output (prerequisite, ~1 day, own PR)

Extend the MCP client contract so callers can opt into the raw result:

- `PasClaw.MCP.Types.pas:51` — add `out ResultJSON: string` to the `CallTool`
  signature (the full `result` object as JSON; `''` if absent).
- `PasClaw.MCP.HttpClient.pas` / `StdioClient.pas` — capture `result` verbatim
  before freeing the envelope; keep the existing text flattening unchanged.
- `PasClaw.MCP.Bridge.pas` `TMCPServerState.CallTool` — thread `ResultJSON`
  through.
- Existing callers pass/ignore the new out-param → **zero behavior change**;
  add a test asserting `structuredContent` and an image block survive.

This is independently useful (any future structured-output consumer benefits)
and is the gate for typed edges.

## Phase 1 — engine + store + headless run (~3–4 days, own PR)

New unit `PasClaw.Workflow.pas`:

- **Schema + parse/serialize** (`TWorkflowSpec`): nodes, edges, inputs.
- **Validator:** DAG (no cycles), every `tool` exists in the registry, every
  `{{nodes.X…}}` references a declared upstream node, required inputs present.
- **Executor:** topological order; per node resolve `args` templates
  (`{{inputs.*}}`, `{{nodes.*.*}}`) against prior results, then
  `Registry.RunTool(node.tool, resolvedArgs)`; store each node's structured
  result for downstream selectors. Fail-fast with the offending node id.
- **Selector:** minimal dotted path + `[i]` index + a single
  `[?key=value]` filter over the structured result (Phase 0). No full JSONPath.

Store + registration:

- `$PASCLAW_HOME/workspace/workflows/<id>.json`, CRUD mirroring the sessions
  store.
- Register each saved workflow as a `workflow_<name>` tool (mirror
  `RegisterSkills`), so the agent/cron can invoke a whole chain by name.

Gateway endpoints (mirror the sessions route block, `Server.pas:1328-1330`):

- `GET  /v1/workflows` — list.
- `POST /v1/workflows` — create/validate; `422` with node-level errors on
  invalid graphs.
- `GET/PUT/DELETE /v1/workflows/<id>` — read/replace/delete.
- `GET  /v1/workflows/<id>/run` — SSE stream of per-node status
  (`started` / `result` / `error` / `done`), reusing the existing `gwSseUrl`
  token-in-query pattern.

**Phase 1 deliverable:** a hand-written `gen_upscale.json` runs end-to-end
headless and produces the upscaled image URL — proving the chain before any UI.

## Phase 2 — Workflow tab + node editor (~4–6 days, sketch)

- Three edits add the tab (nav button, `#tab-workflow` pane,
  `tabLoaders.workflow`).
- The node editor is **vanilla SVG, hand-rolled** — `webui.html` ships as a
  single self-contained file with no external scripts and no existing
  canvas/graph code, so no React-Flow/LiteGraph. Nodes = draggable SVG groups;
  edges = SVG paths; a node's input fields are generated from the MCP tool's
  `inputSchema`.
- Node palette is populated from the MCP tool list. (Note: there is **no**
  existing endpoint that enumerates outbound MCP tools — a small
  `GET /v1/mcp/tools` returning `{name, description, schema}` is needed here.)
- Save → `PUT /v1/workflows/<id>`; Run → the SSE endpoint with live per-node
  status painted on the canvas.

## Phase 3 — agent authoring (~2–3 days, sketch)

- `workflows_manage` tool (create/edit/validate) with a schema-teaching
  description, plus a "Workflow authoring" system-prompt section that lists the
  available MCP tools + schemas (the same idea as the skill-authoring primer
  shipped in this PR).
- Agent-authored workflows land in `workspace/workflows/.pending/` and surface
  in the Workflow tab with Approve/Reject — reusing the skills `.pending`
  machinery.

## Build order / recommendation

Ship **Phase 0 then Phase 1** first: that yields a working, saveable
generate→upscale chain driven by JSON, de-risking the MCP-chaining unknown in
~1 week before committing to the multi-week node editor. Phase 2 (UI) and
Phase 3 (agent authoring) follow independently.

## Open questions

1. Selector language: is dotted + `[i]` + one `[?k=v]` filter enough for
   Replicate's output shapes, or is full JSONPath worth a dependency?
2. Long-running predictions: Replicate `create_prediction` may return a
   pending id needing polling. Does the engine need a per-node
   poll-until-complete step, or does the Replicate MCP block until done?
   (Determines whether nodes need a `poll` sub-kind.)
3. Should `workflow_<name>` tools be default-on for the agent, or opt-in like
   `skills_manage`?
