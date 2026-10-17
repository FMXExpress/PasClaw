# Maintenance

The difference between an agent that gets worse with use and one that gets better is whether anything looks at the day's work after the fact. Facts outlive their expiry, skills accumulate that nothing calls, `MEMORY.md` swells past the always-loaded budget, and the operator notices when the prompt is mostly noise. `pasclaw maintain` is the pass that looks.

```sh
pasclaw maintain                          # today's pass, settings from config.json
pasclaw maintain --since 7 --review       # a week's sessions, plus the model's critique
pasclaw maintain --backup                 # and a backup at the end
pasclaw maintain --dry-run                # report only: delete nothing, call nothing
pasclaw cron add nightly "0 3 * * *" @maintain   # schedule it
```

The cron form runs inside `pasclaw gateway`, in-process, from one reserved skill name. Its one-line summary goes to the daily note and to the entry's channel like any cron output; the full report is on disk.

## What one pass does

1. **Facts.** `facts.db` rows whose `expires` is in the past are deleted (they have been invisible to every read since then), and superseded rows older than `maintenance.keep_superseded_days` (default 30; `0` keeps them forever). The report says how many went and how many are active.
2. **Always-loaded memory.** `SOUL.md`, `USER.md`, `MEMORY.md`, today's and yesterday's note are sized against `memory_core_budget_bytes`. A file over the cap is flagged with how far over it is and the [six-months test](./memory.md#tiers).
3. **Sessions.** The last `--since` days of saved sessions (default 1): sessions, user turns, tool calls, tool results that look like failures (with up to 12 sample lines), input and output tokens.
4. **Skills.** Installed skills, how many are callable, which callable ones no session invoked in `maintenance.unused_skill_days` (default 30), and pairs whose name and description overlap enough to be the same skill twice. Reported, never removed: `pasclaw skills remove` is the operator's call.
5. **Review** (`--review`, or `maintenance.review: true`). One call to `background_model` with the report so far, asking for at most 200 words: what went wrong, one or two changes for tomorrow, what in the always-loaded files should move out. The "dream log". Off by default because it costs a call.
6. **Backup** (`--backup`, or `maintenance.backup: true`). [`pasclaw backup`](./backup.md) with rotation.
7. **Report.** Everything above as Markdown at `workspace/memory/maintenance/<date>.md`. That directory is under `memory/`, so `memory_search` reaches past reports, and it is not one of the always-loaded files, so they never cost prompt space.

`--dry-run` does steps 2, 3 and 4 and counts for 1, deleting nothing, calling no model, writing no file. The exit code is 2 when the report carries warnings (a fact store that would not open, a backup that failed), 0 otherwise.

## Config

```json
"maintenance": {
  "keep_superseded_days": 30,
  "unused_skill_days": 30,
  "review": false,
  "backup": false
},
"background_model": "claude-haiku-4-5-20251001"
```

The flags override the block for one run. `background_model` is what the review runs on; empty falls back to `fast_model`, then the main model (see [Configuration](./configuration.md)).

## What it will not do

- Rewrite `MEMORY.md`. It says which file is over budget and by how much; moving lines out is a judgement call the operator or the agent makes with the file open.
- Remove a skill. Same reason.
- Delete active facts, however old. Only expiry and supersession retire a fact.
- Run on its own. Nothing in PasClaw schedules work the operator did not ask for; the cron line above is the opt-in.
