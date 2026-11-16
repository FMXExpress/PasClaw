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
- **Read-only or not.** `wf_<id>` is read-only only when the whole run
  is: every step is a read-only tool or an `llm` step, so is the tool any
  step's `await` polls with, and the workflow declares no outputs (a run
  writes those to `workflows/<id>/<stamp>/`). A step or poll that writes,
  an MCP tool, a name that isn't a registered tool, or declared outputs
  make it mutating. That decides plan mode and what `/mcp` serves: the
  endpoint serves read-only tools unless the gateway runs with
  `--mcp-allow-write`, and the same applies to workflows.
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
plan and space mode, `BeforeToolCall` / `AfterToolResult` hooks and the
promptware scan. (Not the output cap: a step's output is the next step's
input, and cutting it would break the chain. The workflow's result is
capped where it reaches the model.) Before this, steps called their tools
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

When the agent saves a workflow, you are asked first, in the chat it is
working in.

- **In a chat.** The question appears where you are: a card under the
  agent's reply in the web UI, the footer in the TUI, a prompt in the CLI,
  the editor's permission dialog over ACP. It shows what the workflow will
  be called and every step with its arguments. **Save** makes it the tool
  `wf_<id>` straight away. **Don't save** drops it: nothing is saved or
  kept for later, and the agent is told you said no. **Save, and don't ask
  again for it in this chat** also lets later saves of that same workflow
  in this chat through without asking. If the workflow is already saved,
  the card says the new version replaces it.
- **When nobody can be asked,** the workflow waits for you instead. That
  covers another agent saving over MCP, an API call with no web UI chat, a
  team agent's turn, and a question nobody answered in time. It is staged
  in `workspace/workflows/.pending/<id>.json`, and the web UI's header
  shows **N to approve**. The badge opens a list of everything waiting
  (staged workflows and staged skills), each with its steps and **Approve**
  / **Reject**. A staged workflow does not run and is not a tool. If one
  with that id is already saved, the saved version keeps running until you
  approve the new one.

The same list is in the Workflow tab, and on the command line:

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

- **Over HTTP:** `GET /v1/workflows/pending`, then
  `POST /v1/workflows/pending/approve` with `{"id": "...", "sha256": "..."}`
  or `POST /v1/workflows/pending/reject` with `{"id": "..."}`.
- **The sha256** is the one the list (or `show`) gave you. If the staged
  file has changed since then, for example because the agent saved again,
  the approval is refused, so you never approve a version you haven't
  read. The web UI sends it for you, and `--sha256` does the same on the
  command line. Approving checks the workflow is valid again before saving
  it.
- **Your own saves are not asked about:** the editor, `POST /v1/workflows`
  and `PUT /v1/workflows/<id>` save directly.
- **Turn it off** with `"workflows_auto_approve": true` in `config.json`.
  The agent's saves are then saved without asking.
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
