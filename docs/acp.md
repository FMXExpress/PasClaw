# Editors: the Agent Client Protocol

`pasclaw acp` runs PasClaw as an [Agent Client Protocol](https://agentclientprotocol.com) (ACP) agent. ACP is how an editor such as Zed or a JetBrains IDE drives a coding agent it did not build. The editor starts the agent as a child process and talks JSON-RPC over its stdin and stdout. It shows the reply, each tool call with its diff, permission prompts and the plan in its own UI.

`pasclaw acp` uses PasClaw's normal agent loop: the same tools, `permissions` rules, sessions, modes, MCP servers and provider configuration as `pasclaw agent`. What changes is who drives it.

```sh
pasclaw acp [--model M] [--provider P] [--mode build|plan|improve|space]
            [--max-iterations N] [--system S] [--thinking low|medium|high]
            [--no-mcp] [--profile P] [--backend local|docker]
```

The flags mean what they mean for `pasclaw agent`. One default differs: `--max-iterations` is 50 rather than 8, because an editor turn is a working session, not a one-shot.

## Set it up in an editor

**Zed.** In `settings.json` (Agent settings → External Agents → *Add Custom Agent* opens it):

```json
"agent_servers": {
  "PasClaw": {
    "type": "custom",
    "command": "/usr/local/bin/pasclaw",
    "args": ["acp"],
    "env": {}
  }
}
```

Start a thread with PasClaw from the agent panel's new-thread menu. `dev: open acp logs` in the command palette shows the messages going each way.

**JetBrains IDEs.** In `~/.jetbrains/acp.json` (AI Chat → *Add Custom Agent* creates it):

```json
{
  "agent_servers": {
    "PasClaw": { "command": "/usr/local/bin/pasclaw", "args": ["acp"], "env": {} }
  }
}
```

Any other ACP client works the same way: the command is `pasclaw`, the argument is `acp`. Give the full path to the binary. PasClaw reads its configuration from `$PASCLAW_HOME`, as it does everywhere else; set `PASCLAW_HOME` in `env` to point an editor at a different home.

## What the editor sees

| PasClaw | ACP |
|---|---|
| the model's text, as it is written | `agent_message_chunk`, piece by piece (see *Streaming*) |
| the model's thinking, as it is written | `agent_thought_chunk`, piece by piece |
| a tool call | `tool_call`: a kind (read, edit, execute, search, fetch, …), a title such as `Read src/a.pas` or the command itself, the file it names as a location, and the raw arguments |
| its result | `tool_call_update`: completed or failed, with the output |
| a file an edit tool rewrote (`write_file`, `edit_file`, `append_file`) | a diff in that update, before and after |
| `todo_write`'s checklist | `plan` (`- [x]` completed, `- [~]` in progress, `- [ ]` pending) |
| a `permissions` rule with `"effect":"ask"` | `session/request_permission`, with *Allow once*, *Allow for this session* and *Deny* |
| a held-out verification report, or the iteration limit | a closing message, and `stopReason` `max_turn_requests` for the limit |
| a provider that cannot answer (a bad key, a rate limit, no connection) | the prompt's JSON-RPC error, with the provider's message |
| modes | session modes `build`, `plan`, `improve`, `space`, switched with `session/set_mode` from the next turn |

**Streaming.** With Anthropic or an OpenAI-compatible provider (OpenAI, OpenRouter, Groq, DeepSeek, Mistral, Ollama, LM Studio, vLLM and the rest of the catalog's `openai` kind), the reply streams: each piece of text reaches the editor as the model writes it. An OpenAI-compatible server that refuses the streaming fields is asked again without them, and its reply arrives whole. The model's thinking streams too, as `agent_thought_chunk`, which an editor shows apart from the reply: Anthropic's thinking blocks (turn them on with `--thinking low|medium|high`), and the `reasoning_content` or `reasoning` a compatible server sends for a reasoning model. Thinking is shown, not saved: the session keeps the reply, as without streaming. A `pause_turn` from Anthropic's server tools is continued within the same turn. Gemini and the relay provider send each model round's text whole. A retry or a fallback after a failed call is not streamed either.

**Prompts.** Text is passed as written. A file the user attaches as a link becomes a reference (`@name (uri)`). Embedded file contents become a `<context uri="…">` block. Images and audio are not accepted yet: the agent advertises text only, and anything else is named in the prompt as left out.

**Paths.** The editor's `cwd` is the session's project. Tools resolve relative paths there, the shell runs there, and the system prompt is built for it: its workspace section, the project's `AGENTS.md` and its instruction files. PasClaw's own workspace still holds its memory and sessions.

**Permissions.** What asks is decided by the `permissions` rules in `config.json`, exactly as on every other surface ([Security → Permissions](./security.md#permissions-ordered-rules)). With no rules, nothing asks. To be asked before every shell command and every write:

```json
"permissions": [
  { "tool": "shell_exec",  "effect": "ask" },
  { "tool": "write_file",  "effect": "ask" },
  { "tool": "edit_file",   "effect": "ask" },
  { "tool": "apply_patch", "effect": "ask" }
]
```

*Allow for this session* is remembered for that session only. Anything but a selected allow counts as a no: a reject, a cancelled prompt, or an answer the agent did not offer. So does no answer within `permissions_ask_timeout_sec` (five minutes by default), the limit asks have on every surface. The editor is then sent `$/cancel_request` so it can close the prompt.

**Cancel.** The stop button sends `session/cancel`. The loop stops at its next safe point: before the next model call, or after the running batch of tools has finished. A model call already in flight completes first. The turn answers `stopReason: "cancelled"`, and what it did so far is kept in the session. A permission prompt still open when you cancel is answered as a no, and a tool call the turn announced but did not finish is shown as failed.

**Sessions.** Each ACP session is a normal PasClaw session, saved after every turn to `workspace/sessions/<id>.json`. An editor that reopens a thread sends `session/load`, and the conversation is replayed to it: prompts, replies, tool calls and their results. The same session can be resumed in a terminal with `pasclaw resume <id>`, which works in the editor's project. A turn the provider could not answer is not saved as a reply.

A session keeps the profile it was created under, as it does for `pasclaw agent --session`. The agent has one configuration for all its sessions, so `session/load` of a session made under another profile is refused, and the error names the command that opens it, such as `pasclaw acp --profile security`. With `--profile` or `$PASCLAW_PROFILE` set, the agent's profile is used.

**Modes.** `session/set_mode` takes effect from the next turn: the permission gate and the system prompt both change, including in a session that has run turns already.

**MCP servers.** Servers configured in PasClaw are connected as usual. Servers the editor passes in `session/new` are connected too, once per name per process, unless `--no-mcp` is set. Like configured servers, they are in code mode unless `mcp_codemode_default` is off: the model lists their tools with `code_catalog` and calls them from scripts. Only stdio servers are accepted (`mcpCapabilities` advertises no HTTP or SSE). A server's `env` list is not passed on yet: it starts with the agent's own environment, and a warning is logged.

**The docker shell backend.** With `--backend docker` (or `shell_backend` set to docker), each session's shell commands run in that session's own container, and sessions run their turns side by side. A background job a turn starts (`spawn_background`, `shell_background`) keeps working in that session's container and the editor's project after the turn has answered. The container lives until the agent exits, and a session the editor reloads keeps it. The container mounts PasClaw's workspace and, when the editor's project is outside it, the project too, both at the same path. Reopening a session in a different project restarts its container with that project. On Windows only the workspace is mounted (a container cannot hold a `C:\` path at the same path), so for a project outside it use the local backend.

## Not supported yet

- Images and audio in prompts.
- HTTP and SSE MCP servers from the editor, and per-server environment variables.
- The editor's file system and terminals (`fs/*`, `terminal/*`). PasClaw reads files from disk and runs commands itself, so unsaved editor buffers are not seen.
- Token-by-token text from Gemini and the relay provider. Their text arrives once per model round.
- Authentication methods. Provider keys come from PasClaw's own configuration.

## Logs and tests

Everything for a person goes to stderr; stdout carries ACP messages and nothing else. The startup banner is suppressed for `acp`, as it is for `mcp stdio`.

- `make test-acp` pins the protocol layer (`PasClaw.ACP`) with a scripted host: ids, errors, a turn, an ask, cancel, load replay, calls left open at the end of a turn, and output cut for display staying valid UTF-8.
- `make test-acp-e2e` drives the real binary over stdio against a fake OpenAI-compatible model. It covers a plan, a diff, an allowed and a denied ask, plan and improve mode reaching the system prompt, the project's `AGENTS.md`, a provider failure, cancel, an editor-supplied MCP server, load in a fresh process, profiles, `--max-iterations`, the docker backend and a background subagent that outlives its turn (through a fake `docker` CLI), and stdout carrying only JSON-RPC.
