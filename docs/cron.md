# Cron

```sh
pasclaw cron list
pasclaw cron add daily-summary "0 9 * * *" summarize "workspace/memory"
pasclaw cron add ping-discord "*/15 * * * *" healthcheck "--channel discord:https://discord.com/api/webhooks/..."
pasclaw cron add line-status "0 * * * *" status_skill "--channel line:U1234abcd"
pasclaw cron disable daily-summary
pasclaw cron enable  daily-summary
pasclaw cron remove  daily-summary
```

The cron scheduler runs inside `pasclaw gateway` (not `pasclaw serve`). Standalone-cron deployments use `pasclaw gateway` with the HTTP listener pointed at a private interface.

## Entry format

Each cron entry is a row in `config.json`'s `crons[]`:

```json
{
  "id":          "daily-summary",
  "spec":        "0 9 * * *",
  "skill":       "summarize",
  "args":        "workspace/memory",
  "channel_kind":   "discord",
  "channel_target": "https://discord.com/api/webhooks/...",
  "enabled":     true
}
```

- `id` — unique entry name (used by `enable` / `disable` / `remove`).
- `spec` — standard cron 5-field syntax (`min hour dom mon dow`).
- `skill` — name of the skill to invoke (must be installed; see [Skills](./skills.md)).
- `args` — argument string passed verbatim to the skill template.
- `channel_kind` / `channel_target` — optional; posts skill output to the named channel sink (see below).
- `enabled` — `true`/`false`; toggle with `pasclaw cron enable/disable`.

## At-least-once delivery

Each cron entry persists its last successful fire time to `$PASCLAW_HOME/workspace/cron/state.json` so a missed slot (gateway down, laptop closed) catches up on the next tick instead of being silently skipped.

Delivery is **at-least-once**: the state file is written after the skill runs (`PasClaw.Cron.Scheduler.pas:175` runs the skill, `:196` persists the timestamp), so a crash between those two steps will replay the job on restart. Idempotent skills are safe; side-effecting skills (sending emails, posting to channels) should self-deduplicate.

## Output handling

Skill output is appended to `workspace/memory/<today>.md` for the model to recall on subsequent turns, and — if `--channel <kind>:<target>` was set — posted to the configured channel.

### Channel kinds

| Kind | Target | Auth source |
|---|---|---|
| `discord` | Discord webhook URL | — |
| `slack` | Slack webhook URL | — |
| `teams` | Microsoft Teams Incoming Webhook URL | — |
| `webhook` | Generic webhook URL | — |
| `line` | LINE userId | `$PASCLAW_LINE_TOKEN` |
| `whatsapp` | phone number | `$PASCLAW_WHATSAPP_TOKEN` + `$PASCLAW_WHATSAPP_PHONE_ID` |

## Cron syntax

Standard 5-field cron, no seconds:

```
* * * * *
| | | | └── day-of-week (0-6, Sun=0)
| | | └──── month (1-12)
| | └────── day-of-month (1-31)
| └──────── hour (0-23)
└────────── minute (0-59)
```

Comma lists (`0,15,30,45 * * * *`), step values (`*/15 * * * *`), and ranges (`9-17 * * * *`) all work. No `@daily` / `@weekly` aliases yet — use `0 0 * * *` / `0 0 * * 0`.

Timezone: cron specs are evaluated in the host's local timezone. Set `$TZ` (POSIX) or use `ApplyTimezoneFromEnv` in embedders to override.

## Listing and inspection

```sh
pasclaw cron list
```

prints id + spec + skill + next-fire + enabled. The web UI's Cron tab shows the same data with live last-fire timestamps. `GET /v1/cron` returns the JSON list.

## Pitfalls

- **Cron entries reference skills by name.** If you `pasclaw skills remove <skill>` without removing the cron entry, the next tick fails noisily and the state file still advances.
- **At-least-once means duplicate-tolerant skills only.** A skill that sends an email needs its own dedupe (e.g. write a marker file on success and skip if present).
- **The gateway must be running.** Cron lives inside `pasclaw gateway`; closing the laptop pauses fires. The catch-up logic handles the gap, but only the missing **most recent** slot — older slots in a >`spec_interval` gap get skipped, not back-filled.

## See also

- [Commands](./commands.md#cron) — full flag set.
- [Skills](./skills.md) — what `skill` references.
- [Channels](./channels.md) — how `--channel` targets work.
- [Heartbeat](./commands.md#heartbeat) — the separate periodic-wake daemon that runs the **agent loop** (not a single skill) on a file's body.
