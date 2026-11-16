# Workflows

A workflow is a saved chain of tool calls: each step (a node) calls a
registered tool, an MCP tool (`server__tool`) or a model (`llm`), and later
steps read earlier steps' output through `{{nodes.<id>}}` and the run's
inputs through `{{inputs.<name>}}`. Workflows live in
`$PASCLAW_HOME/workspace/workflows/<id>.json`. You build them in the web
UI's **Workflow** tab; the agent builds them with `workflow_save` and runs
them with `workflow_run`. The schema and the engine are described in
[the design notes](./workflows-design.md).

## Each workflow is a tool

Every saved workflow is also a tool named `wf_<id>`. Its arguments are the
workflow's inputs, with their types and which ones are required:

```json
{"name": "wf_digest",
 "description": "Summarise a page. (Saved workflow \"digest\": web_fetch -> llm. …)",
 "inputSchema": {"type": "object",
                 "properties": {"url": {"type": "string"}},
                 "required": ["url"]}}
```

The agent sees these tools beside its built-in ones. Other agents can call
them over MCP through the gateway's `/mcp` endpoint (and `/v1/mcp/rpc`,
and the `--mcp-port` listener):

```sh
claude mcp add --transport http pasclaw http://127.0.0.1:8088/mcp
```

- **No restart.** The tool list is read from the workflow store on each
  lookup, so a workflow saved, approved or deleted is in (or out of) the
  next `tools/list` and the agent's next request. The store is re-read
  only when its directory listing changes or something in the same
  process saved or deleted a workflow.
- **Read-only or not.** `wf_<id>` is read-only when every step is a
  read-only tool or an `llm` step. A step that writes, an MCP tool step,
  or a step naming a tool that doesn't exist makes it mutating. Over MCP
  that decides whether it is served: the endpoint serves read-only tools
  unless the gateway runs with `--mcp-allow-write`, and the same applies to
  workflows.
- **Names.** Characters a tool name can't hold become `_`, and the name is
  cut to 64 characters.
- **Cost.** Each `wf_<id>` tool's schema is sent with every request, like
  any other tool the agent can see. If you have many workflows, delete the
  ones you don't use.
- **Not on `pasclaw mcp stdio`.** That server exposes a fixed, hand-picked
  set of data tools. Running a workflow needs the full tool registry and
  the configured MCP servers, which only the gateway loads. Hosts that
  speak MCP over HTTP can use the gateway's `/mcp` endpoint.

## Every step goes through the same gates

A workflow step meets the same checks as a tool call the agent makes
directly: the [permission rules](./security.md#permissions-ordered-rules),
plan and space mode, `BeforeToolCall` / `AfterToolResult` hooks, the
promptware scan and the output cap. Before this, steps called their tools
directly, so a rule like `deny read_file` did not stop a workflow from
calling `read_file`.

- **Run from a turn** (`workflow_run`, or the agent calling `wf_<id>`): the
  turn's own gates apply. An `ask` rule asks you, the same way it does for
  the turn's own calls.
- **Run from anywhere else** (the web UI's Run button,
  `POST /v1/workflows/<id>/run`, an MCP client): the rules apply, and an
  `ask` is refused because there's nobody to ask.
- **A refused step fails the run.** The refusal is the step's error, and
  the steps after it do not run. They don't get the text `refused: …` as
  their input.
- **No gate, no run.** A build that has no tool loop to check a step
  fails the step rather than running it unchecked.
- `llm` steps call a provider and are not tools, so tool rules don't
  apply to them. Their prompts come from the workflow and from the
  outputs of earlier steps, and those steps were checked.

## Approval

When the agent saves a workflow, it is **staged**, not saved. It does not
run and is not a tool until you approve it. Skills the agent writes work
the same way.

```
$ pasclaw workflow pending
  digest                       2 step(s)  Summarise a page.

$ pasclaw workflow show digest
Waiting for approval -- sha256 3f1c…
digest
  Summarise a page.
Inputs:
  url: string (required)
Steps:
  fetch  web_fetch
      {"url":"{{inputs.url}}"}
  sum  llm
      {"prompt":"Summarise:\n{{nodes.fetch}}"}
Order:
  fetch -> sum

$ pasclaw workflow approve digest
✓ approved digest -- it runs now, and is the tool wf_digest (no restart needed)
```

- **Where it waits:** `workspace/workflows/.pending/<id>.json`. The agent
  is told it is waiting and how to approve it. If a workflow with that id
  is already saved, the saved version keeps running until you approve the
  new one.
- **Review it** in the web UI's Workflow tab (under *Waiting for
  approval*, each step with its arguments), with `pasclaw workflow show
  <id>`, or with `GET /v1/workflows/pending`.
- **Approve** with the tab's button, `pasclaw workflow approve <id>`, or
  `POST /v1/workflows/pending/approve` with `{"id": "...", "sha256": "..."}`.
  The `sha256` is the one the listing (or `show`) gave you. If the staged
  file has changed since then, for example because the agent saved again,
  the approval is refused, so you never approve a version you haven't
  read. The tab sends it for you, and `--sha256` does the same on the
  command line. Approving checks the workflow is valid again before saving
  it.
- **Reject** with the tab's button, `pasclaw workflow reject <id>`, or
  `POST /v1/workflows/pending/reject` with `{"id": "..."}`.
- **Your own saves are not staged:** the editor, `POST /v1/workflows` and
  `PUT /v1/workflows/<id>` save directly.
- **Turn it off** with `"workflows_auto_approve": true` in `config.json`.
  The agent's saves are then saved directly, as they were before this
  change.
- **The file tools can't write around it.** `write_file`, `edit_file` and
  the other file tools refuse a workflow spec
  (`workflows/<id>.json`) and anything under `workflows/.pending/`, and the
  refusal tells the agent to use `workflow_save`. A run's outputs
  (`workflows/<id>/<stamp>/…`) can still be written. `shell_exec` can't
  be checked by path, so an agent with a shell could still write the file
  directly. Skill approval has the same limit. If that matters, restrict
  the shell with [permission rules](./security.md#permissions-ordered-rules)
  or run it in the [Docker backend](./security.md#docker-shell-backend).
- `pending` can't be used as a workflow id, because
  `/v1/workflows/pending` is the approval list's route.

## Routes and commands

| | |
|---|---|
| `GET /v1/workflows` | Saved workflows. |
| `POST /v1/workflows`, `PUT /v1/workflows/<id>` | Save (yours; not staged). |
| `POST /v1/workflows/<id>/run` | Run one; the body is the inputs. Steps meet the rules; `ask` is refused. |
| `GET /v1/workflows/pending` | Staged workflows: `id`, `name`, `description`, `nodes`, `replaces`, `sha256`, `spec`. |
| `POST /v1/workflows/pending/approve` | `{"id", "sha256"?}` |
| `POST /v1/workflows/pending/reject` | `{"id"}` |
| `pasclaw workflow list` | Saved workflows and the tool each is served as. |
| `pasclaw workflow pending` / `show <id>` / `approve <id> [--sha256 <hex>]` / `reject <id>` | As above. |

The `/v1/workflows` routes answer only when `workflows_enabled` is on, which
is the default.
