# Backup and restore

```sh
pasclaw backup                            # -> $PASCLAW_HOME/backups/pasclaw-<workspace>-YYYYMMDD-HHMMSS.zip
pasclaw backup --to /mnt/nas/pasclaw      # anywhere writable; a mount gets you off-machine copies
pasclaw backup list
pasclaw restore pasclaw-workspace-20261017-030000.zip
```

A backup that cannot be restored is a file. These can.

## What is in an archive

| entry | contents |
|---|---|
| `<workspace>/…` | the active workspace: memory (`MEMORY.md`, `USER.md`, `SOUL.md`, daily notes, `facts.db`), sessions, skills, the knowledge base, checkpoints, `AGENTS.md`, `PLAN.md` |
| `config.redacted.json` | `config.json` with every secret replaced by `•••`: `providers[].api_key`, `mcp_servers[].env`, `gateway.token`, `web_search.api_key`. Providers, models, channels, sandbox and memory settings are intact. The same masking the gateway's `GET /v1/config` uses, from the same function, so the two cannot disagree about what a secret is |
| `RESTORE.md` | what this is, which PasClaw wrote it, how many files, the exact restore command, and the list of secrets to re-enter |

Left out on purpose: the WebView2 browser profile under `workspace/browser/webview2` (hundreds of MB, machine-bound, and your logins), SQLite journals (`*-journal`, `*-wal`, `*-shm`, `kb.db-journal`), `.git`, and the sessions search index, which rebuilds itself.

The notes travel inside every archive so that a zip found on a disk two years from now explains itself without this page.

## Rotation

After a successful write the backup directory is rotated with the 7 / 4 / 6 shape, using borg's rule: the newest archive of each of the last `keep_daily` **days that have one**, of each of the last `keep_weekly` ISO weeks that have one, and of each of the last `keep_monthly` months that have one, are kept. Counting days-with-backups rather than calendar days means a machine that was off for a fortnight does not come back and delete its history. The newest archive is always kept. Only files this command named (`pasclaw-<workspace>-*.zip`) are ever deleted; anything else in the directory is left alone. A failed write never prunes.

```json
"backup": { "dir": "/mnt/nas/pasclaw", "keep_daily": 7, "keep_weekly": 4, "keep_monthly": 6 }
```

The `--keep-*` flags override for one run.

## Restore

```sh
pasclaw restore <zip>                 # under $PASCLAW_HOME; refuses if the workspace exists
pasclaw restore <zip> --into DIR      # somewhere else, e.g. to inspect
pasclaw restore <zip> --force         # overlay an existing workspace; files not in the archive are kept
```

Members are validated against the destination before extraction (no absolute paths, no `..`), then the workspace directory is copied into place. `config.json` is **never** written: the redacted copy lands as `config.redacted.json` beside the workspace, the notes as `RESTORE-<workspace>.md`, and the command prints the secrets to re-enter. Then `pasclaw onboard` (or copy the redacted config over and fill the `•••` in), `pasclaw doctor`, and `pasclaw memory status` if the hybrid search runtime needs provisioning again; model weights are not part of a backup.

## Scheduling

`pasclaw maintain --backup`, or `"maintenance": { "backup": true }` with a nightly `@maintain` cron entry, runs a backup at the end of each [maintenance pass](./maintenance.md). There is no remote target built in: the directory can be a mount, and copying a directory elsewhere is a solved problem with better tools than this one.
