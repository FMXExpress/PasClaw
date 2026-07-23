# Database tools (Phase 1)

PasClaw can query and (when permitted) modify SQL databases through a small set
of agent tools, modelled on the TMS FireDAC MCP server's safety design but built
to compile on **both** toolchains:

- **Delphi:** FireDAC (`TFDConnection`), `DriverName` picked from config.
- **FPC:** sqldb's `TSQLConnector`, connector type picked from config.

The same binary reaches SQLite, PostgreSQL, MySQL/MariaDB, Firebird, MSSQL,
Oracle and ODBC. The client library for a given engine (libpq, libmysqlclient,
libfbclient, FreeTDS, Oracle OCI, unixODBC) is loaded **lazily at connect time**,
so one portable binary ships every engine and a missing library only fails that
one connection — it doesn't break the build or the other engines.

- **FPC:** all connector units are linked by default (SQLite, PostgreSQL,
  MySQL 5.7/8.0, Firebird/Interbase, MSSQL, Oracle, ODBC).
- **Delphi:** SQLite is linked in every RAD Studio edition. The other FireDAC
  drivers need Enterprise/Architect — build with `-dPASCLAW_FIREDAC_FULL` to
  link them, so the default build stays portable across editions.

Canonical `driver` ids: `sqlite`, `postgres`, `mysql` (or `mysql8`, `mariadb`),
`mssql`, `firebird`, `oracle`, `odbc`.

## Tools

| Tool | Category | Purpose |
|------|----------|---------|
| `db_info` | read-only | driver, access mode, row cap, **password-redacted** connection string |
| `db_tables` | read-only | list tables/views |
| `db_describe` | read-only | columns of a table: name, type, size, nullable |
| `db_query` | read-only | run ONE read statement (`SELECT`/`WITH`/`EXPLAIN`) with `:name` params |
| `db_execute` | mutating | run ONE write (`INSERT`/`UPDATE`/`DELETE`; DDL in `full` mode) |
| `db_schema` | read-only | schema digest: every table with columns + row counts (grounding for NL→SQL) |
| `db_explain` | read-only | plan a query (without running it) + flag full table scans + index hint |

All tools take an optional `connection` argument to select a named connection;
omit it for the first (default) one.

## Safety model

- **Capability by mode.** Each connection has a mode: `readonly` (default),
  `readwrite`, or `full`. `db_execute` is refused on a `readonly` connection;
  DDL/administrative statements require `full`. Gating is per-connection and
  enforced at call time.
- **Classification after stripping.** SQL is classified only after comments and
  string literals are removed, so a keyword hidden inside `/* ... */` or a
  quoted string can't smuggle a write past `db_query`.
- **No statement stacking.** A second statement after `;` is rejected.
- **Parameter binding.** Values bind to `:name` placeholders (typed from the
  JSON value), never string-concatenated.
- **Bounded results.** Rows are capped at the connection's `max_rows`; a
  `truncated` flag signals more exist. Oversized cells are truncated.
- **Secret hygiene.** `db_info` redacts the password; keep credentials out of
  the file with env substitution.

## Configuration

Add a `database` array to `config.json`. It's read at every entry point (CLI
agent, TUI, gateway, serve), kept verbatim across a config save/load, and parsed
by `PasClaw.Tools.DB.SetDBConfigFromJSON`; until a connection is installed the
tools are registered but inert.

```json
{
  "database": [
    {
      "name": "app",
      "driver": "sqlite",
      "database": "workspace/app.db",
      "mode": "readonly",
      "max_rows": 500
    }
  ]
}
```

Fields: `name`, `driver`, `database`, `server`, `port`, `user`, `password`,
`params`, `mode`, `max_rows`, `timeout_ms`. Keep credentials out of the file with
env substitution; `db_info` redacts the password on the way out.

## PasClaw as a database MCP server

With a `database` section configured, PasClaw projects the db tools out over MCP,
so any MCP host (Claude Desktop, Cursor, Codex CLI) can query your databases
through PasClaw:

- **stdio:** `pasclaw mcp stdio` exposes `db_query` / `db_tables` / `db_describe`
  / `db_info` (read-only). `--allow-write` additionally exposes `db_execute`
  (still refused on a `readonly` connection). Point a host's MCP config at
  `pasclaw mcp stdio` as the command.
- **HTTP:** the gateway's `POST /mcp` route exposes the same tools from its
  registry.

Two safety layers apply: the MCP server only advertises `tcReadOnly` tools
unless writes are allowed, and each tool still enforces the connection's mode.

## DBA layer

The `db_schema` / `db_explain` tools plus PasClaw's existing memory, KB, workflow
and cron machinery compose into a lightweight "always-on DBA" — the DeepSQL idea,
built from parts you already have:

- **Ground NL→SQL in the real schema.** `db_schema` returns each table's columns
  and row counts. Read it before writing queries; the agent can also persist the
  digest into the knowledgebase (`workspace/kb`) so `kb_search` recalls it.
- **Teach business rules in plain English.** Store definitions with the memory
  tools — "MRR = sum(amount) where status='active'", "a hotel is *active* when
  `deleted_at is null`" — and they persist across sessions and surface via
  `memory_search`, so later queries use your vocabulary.
- **Optimize slow queries.** `db_explain` plans a query without running it,
  flags full table scans in `full_scans`, and hints at an index. Apply the index
  (with `db_execute` on a `full`-mode connection), then re-run `db_explain` to
  confirm the plan switched to `SEARCH … USING INDEX`.
- **Automate it.** Wrap the loop in a saved workflow and put it on a cron: pull
  slow statements (e.g. Postgres `pg_stat_statements`) with `db_query`, run each
  through `db_explain`, and post the ranked findings + proposed indexes to a
  channel. For example:

  ```json
  {
    "name": "slow_query_audit",
    "inputs": [{ "name": "min_ms", "type": "number" }],
    "nodes": [
      { "id": "slow", "tool": "db_query", "args": {
          "sql": "SELECT query, mean_exec_time FROM pg_stat_statements WHERE mean_exec_time > :ms ORDER BY mean_exec_time DESC LIMIT 10",
          "params": { "ms": "{{inputs.min_ms}}" } } },
      { "id": "advise", "tool": "llm", "args": {
          "provider": "anthropic",
          "prompt": "For each slow query below, call db_explain and propose an index. {{nodes.slow}}" } }
    ]
  }
  ```

`db_schema` and `db_explain` are read-only, so they project over MCP too — an
external host gets schema grounding and query-plan analysis for free.

## Roadmap

- **Phase 1 (done)** — engine-agnostic seam + the five tools + safety model,
  SQLite backend on both toolchains.
- **Phase 2 (done)** — link all FPC connectors (+ the `PASCLAW_FIREDAC_FULL`
  define for Delphi); wire the `database` config section at each entry point.
- **Phase 3 (done)** — project the native tools out through PasClaw's MCP server
  (stdio + HTTP `/mcp`), so PasClaw itself is a cross-platform database MCP
  server.
- **Phase 4 (done)** — the DBA layer: `db_schema` (schema/stat digest) and
  `db_explain` (query-plan + full-scan/index advisor), composing with memory
  facts (business glossary) and workflow+cron (slow-query audit) as above.
