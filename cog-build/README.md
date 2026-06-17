# PasClaw BUILD cog

A Replicate [cog](https://github.com/replicate/cog) that exposes `pasclaw build` — multi-iteration agent runs with a `workspace.zip` handshake — for use against ephemeral cloud compute.

Sibling to [`/cog/`](../cog/), which runs the simpler one-shot `pasclaw agent` flow. This one is for the "ship the whole brain back and forth" pattern: feed in a workspace.zip from a previous run, get a workspace.zip back containing everything the agent did (memory updates, knowledge-base writes, checkpoint history, source files written, …).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `message` | str | — | The build task ("add X", "port Y to Z", …) |
| `max_iters` | int | 50 | Tool-loop iteration budget |
| `timeout_seconds` | int | 3600 | Subprocess timeout (Replicate's container ceiling applies on top) |
| `workspace_in` | Path | None | Workspace.zip from a previous build. Cog handles both upload + URL via Path |
| `workspace_in_url` | str | "" | Explicit URL — downloaded via [`pget`](https://github.com/replicate/pget) for parallelism. Wins over `workspace_in` when set. |
| `openai_api_key` / `anthropic_api_key` / `gemini_api_key` / `groq_api_key` / `openrouter_api_key` / `deepseek_api_key` | str | "" | Provider creds — same shape as `/cog/`. |
| `provider`, `model` | str | "" | Override which provider / model is used. Empty = first key wins. |

## Outputs

A pydantic `BaseModel`:

```jsonc
{
  "workspace": "<Path to workspace_out.zip>",
  "text":      "<model's final reply, same as `pasclaw agent -q`>"
}
```

The `text` field lets the caller decide whether to feed the workspace back for another round. Typical control-loop:

```python
import replicate

ws = None
for step in range(20):
    out = replicate.run(
        "owner/pasclaw-build",
        input={
            "message": "implement issue #42",
            "max_iters": 30,
            "workspace_in_url": ws,        # None on the first call
            "anthropic_api_key": KEY,
        },
    )
    ws = out["workspace"]
    print(out["text"])
    if "DONE" in out["text"]:
        break
```

## Workspace contents

Everything under `$PASCLAW_HOME` ships back:

```
workspace/
├── memory/MEMORY.md           ← rules + scars carry forward
├── kb.db                      ← knowledgebase
├── kb-files/*                 ← uploaded reference docs (including binaries)
├── sessions/<id>.json         ← chat history
├── checkpoints/<id>/          ← zpaq-backed undo/redo journal
│   ├── archive.zpaq
│   └── index.json
├── skills/                    ← installed skills
└── AGENTS.md                  ← project rules (if present)
```

A small denylist (`pasclaw build` enforces) keeps surrounding-repo noise out:
- `.git` directories at any depth
- `.DS_Store`, `Thumbs.db`
- `kb.db-journal` (SQLite WAL, regenerated)

Everything else — tmp files, log dumps, kb-files binaries — does ship. The whole point of the handshake is "preserve the entire brain".

### What does NOT ship: `config.json` (API keys)

`config.json` is deliberately kept **outside** `$PASCLAW_HOME` so it never ends up in `workspace.zip`:

- The predictor writes it to a sibling scratch dir and sets `PASCLAW_CONFIG` so PasClaw finds it there.
- API keys stay in the predict.py process scope.
- A `workspace_in.zip` from a prior run can't clobber the fresh API keys this call was given.
- The output `workspace.zip` is provider-agnostic — safe to log, share, or store anywhere the rest of the workspace already goes.

Backward-compatible with every other `pasclaw` caller: when `PASCLAW_CONFIG` is unset (the normal case for CLI / TUI / gateway users), `GetConfigPath` falls back to `$PASCLAW_HOME/config.json` exactly as it did before.

## Size cap

**4 GiB** input, enforced at both ends (Python + Pascal). Replicate's upload + container limits will catch this earlier in practice; the cap is there so a runaway caller fails fast with a clean error.

## Why `pget` for the input?

For large URL-backed workspaces (multi-hundred-MB checkpoint archives), cog's default Path-input fetch is single-stream. Replicate's [pget](https://github.com/replicate/pget) does parallel multi-connection downloads from S3-compatible storage — typically 3–5× faster. Use `workspace_in_url` (string) to opt in; `workspace_in` (Path) still works for upload-from-disk or smaller URLs that don't benefit from parallelism.

## Build

```sh
cd cog-build/
cog build -t pasclaw-build
```

Then push to Replicate as usual.

## Run locally

```sh
cd cog-build/
cog predict \
  -i message="add a --version flag to the CLI" \
  -i max_iters=30 \
  -i anthropic_api_key=sk-ant-… \
  -i workspace_in=@/tmp/prev_workspace.zip
```
