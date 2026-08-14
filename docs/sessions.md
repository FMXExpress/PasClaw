# Sessions

`pasclaw agent` serialises conversation history to `$PASCLAW_HOME/workspace/sessions/<id>.json` after every turn — messages + `tool_calls` + `tool_results` + model + provider + compaction summary. Persistence is **on by default**: every interactive `pasclaw agent` run auto-allocates a fresh id and the conversation survives Ctrl-C / crash without any flag.

## Session id

Format: `yyyymmddTHHMMSS-<8 hex>` (e.g. `20260601T093015-1a2b3c4d`). Sortable, collision-safe.

## Commands

```sh
pasclaw agent                                          # interactive; auto-allocates a fresh id
pasclaw agent --session 20260601T093015-1a2b3c4d       # resume by id
pasclaw resume 20260601T093015-1a2b3c4d                # shorthand for --session

pasclaw session list                                   # id, age, title, msg count
pasclaw session show <id>                              # metadata + last 8 messages (head trimmed)
pasclaw session export <id>                            # raw JSON to stdout (pipe through jq)
pasclaw session delete <id>                            # remove the session file
```

An id that doesn't yet exist starts a fresh session at that id — handy for scripts pre-seeding e.g. `daily-2026-06-01`:

```sh
pasclaw agent --session daily-2026-06-01 -m "what's on for today?"
```

## Slash commands (interactive)

| Command | Effect |
|---|---|
| `/help` | List slash commands. |
| `/status` | Show model + provider + message count + thinking state. |
| `/new` | Start a fresh session (new id, history cleared, steering queue dropped). |
| `/reset` | Clear history in the current session (id preserved). |
| `/compact` | Force a summariser pass over the older portion of history. Persisted before returning to the prompt. |
| `/think` | Toggle extended-thinking mode for the next turn (Anthropic Claude). |
| `/tools` | List registered tools. |
| `/steer <msg>` | Push a steering message into the current session's queue (handy for testing). |
| `/quit` | Exit. |

## File shape

```json
{
  "meta": {
    "id":                       "20260601T093015-1a2b3c4d",
    "title":                    "summarise this repo",
    "model":                    "claude-opus-4-7",
    "provider":                 "anthropic",
    "system_prompt_override":   null,
    "working_state": {
      "recent_edits":       ["src/main.pas", "docs/getting-started.md"],
      "last_shell_command": "make smoke",
      "last_tool_error":    null
    },
    "stats": {
      "input_tokens":            12345,
      "output_tokens":            2345,
      "cache_read_tokens":        8000,
      "cache_created_tokens":      500,
      "turns":                      12,
      "tool_calls":                 23,
      "truncation_bytes_saved":  45678
    }
  },
  "messages": [
    { "role": "user",      "content": "summarise this repo" },
    { "role": "assistant", "content": "Looking...",
      "tool_calls": [{ "id": "...", "function": {"name": "fs_list", "arguments": "{}"} }] },
    { "role": "tool",      "tool_call_id": "...", "content": "..." }
  ]
}
```

`meta.stats` is populated only when `stats_collection_enabled: true`.

Atomicity: writes go through `.tmp` then `rename`, so killing the process mid-write can never leave a half-written JSON file.

## Working-state snapshot

Each session's `meta.working_state` records the last 8 file paths edited via `fs_write` / `fs_edit_hashline`, the most recent `shell_exec` command, and the most recent tool-call error. Persisted under `meta.working_state`; rebuilt after every successful tool loop and re-injected as a system-prompt prefix on the next turn.

Survives `/quit`-and-resume, compaction, and `pasclaw agent --session <id>` so the agent picks up with structured edit/shell/error context even when the conversation transcript no longer carries it.

## Compaction

When the running history — system prompt included — estimates above `compaction.threshold_tokens` (default `80000`), `RunToolLoop` summarises the older portion via the same provider and folds the result into the system prompt as a `[Conversation summary so far]` block, keeping the newest messages verbatim. Falls back to verbatim on summariser failure — no silent context loss.

