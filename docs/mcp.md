# MCP servers

PasClaw is both an **MCP client** (configured MCP servers expose tools to the model) and an **MCP server** (`/mcp` and `/v1/mcp/rpc` on the gateway, plus `pasclaw mcp stdio`).

Both transports supported on the client side:

- **Stdio MCP** — spawned subprocess + JSON-RPC over pipes. Format `pasclaw mcp add foo npx -y @org/server-foo arg1 arg2`.
- **Streamable HTTP MCP** — handles SSE-framed responses, Bearer-token auth. Format `pasclaw mcp add bar https://example.com/mcp`.

Both speak MCP 2026-07-28 and fall back to the `initialize` handshake for older servers; see [Protocol versions](#protocol-versions).

A command starting with `http://` or `https://` is dispatched to the HTTP client; everything else is spawned.

## Commands

```sh
pasclaw mcp list
pasclaw mcp add filesystem npx -y @modelcontextprotocol/server-filesystem /tmp
pasclaw mcp add remote https://example.com/mcp
pasclaw mcp show filesystem
pasclaw mcp test filesystem          # negotiate the protocol version + list_tools
pasclaw mcp remove filesystem
pasclaw mcp edit                     # open mcp_servers in $EDITOR
pasclaw mcp catalog                  # list curated public MCP servers
pasclaw mcp search <query>           # search the pasclaw.dev hub
pasclaw mcp install <slug>           # install from hub OR bundled catalog
```

## Storage

```json
"mcp_servers": [
  { "name": "filesystem",
    "cmd":  "npx",
    "args": "-y @modelcontextprotocol/server-filesystem /tmp",
    "env":  "",
    "enabled": true },
  { "name": "remote",
    "cmd":  "https://example.com/mcp",
    "args": "",
    "env":  "Authorization=Bearer abc123",
    "enabled": true }
]
```

`env` is `KEY=VALUE` pairs separated by `;`. For a command, the variables are added to the environment the server is started with (they win over the gateway's own). For the HTTP transport, `args` holds the Authorization header `pasclaw mcp install` writes; when `args` is empty, an `Authorization` variable here is sent as that header on every call. A `${VAR}` marker in a value is read from the gateway's environment when it starts, so a token need not be stored in `config.json` at all.

`GET /v1/config` masks each value on its own and keeps the names (`GITHUB_TOKEN=•••;DEBUG=•••`); a save that sends a masked value back keeps the saved value of the variable with that name, so a value can be set without ever being read.

## In the web UI

The **MCP** tab adds, edits and removes servers; **Settings › MCP servers** edits the same list as cards, with the same form. Both save `config.json` through `PUT /v1/config`.

- The form: name, transport (a command with its arguments, or a URL), environment variables as rows (values write-only), enabled, and tool exposure (follow `mcp_codemode_default`, Code Mode, or classic). It refuses a missing name, a name another server has (in any case), a name with anything but letters, digits, `-` and `_` (the name begins each tool's name), a missing command or URL, and a renamed server or variable whose saved value would be lost.
- **Start from the catalog** (Add only) lists the bundled catalog from `GET /v1/mcp/catalog` and fills the form; a token the entry needs becomes a `${VAR}` marker, for example `Authorization=Bearer ${HF_TOKEN}`.
- **Remove** asks first.

What a save applies at once, and what waits for a restart:

| Change | When |
| --- | --- |
| A server added, or turned on, that this gateway has not started | At once: it connects the way the boot does (cached tools first, the live connect on its own thread), and shows Connecting, then Ready |
| A running server's command, arguments, environment or code mode changed | At the next restart; until then it runs as it was started |
| A running server turned off or removed | At the next restart; until then it keeps running and its tools stay available |

Why: the bridge only ever adds. A running server's tools are registered in the tool registry, which has no way to take a tool back, and a chat may be in the middle of a call on its client, so stopping or replacing it under a running chat is not safe. The MCP tab marks such a server **Restart to apply**, `GET /v1/mcp` gives it `apply: "restart"`, and `PUT /v1/config` answers `"mcp": {"connected": [...], "restart": [...]}`, which Settings lists with the other restart-only changes. A gateway started with `--no-mcp` connects nothing, so every MCP change waits for a restart there.

## Protocol versions

The client speaks MCP **2026-07-28** (the stateless revision) and the handshake revisions before it, and works out which one each server speaks when it connects:

1. It sends `server/discover` declaring `2026-07-28` in `_meta`. A server that answers with `supportedVersions` containing `2026-07-28` is **modern**: there is no `initialize` and no session, and every request carries `_meta` with `io.modelcontextprotocol/protocolVersion`, `io.modelcontextprotocol/clientInfo` (`pasclaw` and its version) and `io.modelcontextprotocol/clientCapabilities`. A result without `resultType` counts as complete.
2. Anything else means a **legacy** server: an error (method not found, an HTTP 4xx whose body is not a modern MCP error), or no answer within 5 seconds (less when the connect budget is shorter). PasClaw then sends `initialize` offering **2025-11-25**, the newest handshake revision it speaks in full, and uses whatever version the server answers (2024-11-05, 2025-03-26, 2025-06-18 and 2025-11-25 servers all connect).
3. `UnsupportedProtocolVersionError` (-32022) means a modern server that does not speak 2026-07-28: `initialize` offers the newest revision from the error's `supported` list that PasClaw knows. With none in common the connect fails and says which versions the server supports.

A stdio server that exits when it gets a request before `initialize` is started again for the handshake. If the probe timed out and `initialize` then fails, the server is asked again, in case it was a modern server that was still starting.

The result is recorded per server and shown where server status is shown:

- `pasclaw mcp test <name>` prints `protocol: 2026-07-28 (stateless, via server/discover)` or `protocol: 2025-06-18 (handshake, via initialize (probe: ...))`.
- The gateway's `GET /v1/mcp` gives each connected server `state` (`connecting` / `ready` / `failed`), `protocol_version`, `negotiation`, `server_name`, `server_version` and, on failure, `error`. It lists `config.json` as saved, so a server added since the gateway started is there too, with `apply: "restart"` when the running gateway has not taken it up. The web UI's **MCP** tab shows the state and the version (hover for how it was settled).
- The live connect is logged: `mcp[name] live connect OK (12 tools, MCP 2026-07-28 via server/discover)`.

Over **Streamable HTTP** a modern request also carries `MCP-Protocol-Version: 2026-07-28`, `Mcp-Method`, and `Mcp-Name` (the tool name for `tools/call`, the `taskId` for `tasks/*`), with the `=?base64?...?=` form for values that are not plain ASCII. Arguments whose schema property has `x-mcp-header` are mirrored into `Mcp-Param-<Name>` headers; a tool whose `x-mcp-header` annotations break the spec's rules is left out of `tools/list` with a warning, and a `HeaderMismatch` error re-reads the tool list and retries once. No `Mcp-Session-Id` is sent. A legacy HTTP server gets the old shape: `Mcp-Session-Id` echoed back, and from 2025-06-18 on the negotiated `MCP-Protocol-Version`. Both eras send one `Accept: application/json, text/event-stream`, and an SSE reply's notifications are skipped to find the response to the request.

`tools/list` follows `nextCursor` pages. `ping` is never sent (2026-07-28 removed it). Sampling, roots and logging are deprecated in 2026-07-28 and are not offered.

## Elicitation (a server asking the user)

A server can ask the user to fill in a form (form mode) or to go to a URL (URL mode). On a modern server the request comes back from `tools/call` as `resultType: "input_required"` with `inputRequests`; PasClaw answers each one and calls the tool again with `inputResponses` and the server's `requestState` echoed unchanged, under a new request id, for at most 8 rounds. A legacy server sends its own `elicitation/create` request while the call is in flight (over stdio); a 2025-11-25 server's `URLElicitationRequiredError` (-32042) is handled too: the URLs are shown, and the call is retried once after the user is done.

Who answers depends on where the tool call came from:

| Context | Form mode | URL mode | Capability declared |
| --- | --- | --- | --- |
| `pasclaw agent` (interactive REPL) | one prompt per field, typed per the schema (text, integer, number, yes/no, a choice by value, title or number, a comma-separated multi-select), with defaults, required fields re-asked, then a review: send / edit / decline / cancel | the full URL and its host are shown, with a warning for a punycode host; PasClaw does not open or fetch it; the user opens it and answers done / decline / cancel | `form` and `url` |
| `pasclaw tui` (FPC line REPL) | the same | the same | `form` and `url` |
| `pasclaw tui` (Delphi full-screen TUI), gateway, web UI, `pasclaw agent -m` one-shot, subagents, ACP, workflows | declined | declined | none |

At a form prompt, Enter keeps the default or skips an optional field, and `/decline` or `/cancel` stops. Prompts are taken one at a time, like permission asks.

Where nobody can answer, no elicitation capability is declared, so a modern server should not ask; if it needs to, it answers `MissingRequiredClientCapability` and the model is told the tool needs an interactive session. If a server asks anyway, the request is declined, a modern call is not retried, and the tool result tells the model what was asked: the message and field names for a form, and for URL mode the URL itself, to hand to the user with a note to call the tool again once they have finished. A legacy server's `elicitation/create` is answered `decline` and the same note is added to the tool result.

Over HTTP, legacy elicitation is not supported: a legacy server sends `elicitation/create` inside the SSE response and waits for a separate POST, and PasClaw's HTTP layer reads a response whole, so it could not answer in time. PasClaw therefore declares no elicitation on legacy HTTP connections. Modern elicitation arrives in the result itself and works over HTTP as over stdio.

Frontends set the handler through `TToolLoopConfig.Elicitor` (a `TMCPElicitationHandler` from `PasClaw.MCP.Elicit`), which the tool loop publishes on whichever thread dispatches the call. `SetMCPProcessElicitationHandler` decides what a legacy `initialize` declares, since that handshake happens once, before any tool loop.

## Tasks

PasClaw declares the tasks extension (`io.modelcontextprotocol/tasks`) on every modern request. When `tools/call` returns a task handle (`resultType: "task"`) instead of a result, PasClaw polls `tasks/get` at the server's `pollIntervalMs` (default 1 s, kept between 10 ms and 30 s) until the task is `completed` (its `result` is the tool result), `failed` (its error is the tool error) or `cancelled`. Polling stays within the tool call's timeout (30 s on stdio, 60 s on HTTP) and the task's `ttlMs`; a task still running when the time is up is cancelled with `tasks/cancel` and the model is told so. When a task asks for input (`input_required`), each new `inputRequests` key goes through the elicitation handler above and the answers go back with `tasks/update`; keys already answered are not asked again. Where nobody can answer, the task is told `decline` (so it is not left waiting) and the note is added to the result.

## Authorization (OAuth)

`pasclaw mcp auth <name>` runs OAuth 2.1 with PKCE against the authorization server the MCP server names. Following MCP 2026-07-28:

- **Issuer check (RFC 9207).** The issuer from the authorization server's metadata is recorded with the state and PKCE verifier. A redirect that carries `iss` must name that issuer exactly (no case folding, port or trailing-slash normalisation), or it is refused before the code is used, and its error text is neither shown nor acted on. When the metadata says `authorization_response_iss_parameter_supported`, a redirect without `iss` is refused too.
- **Client ID Metadata Documents.** When the authorization server advertises `client_id_metadata_document_supported` and `mcp_oauth_client_metadata_url` is set, that HTTPS URL is the `client_id` and nothing is registered. PasClaw hosts no such document, so the key has no default; the document you host must list `http://127.0.0.1/cb` in `redirect_uris` (PasClaw listens on a free loopback port, and authorization servers accept any port on a loopback redirect).
- **Dynamic Client Registration** (deprecated in 2026-07-28, used when CIMD is not available) registers a public client with `application_type: "native"`, so an OpenID Connect server does not apply web-app redirect rules to the loopback redirect.
- **Credentials bound to the issuer.** The registration is stored in `<home>/oauth/<name>.json` with the issuer that made it and its redirect URI. The next `mcp auth` reuses it only with the same issuer, listening on the same redirect port again; if the protected resource now names another authorization server, the old client is not used and a new one is registered. A refresh is refused when the stored client belongs to a different issuer than the tokens. A reused registration the server rejects (`invalid_client`) is dropped, so the next run registers afresh.

## Skills over MCP

Not implemented. A written specification exists (SEP-2640, `io.modelcontextprotocol/skills`: `skills/list`, `skills/get`, skill files through `resources/read`), but its full text is still labelled beta in the ext-skills repository, and it asks the host for a loading path with per-skill approval, digest and size checks against a manifest, and an origin-tagged cache. PasClaw's MCP client reads no resources today, so this is left for a separate change.

## Tool bridging

Every tool a configured (and enabled) MCP server exports becomes available to the model on every turn, prefixed by the server name so collisions don't shadow each other. For an MCP server named `filesystem` that exports a `read_file` tool, the model sees `filesystem.read_file`.

At startup the tools come from the list each server sent last time (`$PASCLAW_HOME/mcp-cache/<server>.json`), so the model has them on its first turn while the servers connect in the background. A call to a server that is still connecting waits for the connect to finish (at most its 30 s connect timeout) and then runs; if the connect failed, the call reports why.

### Built-in long tail

The same lazy reveal applies to PasClaw's own tools (`builtin_progressive_disclosure`, default on). Tool schemas are re-sent on every request and dominate its size, so the families a turn rarely reaches for are withheld behind `tool_search` and listed by name in a "Deferred Tools" prompt section: `db_*`, `workflow_*`, `spawn*`, `session_*`, plus `desktop` (see below). The set is one predicate (`ToolIsLongTail` in `PasClaw.Tools.Types`) read both by the registration sweep and by the registry latch, so a tool registered later is deferred the same way. `memory_write`, `shell_background` and `memory_fetch` were tried in the set and stay visible. A hidden tool is one the model stops choosing, not one it searches for: without `shell_background` it runs a build in `shell_exec` and blocks on it, and nothing ever says the background path existed. Rule 5 of the prompt also recommends `memory_write`. Measured on a six-turn build task with identical model decisions (`bench/ragbench/README.md`): 18 of 36 schemas visible, 150,160 request bytes against 156,142 with `desktop` visible and 228,634 under the old `--no-mcp`. A deferred tool costs one extra `tool_search` turn the first time it is needed; calling one directly without searching still works.

`desktop` is the one exception that tracks what is running. It does nothing without a desktop, so it is deferred for API callers, channels and plain chats. A desktop (the browser `/desktop` or the native app) needs it from its first turn, because the shell routes every screen request ("tile the windows") through it. Both desktops subscribe to `/v1/desktop/events`, and the gateway reveals `desktop` the moment one connects, so the model never spends a search turn finding it. Like any reveal, it is registry-wide and lasts until the gateway stops.

`--no-mcp` keeps this: `pasclaw agent`, the gateway, serve and the TUI register `tool_search` and the deferral even when MCP is off (the last three used to skip both, so every request carried all 36 schemas). With MCP off, the built-in long tail is the only reason for `tool_search`, so it is registered only when `builtin_progressive_disclosure` is on, whatever `mcp_progressive_disclosure` says. It also never mentions MCP servers: one listed in config does not start under `--no-mcp`, so a search that finds nothing says MCP is off rather than that the server is still connecting.

## Code Mode

By default an MCP server's tools are **not sent to the model as tool schemas at all** (`mcp_servers[].codemode`, default from `mcp_codemode_default: true`). The model calls them from an `execute_code` script, where a one-line `tool` function wraps the tool RPC:

```sh
tool --catalog github                                     # names, descriptions, argument schemas
tool github__list_issues '{"repo":"FMXExpress/PasClaw","state":"open"}' \
  | jq -r '.[] | select(.title | test("crash")) | .number' \
  | while read n; do tool github__get_issue "{\"number\":$n}" | jq .body; done
```

Why: a chain of MCP calls becomes one tool round, and the intermediate results never enter the conversation. That is the cost win OpenCode 2.0 ships under the same name, without a second runtime: the script is still bash or PowerShell. The system prompt lists each code-mode server with its tool count and the recipe above; `code_catalog(server?)` returns the same catalog without a script; `tool_search` tells the model when it asks for a code-mode tool the classic way.

A script's calls go through the same dispatch gates as direct tool calls (plan mode refuses mutating MCP tools from a script too, hooks see them, output is capped).

With the Docker shell backend, `tool` needs two things to reach back out of the container: the `pasclaw` binary (bind-mounted read-only at the same path) and a route to the parent's RPC listener. A container on a bridge network has its own loopback, so the listener moves to the host's docker-bridge gateway and the container gets `host.docker.internal` mapped to the host (`--add-host`, which needs Docker >= 20.10); the discovery file in the mounted `run/` directory names the address to dial, and the per-call random token still authorises every request. With `"network": "host"` nothing moves — the namespace is shared. With `"network": "none"` there is no route at all, so `tool` cannot work and a code-mode server is unreachable from a script; PasClaw logs that at container start.

A subagent inherits a code-mode tool **as code mode**: its registry can dispatch the tool from a script, and the schema stays out of the child's prompt exactly as it is out of the parent's.

`"codemode": false` on a server exposes its tools the classic way: deferred behind `tool_search` when progressive disclosure is on, in the provider's tool list otherwise. `"mcp_codemode_default": false` makes classic the default for every server that does not say otherwise.

## `pasclaw mcp catalog` (built-in + hub)

`pasclaw mcp catalog` queries the pasclaw.dev MCP registry (`GET /api/public/v1/mcp`) with a 5-second timeout and falls back to the bundled 5-entry list when the hub is unreachable. Source attribution (`hub` / `built-in`) is shown in the output.

### Bundled built-in catalog

| name | env var | provider |
|---|---|---|
| `replicate` | `REPLICATE_API_TOKEN` | Run AI models (text/image/video/audio) on Replicate — 5000+ models. |
| `digitalocean-apps` | `DIGITALOCEAN_TOKEN` | Manage DigitalOcean App Platform. |
| `digitalocean-databases` | `DIGITALOCEAN_TOKEN` | Manage DigitalOcean Managed Databases. |
| `runpod-docs` | _(none)_ | Search RunPod documentation. |
| `huggingface` | `HF_TOKEN` | Search models / datasets / papers / Spaces. |

`pasclaw mcp search <query>` hits the hub directly with no fallback — the bundled list is too small to search.

The gateway serves the bundled list (never the hub) at `GET /v1/mcp/catalog` for the web UI's **Start from the catalog**.

`pasclaw mcp install <slug>` tries the hub first so any registered server is installable, falls back to the bundled catalog when the hub doesn't have it. Auth is read from the env var the catalog entry names; installing with the env unset writes an empty Authorization header and a hint to re-run after setting it.

## `pasclaw mcp stdio` (server mode)

Run PasClaw as an MCP server for other agents to call:

```sh
pasclaw mcp stdio
```

Other agents (Claude Code, Cursor, etc.) can declare this in their MCP config and call PasClaw's tools — `fs_*`, `shell_exec`, `memory_search`, `kb_search`, etc. — through standard MCP.

**Important**: stdio MCP must keep stdout clean JSON-RPC. PasClaw's `IsStdioMCPInvocation` check in `PasClaw.dpr` automatically suppresses the banner and routes all logging to stderr when the binary is invoked as `pasclaw mcp stdio`. Same goes for the legacy `__tool` subprocess RPC.

## HTTP MCP endpoint

When running `pasclaw gateway`, an MCP-over-HTTP endpoint is mounted at `/mcp` and `/v1/mcp/rpc`. Other agents can call PasClaw's tools over HTTP:

```sh
curl http://127.0.0.1:8088/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
```

Each saved [workflow](./workflows.md) is served here as its own tool, `wf_<id>`, with the workflow's inputs as its schema — read-only when every step is, so a workflow that writes needs `--mcp-allow-write` like any other mutating tool. A workflow saved or approved while the gateway runs is in the next `tools/list`. Its steps meet the gateway's permission rules; an `ask` rule is refused, there being no operator on an MCP call to ask.

### Allowlist + read-only mode

The gateway can be locked down for exposed MCP. By default the inbound MCP server refuses mutating tools (`fs_write`, `fs_edit_hashline`, `shell_exec`, `execute_code`, `memory_write`); `--mcp-allow-write` opts in to them. There is no per-tool allowlist flag — the allowlist is the read-only / read-write split.

`memory_write` is the one worth thinking about separately. `memory_search` has always let another agent **read** PasClaw's memory; `memory_write` lets it **contribute**, so a decision recorded in Cursor is in context the next time PasClaw runs. Each written fact stores its declared origin (`written:<source>`) for audit. That origin is a label, not an authentication — a client can claim any value — so treat an exposed writable MCP surface as trusted-caller-only.

```sh
pasclaw gateway --mcp-port 9090                       # spawn a second MCP-only listener on port 9090
pasclaw gateway --mcp-port 9090 --mcp-allow-write     # second listener with mutating tools enabled
```

`--mcp-port <p>` spawns a second `TGatewayServer` instance on the named port that honours only the MCP routes (`/mcp`, `/v1/mcp/rpc`) plus `/v1/health`. The main gateway port keeps the full route table. Use the second listener to isolate MCP traffic from the human-facing routes (different firewall rules, different network).

## See also

- [Tools](./tools.md) for the tools the model sees, including MCP-bridged.
- [Commands](./commands.md#mcp) for the full `pasclaw mcp` flag set.
- [Gateway](./gateway.md) for the route table.
