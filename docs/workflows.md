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

## In the web UI

The **Workflow** tab lists the saved workflows and opens one in an editor:
steps as cards on a canvas, the selected step's settings beside it, and a
run under it.

**A step's arguments are a form.** For an MCP tool (`GET /v1/mcp/tools`)
or a built-in one (`GET /v1/tools`) the settings show one field per
property of the tool's input schema:

| Property | Field |
|---|---|
| `string` | a text field; a textarea for long text and prompts |
| `number`, `integer` | a number |
| `boolean` | a checkbox |
| `enum` | a select |
| an array of strings, numbers or booleans | a list you add to and remove from |
| an object with properties | a fieldset with its own fields; JSON for anything nested deeper |

Required properties are marked with `*`, the description is the hint
under the field, and the default is the placeholder (a field left empty
isn't sent, so the tool's default applies). A field that holds a
template, `{{inputs.prompt}}` or `{{nodes.gen.output[0]}}`, is text
whatever the property's type, and is saved as you typed it: a number
field holding `{{inputs.steps}}` saves the string. A checkbox or a select
has a `{{ }}` button to type a template instead.

The JSON is still there, under **Arguments as JSON**, and the two follow
each other: a form edit rewrites the JSON (keeping keys the schema doesn't
name), and a JSON edit refills the form. JSON that doesn't parse shows
the error under it and leaves the form as it was. A tool with no schema
has the JSON alone. LLM steps keep their provider, model and prompt form,
and a Replicate model's inputs use the same schema form.

**A run shows what it made.** After a run:

- each step's result is in the run panel, and in the step's settings when
  you click its card. JSON is pretty-printed with collapsible sections; a
  Replicate prediction gets a line with its `status`, `model` and
  `metrics.predict_time` above it. Text is rendered as markdown.
