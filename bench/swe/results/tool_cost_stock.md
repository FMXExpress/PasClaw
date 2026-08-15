# Per-tool size — `stock` variant

Generated: 2026-06-19T04:31:18Z

Each row is one tool registration. `total_bytes` is the
on-the-wire byte size of that tool's entry in the `tools[]`
array of the first /v1/chat/completions request. `desc_chars`
is the description string length; `schema_bytes` is the
compact JSON of the parameters schema.

| tool | total | desc | schema | %  |
|---|---|---|---|---|
| `execute_code` | 1078 | 583 | 410 | 12.7% |
| `fs_edit_hashline` | 982 | 734 | 123 | 11.6% |
| `web_fetch` | 954 | 444 | 428 | 11.3% |
| `fs_grep` | 926 | 450 | 396 | 10.9% |
| `session_search` | 786 | 439 | 254 | 9.3% |
| `memory_search` | 705 | 340 | 279 | 8.3% |
| `vault_search` | 634 | 334 | 213 | 7.5% |
| `memory_fetch` | 633 | 267 | 281 | 7.5% |
| `vault_get` | 479 | 262 | 135 | 5.7% |
| `fs_read` | 399 | 133 | 179 | 4.7% |
| `fs_write` | 342 | 146 | 115 | 4.0% |
| `shell_exec` | 313 | 105 | 125 | 3.7% |
| `fs_list` | 231 | 70 | 77 | 2.7% |
| **TOTAL** | **8462** |   |   | 100% |

## What to look at

- **Long descriptions on rarely-explained tools** — fs_read, fs_write, shell_exec are universally understood; their multi-line descriptions in PasClaw.Tools.* may pay for themselves with a small subset of users.
- **Verbose schema strings** — JSON Schema's `description` fields inside parameters compound: each property gets one.
- **Tool name length** — `fs_edit_hashline` is 16 chars × 4 mentions per call (name, in the schema, in the description) — minor but multiplies across runs.
