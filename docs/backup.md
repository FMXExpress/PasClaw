# Backup and restore

```sh
pasclaw backup                            # -> $PASCLAW_HOME/backups/pasclaw-<workspace>-YYYYMMDD-HHMMSS.zip
pasclaw backup --to /mnt/nas/pasclaw      # anywhere writable; a mount gets you off-machine copies
pasclaw backup list
pasclaw restore pasclaw-workspace-20261017-030000.zip
```

A backup that cannot be restored is a file. These can, integrations included.

## What is in an archive

| entry | contents |
|---|---|
| `<workspace>/…` | the active workspace: memory (`MEMORY.md`, `USER.md`, `SOUL.md`, daily notes, `facts.db`), sessions, skills, the knowledge base, checkpoints, `AGENTS.md`, `PLAN.md` |
| `config.json` | your real config, API keys and tokens included, so a restore brings every connected API back. **This makes the archive a credential: store it like one.** `RESTORE.md` says so |
| `RESTORE.md` | what this is, which PasClaw wrote it, how many files, the exact restore command |

With `--redact` (or `"backup": { "include_secrets": false }`), `config.json` is replaced by `config.redacted.json`: every secret masked as `•••`: `providers[].api_key`, `mcp_servers[].env`, `gateway.token`, `web_search.api_key`, and the webhook-style `channels[].target` and `crons[].channel_target`. Providers, models, channels, sandbox and memory settings stay intact, and `RESTORE.md` lists what to re-enter. It is the same masking the gateway's `GET /v1/config` uses, from the same function, so the two cannot disagree about what a secret is. Use it for an archive that will sit somewhere shared.

Left out on purpose: the WebView2 browser profile under `workspace/browser/webview2` (hundreds of MB, machine-bound, and your logins), SQLite journals (`*-journal`, `*-wal`, `*-shm`, `kb.db-journal`), `.git`, the sessions search index, which rebuilds itself, and the backup directory itself when it sits inside the workspace, so a backup never contains earlier backups.

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

Members are validated against the destination before extraction (no absolute paths, no `..`), then the workspace directory is copied into place and the notes land as `RESTORE-<workspace>.md`.

`config.json` from the archive is written when the home has none. When one exists it is left alone unless `--force`, which keeps it as `config.json.bak` and replaces it. A redacted archive never writes `config.json`: `config.redacted.json` lands beside the workspace and the command prints the secrets to re-enter. Then `pasclaw doctor`, and `pasclaw memory status` if the hybrid search runtime needs provisioning again; model weights are not part of a backup.

## Scheduling

`pasclaw maintain --backup`, or `"maintenance": { "backup": true }` with a nightly `@maintain` cron entry, runs a backup at the end of each [maintenance pass](./maintenance.md). There is no remote target built in: the directory can be a mount, and copying a directory elsewhere is a solved problem with better tools than this one.
