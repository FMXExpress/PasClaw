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

The gateway can be locked down for exposed MCP:

```sh
pasclaw gateway --mcp-allow fs_read,fs_list,memory_search    # only these tools advertised
pasclaw gateway --mcp-read-only                               # refuse mutating tools (fs_write, shell_exec, ...)
pasclaw gateway --mcp-only --mcp-port 9090                    # second listener: MCP-only routes
```

`--mcp-only` spins a second `TGatewayServer` instance on the named port that honours only the MCP routes plus `/v1/health`. Use to isolate MCP traffic from the human-facing routes.

## See also

- [Tools](./tools.md) for the tools the model sees, including MCP-bridged.
- [Commands](./commands.md#mcp) for the full `pasclaw mcp` flag set.
- [Gateway](./gateway.md) for the route table.
