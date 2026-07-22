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

## Roadmap

- **Phase 1 (done)** — engine-agnostic seam + the five tools + safety model,
  SQLite backend on both toolchains.
- **Phase 2 (done)** — link all FPC connectors (+ the `PASCLAW_FIREDAC_FULL`
  define for Delphi); wire the `database` config section at each entry point.
- **Phase 3** — project the native tools out through PasClaw's MCP server, so
  PasClaw itself is a cross-platform database MCP server.
- **Phase 4** — a DeepSQL-style "DBA" layer: schema/stat indexing into the KB,
  a plain-English business glossary in memory facts, and a cron+workflow that
  ranks slow queries and proposes indexes.