The summary is a **rolling record**: a later compaction replaces the block rather than appending a second one, and the old record is fed to the summariser as the head of its input, so one block always covers the whole dropped history. The summariser writes a sectioned handoff note — Goal, Progress, Key decisions, Errors encountered, Open questions.

Retention is a **token budget**, not a message count: `retain_budget_tokens` (default `20000`) decides how much recent history survives verbatim, walking back from the newest message. `recent_turns` (default `8`) is a floor — however large the recent messages are, at least that many are kept. The cut never splits a tool_call from its tool_results.

There is also a **reactive** pass: when a provider rejects a call because the context window overflowed (the token estimate ran low — dense content does that), the loop compacts with the threshold forced and retries the call once. If the retry still overflows, the error surfaces.

`/compact` forces the pass manually. The resulting summary lands in `meta.system_prompt_override` so a `/quit`-and-resume picks up the compacted shape.

Configuration (all optional; these are the defaults):

```json
"compaction": {
  "enabled":              true,
  "threshold_tokens":     80000,
  "retain_budget_tokens": 20000,
  "recent_turns":         8,
  "summary_budget":       800
}
```

Before the older history is dropped, the session's [working-state snapshot](#working-state-snapshot) is refreshed from it, so edited paths and shell commands in the dropped half survive in the cross-turn snapshot even though the transcript no longer carries them.

## Mid-loop steering

Push a follow-up into a running agent without waiting for the current tool loop to finish. From another terminal:

```sh
pasclaw steer 20260601T093015-1a2b3c4d "actually skip X, focus on Y"
pasclaw steer <session-id> --list        # show pending count
pasclaw steer <session-id> --clear       # drop the queue
```

The running `pasclaw agent --session <id>` drains the queue at the top of its NEXT tool-loop iteration and folds each pending message into history as a `[user steering] ...` system note before the next LLM round-trip. Up to 4 messages per iteration are applied (`MaxSteeringPerTurn`, matching nanobot's `_MAX_INJECTIONS_PER_TURN`); extras are dropped with a warning so a runaway pusher can't grow history unbounded.

`/steer <msg>` inside an interactive session is the same mechanism (handy for testing). `/reset`, `/new`, and `pasclaw session delete` clear the queue.

### Storage

One append-only JSONL file per session under `$PASCLAW_HOME/workspace/steering/<id>.jsonl`. Atomic per-line POSIX appends + rename-to-tmp-on-drain so concurrent push/drain doesn't lose messages.

### Channel coverage

Currently only CLI sessions wire `SteeringKey`; channels can opt in by passing their own per-conversation key on `TToolLoopConfig.SteeringKey` once they restructure to non-blocking poll loops.

## Session search

`session_search(query, k?)` is a model-facing tool that searches the full text of every saved session under `workspace/sessions/`. Returns session id + title + snippet + BM25 score with a `pasclaw resume <id>` hint per hit.

Index lives at `workspace/sessions/.search.db`, lazily rebuilt from the JSON transcripts (reindexes a session only when its `UpdatedAt` advances). Reuses `memory_search`'s FTS query normaliser so both tools treat a query identically. Gateway stat buckets (`_gateway_v1_chat.json`, etc.) are excluded.

## Auto-allocation defaults

- `pasclaw agent` (no args) — fresh id, persists.
- `pasclaw agent -m "..."` (one-shot `-m`) — does NOT persist. Single turns aren't worth a session file.
- `pasclaw agent --session <id>` — resume or create at that id.
- `pasclaw tui` — Delphi build reads `ListSessions` for the session pane and resumes the newest by default; pass `--session <id>` to pick a different one. FPC build of `tui` keeps history in-memory only.

## See also

- [Commands](./commands.md#agent) for the full `pasclaw agent` flag set.
- [Tools](./tools.md) for `session_search` and `memory_search`.
- [Configuration](./configuration.md) for `compaction.*` and `stats_collection_enabled`.
