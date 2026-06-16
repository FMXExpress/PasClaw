# Checkpoints (undo / redo)

PasClaw snapshots files before the agent writes them, so you can rewind the last N turns' edits when the model breaks something. Opt-in; off by default. Enable via `pasclaw onboard`, or set `checkpoints.enabled = true` in `config.json`.

## TUI

```
/undo        # rewind 1 turn
/undo 3      # rewind 3 turns
/redo        # roll forward 1 turn (zpaq backend only)
/redo 2      # roll forward 2 turns (zpaq backend only)
```

`/redo` is the inverse of `/undo`: it replays whatever `/undo` captured into the redo stack. Standard editor semantics — a fresh edit after `/undo` invalidates the redo stack (the alternative branch is dead).

## Storage backends

Two backends co-exist; the right one is picked at session start.

### `cbZpaq` (preferred)

One streaming archive per session via the vendored Free Pascal port of **libzpaq 7.15** (`src/pkg/vendor/zpaq/`, MIT-licensed, ~180 KB checked into the repo — no separate fetch step). Plus a JSON journal that records which archive segment belongs to which turn and which paths.

```
$PASCLAW_HOME/workspace/checkpoints/<session-id>/
├── archive.zpaq      # one streaming archive, compressed (LZ77 method 1)
└── index.json        # turn → archive_idx mapping + redo stack
```

`index.json` schema (v1):

```json
{
  "version": 1,
  "current_turn": 17,
  "archive_count": 42,
  "turns": [
    {
      "turn": 1,
      "ts": "2026-06-16T17:00:00",
      "entries": [
        { "path": "/abs/src/foo.pas", "archive_idx": 0, "was_created": false }
      ]
    }
  ],
  "redo_stack": [
    {
      "turn_label": 16,
      "entries": [
        { "path": "/abs/src/foo.pas", "archive_idx": 41 }
      ]
    }
  ]
}
```

Each `/undo` snapshots the current state of every touched path into the archive *before* rolling back, then pushes the bundle onto `redo_stack`. `/redo` pops the top bundle and extracts its segments. New writes clear the stack.

**Compression:** method 1 (LZ77) on the snapshot hot path — fast enough that latency stays sub-100ms per snapshot for typical source files. Higher tiers (methods 2–5) would save more disk at higher CPU cost; tune via `PasClaw.Checkpoints.Zpaq.ZpaqDefaultMethod`.

**Selected when:** PasClaw was built under FPC. The vendor is `{$mode objfpc}` so it doesn't compile under Delphi; Delphi builds fall through to `cbLegacy`.

### `cbLegacy` (fallback)

Per-turn directory of raw blobs + `manifest.json` — the original PR #221 storage. Used on Delphi builds (where the zpaq vendor unit, written in `{$mode objfpc}`, doesn't compile). Same `/undo` semantics; **`/redo` is not available** under this backend (no per-undo capture point).

```
$PASCLAW_HOME/workspace/checkpoints/<session-id>/turn-NNNN/
├── manifest.json
└── blobs/0000.bin, 0001.bin, ...
```

## Behavior

| Property | `cbZpaq` | `cbLegacy` |
|---|---|---|
| `/undo` | ✓ | ✓ |
| `/redo` | ✓ | ✗ (`'redo not supported by this backend'`) |
| Cross-turn dedup | none (streaming format) | none |
| Per-segment compression | ✓ (zpaq method 1) | ✗ (raw blobs) |
| `KeepLast` pruning at `BeginTurn` | ✓ (prunes oldest turn records from journal) | ✓ (rm -rf oldest turn dir) |
| Files the model **created** in a rewound turn | left in place (carve-out) | left in place (carve-out) |

The carve-out for created files is the same in both backends: `/undo` doesn't delete files the model created during the rewound window. Fixing this needs a post-write snapshot path and is deferred to a follow-up; the alternative ("delete any file created during a rewound turn") risks data loss when the model rewrites unrelated files in the same turn.

## Choosing `KeepLast`

`checkpoints.keep_last` (default 32) bounds how many turn records the journal keeps. Once exceeded, the oldest is dropped at the next `BeginTurn`. Under `cbZpaq` the archive itself isn't compacted — the segments stay on disk, just unreferenced from the journal. Disk grows monotonically per session; archive a finished session and remove its `checkpoints/<session-id>/` dir to reclaim space.

## Implementation

- `src/pkg/checkpoints/PasClaw.Checkpoints.pas` — public API + backend dispatch + both backend implementations.
- `src/pkg/checkpoints/PasClaw.Checkpoints.Zpaq.pas` — thin wrapper over the vendored libzpaq port.
- `src/pkg/vendor/zpaq/` — Xelitan's Free Pascal port of libzpaq 7.15, vendored permanently in-tree (MIT; see `NOTICE` for provenance).
- Tests:
  - `src/tests/checkpoints_tests.pas` — legacy backend coverage.
  - `src/tests/checkpoints_zpaq_tests.pas` — wrapper round-trip.
  - `src/tests/checkpoints_redo_tests.pas` — full `BeginTurn / SnapshotBeforeWrite / UndoTurns / RedoTurns` flow incl. redo-stack invalidation.
