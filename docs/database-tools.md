# Database tools (Phase 1)

PasClaw can query and (when permitted) modify SQL databases through a small set
of agent tools, modelled on the TMS FireDAC MCP server's safety design but built
to compile on **both** toolchains:

- **Delphi:** FireDAC (`TFDConnection`), `DriverName` picked from config.
- **FPC:** sqldb's `TSQLConnector`, connector type picked from config.

The same binary reaches SQLite, PostgreSQL, MySQL/MariaDB, Firebird, MSSQL,
Oracle and ODBC once the matching driver/connector is linked. **Phase 1 links
and tests SQLite on both toolchains;** the other engines are recognised by the
driver mapping but need their connector unit linked (Phase 2).

## Tools

| Tool | Category | Purpose |
|------|----------|---------|
| `db_info` | read-only | driver, access mode, row cap, **password-redacted** connection string |
| `db_tables` | read-only | list tables/views |
| `db_describe` | read-only | columns of a table: name, type, size, nullable |
| `db_query` | read-only | run ONE read statement (`SELECT`/`WITH`/`EXPLAIN`) with `:name` params |
| `db_execute` | mutating | run ONE write (`INSERT`/`UPDATE`/`DELETE`; DDL in `full` mode) |

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

## Configuration (Phase 2 wires this at each entry point)

The engine reads a `database` array. Each entry:

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

Fields: `name`, `driver` (`sqlite|postgres|mysql|mssql|firebird|oracle|odbc`),
`database`, `server`, `port`, `user`, `password`, `params`, `mode`, `max_rows`,
`timeout_ms`. `PasClaw.Tools.DB.SetDBConfigFromJSON` parses this section; until a
connection is installed the tools are registered but inert.

## Roadmap

- **Phase 2** — link Postgres/MySQL/ODBC connectors + FireDAC driver links; wire
  the `database` config section at each entry point.
- **Phase 3** — project the native tools out through PasClaw's MCP server, so
  PasClaw itself is a cross-platform database MCP server.
- **Phase 4** — a DeepSQL-style "DBA" layer: schema/stat indexing into the KB,
  a plain-English business glossary in memory facts, and a cron+workflow that
  ranks slow queries and proposes indexes.
