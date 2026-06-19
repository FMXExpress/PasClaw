# Per-turn request growth

Generated: 2026-06-19T04:36:12Z
Fixture: `01-snippet-window-magic-number`
Mock transcript: `fixture/01-snippet-window-magic-number/mock/default.jsonl`

`req_bytes[N]` is the byte size of the Nth /v1/chat/completions
request body. Growth between turns shows how the conversation
accumulates: each turn adds the prior assistant message + the
tool result. Condenser / `tool_output_cap` clip the tool-result
side of that growth.

| variant | turn 1 | turn 2 | turn 3 | Δ2→3 | total |
|---|---|---|---|---|---|
| `baseline` | 9916 | 10897 | 12100 | +1203 | 32913 |
| `stock` | 12828 | 13809 | 15012 | +1203 | 41649 |
| `max-build` | 15723 | 16704 | 17907 | +1203 | 50334 |
| `low-token` | 14232 | 15213 | 16416 | +1203 | 45861 |
| `lean-stock` | 12828 | 13809 | 15012 | +1203 | 41649 |
| `lean-build` | 13380 | 14361 | 15564 | +1203 | 43305 |
| `lean-edit` | 9916 | 10897 | 12100 | +1203 | 32913 |

## Reading the table

- **turn 1** = first-turn prompt size (what `probe_first_turn.py` measured).
- **turn 2** = turn 1 + the assistant's tool_call + the tool result.
- **turn 3** = turn 2 + the assistant's next tool_call + result.
- **Δ2→3** is the size of one round (assistant turn + tool result). A flat slope means tool-result blobs aren't dominating; a steep one means they are.
- **total** is the sum of req_bytes across all turns: the actual model token cost for the whole task (each turn re-sends the conversation).
