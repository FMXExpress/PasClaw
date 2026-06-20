# Tool utilization across PasClaw's bench fixtures

Generated: 2026-06-19T04:47:04Z
Sources: 4 mock transcripts + 0 live-driven runs

`cost_bytes` is the on-the-wire size of the tool's
registration in PasClaw's first /v1/chat/completions request
(from `results/tool_cost_stock.md`). `mock_calls` is how
often the bundled ideal-trajectory transcripts call it;
`live_calls` is from the queue history of any live-driven
runs left under `results/run-*/`.

Rows above the divider were NEVER called -- those are the
first candidates for default-off / opt-in registration.

| tool | cost | mock | live | per-task | bytes/use |
|---|---|---|---|---|---|
| `skills_manage` | 1491 | 0 | 0 | 0.00 | ∞ |
| `execute_code` | 1078 | 0 | 0 | 0.00 | ∞ |
| `fs_edit_hashline` | 982 | 0 | 0 | 0.00 | ∞ |
| `web_fetch` | 954 | 0 | 0 | 0.00 | ∞ |
| `fs_grep` | 926 | 0 | 0 | 0.00 | ∞ |
| `session_search` | 786 | 0 | 0 | 0.00 | ∞ |
| `memory_search` | 705 | 0 | 0 | 0.00 | ∞ |
| `vault_search` | 634 | 0 | 0 | 0.00 | ∞ |
| `memory_fetch` | 633 | 0 | 0 | 0.00 | ∞ |
| `tool_output_get` | 552 | 0 | 0 | 0.00 | ∞ |
| `vault_get` | 479 | 0 | 0 | 0.00 | ∞ |
| `skills_view` | 452 | 0 | 0 | 0.00 | ∞ |
| `skills_list` | 400 | 0 | 0 | 0.00 | ∞ |
| `fs_list` | 231 | 0 | 0 | 0.00 | ∞ |
|   |   |   |   |   |   |
| **USED ↓** |   |   |   |   |   |
| `shell_exec` | 313 | 1 | 0 | 0.25 | 313 |
| `fs_read` | 399 | 3 | 0 | 0.75 | 133 |
| `fs_write` | 342 | 4 | 0 | 1.00 | 85 |

## Summary

- Total stock-catalog cost: **11357 bytes**
- Cost of NEVER-called tools: **10303 bytes (90.7%)**
- Tools the bundled fixtures actually call: **3 / 17** (18%)

Caveats:

- The bench fixtures are SMALL. Real coding tasks would
  call `fs_grep` (find callers) and `fs_edit_hashline`
  (surgical patches) far more often. The utilization
  numbers here are a floor, not a ceiling.
- Mock transcripts are author-curated; they reflect what I
  THINK the agent should do, not what it actually does. The
  `live` column corrects for that bias as it grows.
- The 13-tool stock catalog plus the 4 max-build add-ons
  are sized in `results/tool_cost_stock.md` -- refresh that
  if a tool's description or schema changes.