- clicking the **Outputs** box shows each declared output's name and
  value (the run route's `outputs`).
- media in a result shows as an image, a video or an audio player, and as
  a thumbnail on the step's card and on the Outputs box. Clicking an image
  or video opens it large (Esc closes it), with a link to the original.

Media is found by URL: a result that is a URL; the `output`, `url`,
`image`, `images`, `video` and `audio` fields; any other string or list
of strings that is a URL; and `data:` URIs. The file extension says what
it is (png, jpg, jpeg, webp, gif, avif; mp4, webm, mov; mp3, wav, ogg,
m4a, flac); a URL without one counts only under a field named for a kind,
such as `image` or `video`. Nothing is fetched to find out. Only `http`,
`https` and `data:` image, video and audio URLs are shown or linked, with
no referrer; anything else, `javascript:` included, stays text.
## Export as code

A saved workflow can leave PasClaw as a program you run on its own:

```sh
pasclaw workflow export digest --lang python  -o wf_digest.py
pasclaw workflow export digest --lang pascal  -o wf_digest.dpr
```

Without `-o` the source goes to stdout. The same text comes from
`GET /v1/workflows/<id>/export?lang=python|pascal` (a download named
`wf_<id>.py` / `wf_<id>.dpr`) and from **Export** in the web UI's editor
toolbar, which exports the *saved* workflow and asks you to save first when
the editor has changes. In the file name, characters other than letters,
digits and `_` in the id become `_`. Neither export contains a key or token
from your config: they name environment variables instead.

Both programs take the same arguments:

| | |
|---|---|
| `--input NAME=VALUE` | A workflow input (repeatable). A required input that is missing stops the run before it starts. |
| `--json` | Print the outputs as one JSON object. Without it, one output prints as its bare value and several as `name: value` lines. With no declared outputs, the output is the text of the last step that produced one (as `workflow_run`'s `output`). |
| `--no-files` | Don't write the declared outputs to files (they are written by default, as a run in PasClaw writes them). |
| `--help` | The workflow's inputs and outputs. |

Step progress goes to stderr; a failed step exits 1 with the step and its error.

### Object Pascal (`--lang pascal`)

A `.dpr` program that embeds the spec and runs it with PasClaw's own engine
and units (`PasClaw.Workflow.Standalone`). It behaves like a run in PasClaw
because it *is* one: the same templates, selectors, `await` polling, loop and
outputs, every step through the same [permission rules](#every-step-goes-through-the-same-gates)
(an `ask` is refused: nobody can be asked), the built-in tools, skills, the
providers and the MCP servers from `$PASCLAW_HOME/config.json`. Declared
outputs are written to the workspace, under the workflow's output folder.
`pasclaw workflow run <id>` runs a saved workflow the same way, from the
store.

Build it from a PasClaw source checkout. After `make`, against the units
`make` compiled:

```sh
fpc -MDelphi -Sh -Fubuild/lib -FEbuild wf_digest.dpr
```

or straight from the sources, without make (Debian/Ubuntu paths):

```sh
mkdir -p /tmp/wf-units && fpc -MDelphi -Sh -Fusrc/pkg/* -Fusrc/pkg/memory/localvector \
  -Fusrc/pkg/vendor/zpaq -Fuvendor/Indy/Lib/* -Fivendor/Indy/Lib/* \
  -Fu/usr/lib/lazarus/3.0/components/lazutils -FU/tmp/wf-units -FEbuild wf_digest.dpr
```

The program is Delphi-compatible (mode Delphi, FPC-only units behind
`{$IFDEF FPC}`); with Delphi, add the same source folders to the project's
search path. It needs PasClaw's config to find providers, keys and MCP
servers, so it runs where PasClaw is set up.

### Python (`--lang python`)

A single script for Python 3.9+, standard library only. It carries the spec
as data and a re-implementation of the engine: the same `{{inputs.x}}`,
`{{nodes.id}}`, `{{nodes.id.selector}}` and `{{self.x}}` templates
(substituted into the step's argument JSON exactly as the engine does), the
same dependency order, `await` polling, loop (`max`, `until`, `feedback`) and
outputs. The header lists what it needs.

| Step | In the Python script |
|---|---|
| `llm` | `POST <base>/v1/chat/completions` on an OpenAI-compatible endpoint. `LLM_BASE_URL` (default: the provider's `api_base` from the config it was exported from), `LLM_MODEL` (default: the step's model, else the provider's), and the key from `<PROVIDER>_API_KEY` (e.g. `OPENAI_API_KEY`), else `LLM_API_KEY`. An Anthropic provider needs `LLM_BASE_URL` pointed at an OpenAI-compatible endpoint. |
| `replicate` | Replicate's HTTP API with `REPLICATE_API_TOKEN`: creates the prediction (`version`, or `model` as `owner/name` or `owner/name:version`), polls until it succeeds, fails, is cancelled or aborts (5 minutes at most), and the step's output is `output[0]`. `REPLICATE_API_BASE` overrides the host. |
| MCP tool (`server__tool`) | The official `mcp` SDK (`pip install mcp`, imported only when an MCP step runs). Stdio servers start with the command and args from the config at export time and inherit the environment, so set their variables (the header names them; their values are never written); HTTP servers are reached by URL, with an `Authorization` header from `MCP_<SERVER>_AUTH` if set. One session per server for the run. |
| `read_file`, `write_file`, `shell_exec` | Done directly, relative to the current directory. |
| Any other built-in tool | Fails at its step with "not supported in the exported script". |

Declared outputs are written to `<out-dir>/<stamp>/output.json` and one text
file per output, `out-dir` being `--out-dir`, else the workflow's output
folder, else `workflows/<id>`, relative to the current directory.

### What doesn't carry over

- **The gates.** The Python script runs every step it can; PasClaw's
  permission rules, plan mode, hooks and promptware scan are not in it. (The
  Pascal program keeps them.)
- **Tool output format.** A built-in step in Python returns the raw file or
  command output; PasClaw's tools may format theirs (line markers, exit-code
  notes), so a selector on that text can differ. PasClaw's compacting of
  table-shaped MCP results into a table is not reproduced.
- **Providers.** The Python script speaks only the OpenAI chat-completions
  format and sends only the model and messages.
- **MCP bare-name fallback.** PasClaw finds an MCP tool on any connected
  server by its bare name when no server name prefixes it; the script needs
  the prefix to name a server it knows.
- **Replicate through MCP.** A `replicate` step uses the HTTP API in Python
  and the Replicate MCP server in PasClaw; a step that sets its own `await`
  keeps PasClaw's polling only in the Pascal program.
- Numbers in a selector's result are printed the way PasClaw's JSON library
  prints them (`2.5000000000000000E+000`), in both.

## Sharing workflows

Someone builds a workflow and posts the file; someone else loads it. The
file is the portable workflow file, `<id>.pasclaw-workflow.json`:

```json
{
  "format": "pasclaw-workflow",
  "version": 1,
  "exported_at": "2026-11-28T15:11:47Z",
  "pasclaw_version": "v0.1.5",
  "workflow": {
    "id": "digest",
    "name": "digest",
    "description": "Summarise a page, then post it.",
    "inputs": [{"name": "url", "type": "string", "required": true}],
    "outputs": [{"name": "summary", "value": "{{nodes.sum}}", "type": "string"}],
    "nodes": [
      {"id": "fetch", "tool": "web_fetch", "args": {"url": "{{inputs.url}}"}},
      {"id": "sum", "tool": "llm", "args": {"prompt": "Summarise:\n{{nodes.fetch}}"}},
      {"id": "post", "tool": "slack__post_message", "args": {"text": "{{nodes.sum}}"}}
    ],
    "edges": []
  },
  "requires": {
    "mcp_servers": [{"name": "slack", "command": "npx", "args": ["-y", "@example/slack-mcp"],
                     "env": ["SLACK_BOT_TOKEN"]}],
    "providers": [{"name": "anthropic", "kind": "anthropic", "models": ["claude-opus-4-7"]}],
    "tools": ["web_fetch"],
    "replicate_models": []
  }
}
```

- **`workflow`** is the spec exactly as PasClaw saves it, editor layout
  included: importing it gives back the same workflow.
- **`requires`** is what the workflow needs from the machine that runs it:
  the MCP servers its steps call, with the command and args (stdio) or URL
  (HTTP) the author used, so you can add them; the providers and models its
  `llm` steps name (an empty name is the default provider); the built-in
  tools it calls; the Replicate models its steps run.
- **No secrets.** No provider key, gateway token, MCP env *value*, HTTP
  header or token is ever written: `env` lists only the variable names a
  server is configured with, and an HTTP server's auth header is left out.

**Export** it with `pasclaw workflow export <id> --lang workflow`
(`--format json` is the same), `GET /v1/workflows/<id>/export?lang=workflow`,
or **Export › Workflow file (.json)** in the editor.

**Import** it:

```
$ pasclaw workflow import digest.pasclaw-workflow.json
✓ imported digest -- staged for approval; it does not run until approved. Read it: pasclaw workflow show digest   Approve: pasclaw workflow approve digest
Missing on this machine (the workflow will fail at these steps until added):
  - MCP server "slack" is not configured here (the author ran: npx -y @example/slack-mcp)
```

or `POST /v1/workflows/import` with the file as the body, or **Import** in
the Workflow tab's list header (pick a file or paste it).

- **It is staged, not saved.** An imported workflow can run shell, file and
  MCP tools, so it waits for approval exactly like a workflow the agent
  saves (see [Approval](#approval)): it is listed first under **Waiting for
  your approval** with every step and its arguments, it is not a tool and
  does not run until you **Approve** it. `pasclaw workflow import --approve`
  saves it at once; that is for your own terminal, and the route has no
  such option.
- **The file is checked**: `format` must be `pasclaw-workflow`, `version` one
  this PasClaw reads (1), and `workflow` a spec that parses and is valid.
  Anything else is refused with what is wrong, and nothing is staged.
- **An id that is taken** (a saved workflow or one already waiting) is
  refused unless you give another (`--as <new-id>`, `?as=`) or replace it
  (`--replace`, `?replace=1`; the saved one keeps running until you approve
  the replacement). The web UI offers **Rename**, **Replace** and **Cancel**.
- **What is missing is reported, not refused**: MCP servers this machine has
  not configured (with how the author ran them), providers it lacks, built-in
  tools that are not registered. The import answer lists them, and so does
  each staged row in the approvals list (`missing` in
  `GET /v1/workflows/pending`).
- **From a URL**: `pasclaw workflow import https://…` fetches http(s) only,
  through PasClaw's SSRF guard (private, loopback and link-local addresses
  are refused, on every redirect too), at most 1 MB.

## Routes and commands

| | |
|---|---|
| `GET /v1/workflows` | Saved workflows. |
| `POST /v1/workflows`, `PUT /v1/workflows/<id>` | Save (yours; not staged). |
| `POST /v1/workflows/<id>/run` | Run one; the body is the inputs. Steps meet the rules; `ask` is refused. Answers each step's result, and `outputs` (name to value) when the workflow declares outputs. |
| `GET /v1/workflows/pending` | Staged workflows: `id`, `name`, `description`, `nodes`, `replaces`, `sha256`, `spec`. |
| `POST /v1/workflows/pending/approve` | `{"id", "sha256"?}` |
| `POST /v1/workflows/pending/reject` | `{"id"}` |
| `GET /v1/workflows/<id>/export?lang=python\|pascal\|workflow` | The workflow as a Python script, an Object Pascal program or the portable workflow file, as a download. 404 for an unknown id, 400 for an unknown language. |
| `POST /v1/workflows/import[?as=<id>][&replace=1]` | Import a workflow file (the body): staged for approval. 409 with `clash` when the id is taken; 400 for a bad file. Answers `id`, `sha256`, `replaces`, `missing`. |
| `pasclaw workflow list` | Saved workflows and the tool each is served as. |
| `pasclaw workflow pending` / `show <id>` / `approve <id> [--sha256 <hex>]` / `reject <id>` | As above. |
| `pasclaw workflow run <id> [--input NAME=VALUE ...] [--json] [--no-files]` | Run a saved workflow from the command line, through the same gates. |
| `pasclaw workflow export <id> --lang python\|pascal\|workflow [-o FILE]` | [Export as code](#export-as-code), or the [workflow file](#sharing-workflows). |
| `pasclaw workflow import <file\|url> [--as <id>] [--replace] [--approve]` | [Import a workflow file](#sharing-workflows): staged unless `--approve`. |

The `/v1/workflows` routes answer only when `workflows_enabled` is on, which
is the default.
