# MCP servers

PasClaw is both an **MCP client** (configured MCP servers expose tools to the model) and an **MCP server** (`/mcp` and `/v1/mcp/rpc` on the gateway, plus `pasclaw mcp stdio`).

Both transports supported on the client side:

- **Stdio MCP** — spawned subprocess + JSON-RPC over pipes. Format `pasclaw mcp add foo npx -y @org/server-foo arg1 arg2`.
- **Streamable HTTP MCP** — handles SSE-framed responses, Bearer-token auth. Format `pasclaw mcp add bar https://example.com/mcp`.

A command starting with `http://` or `https://` is dispatched to the HTTP client; everything else is spawned.

## Commands

```sh
pasclaw mcp list
pasclaw mcp add filesystem npx -y @modelcontextprotocol/server-filesystem /tmp
pasclaw mcp add remote https://example.com/mcp
pasclaw mcp show filesystem
pasclaw mcp test filesystem          # round-trip an initialize + list_tools
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

`env` is `KEY=VALUE` pairs separated by `;`. For the HTTP transport, `Authorization` is read here and written as a request header on every call.

## Tool bridging

Every tool a configured (and enabled) MCP server exports becomes available to the model on every turn, prefixed by the server name so collisions don't shadow each other. For an MCP server named `filesystem` that exports a `read_file` tool, the model sees `filesystem.read_file`.

## Code Mode

By default an MCP server's tools are **not sent to the model as tool schemas at all** (`mcp_servers[].codemode`, default from `mcp_codemode_default: true`). The model calls them from an `execute_code` script, where a one-line `tool` function wraps the tool RPC:

```sh
tool --catalog github                                     # names, descriptions, argument schemas
tool github__list_issues '{"repo":"FMXExpress/PasClaw","state":"open"}' \
  | jq -r '.[] | select(.title | test("crash")) | .number' \
  | while read n; do tool github__get_issue "{\"number\":$n}" | jq .body; done
```

Why: a chain of MCP calls becomes one tool round, and the intermediate results never enter the conversation. That is the cost win OpenCode 2.0 ships under the same name, without a second runtime: the script is still bash or PowerShell. The system prompt lists each code-mode server with its tool count and the recipe above; `code_catalog(server?)` returns the same catalog without a script; `tool_search` tells the model when it asks for a code-mode tool the classic way.

A script's calls go through the same dispatch gates as direct tool calls (plan mode refuses mutating MCP tools from a script too, hooks see them, output is capped). With the Docker shell backend the `pasclaw` binary is bind-mounted read-only into the container so `tool` works there.

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
