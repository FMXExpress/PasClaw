# Ablation: first-turn prompt cost by setting

Generated: 2026-06-19T03:21:50Z

Each row is one variant of PasClaw's configuration. `req_bytes`
is the size of the FIRST `/v1/chat/completions` request body --
the system prompt + tools schema + user task. Larger = more
tokens spent on every turn before any agent reasoning.

Δ columns are vs `stock` (req_bytes=12822, tools=13).

| variant | req_bytes | Δbytes | tools | Δtools | tool diff |
|---|---|---|---|---|---|
| `stock-no-tools` | 1879 | -10943 | 0 | -13 | − execute_code fs_edit_hashline fs_grep fs_list fs_read fs_write memory_fetch memory_search session_search shell_exec vault_get vault_search web_fetch |
| `baseline` | 9910 | -2912 | 9 | -4 | − memory_fetch vault_get vault_search web_fetch |
| `security` | 9910 | -2912 | 9 | -4 | − memory_fetch vault_get vault_search web_fetch |
| `stock` | 12822 | +0 | 13 | +0 | — |
| `stock+orient-task-aware` | 12822 | +0 | 13 | +0 | — |
| `stock+checkpoints` | 12822 | +0 | 13 | +0 | — |
| `stock+stats` | 12822 | +0 | 13 | +0 | — |
| `stock+cache-1h` | 12822 | +0 | 13 | +0 | — |
| `stock+skill-distiller` | 12822 | +0 | 13 | +0 | — |
| `stock+auto-router` | 12822 | +0 | 13 | +0 | — |
| `stock-no-mcp` | 12822 | +0 | 13 | +0 | — |
| `lean-stock` | 12822 | +0 | 13 | +0 | — |
| `stock+condenser` | 13374 | +552 | 14 | +1 | + tool_output_get |
| `stock+output-cap-16k` | 13374 | +552 | 14 | +1 | + tool_output_get |
| `lean-build` | 13374 | +552 | 14 | +1 | + tool_output_get |
| `stock+skill-progressive` | 13674 | +852 | 15 | +2 | + skills_list skills_view |
| `low-token` | 14226 | +1404 | 16 | +3 | + skills_list skills_view tool_output_get |
| `lean-build-plus-skills-disclosure` | 14226 | +1404 | 16 | +3 | + skills_list skills_view tool_output_get |
| `stock+skill-self-manage` | 14313 | +1491 | 14 | +1 | + skills_manage |
| `max-build` | 15717 | +2895 | 17 | +4 | + skills_list skills_manage skills_view tool_output_get |
| `all-on` | 15717 | +2895 | 17 | +4 | + skills_list skills_manage skills_view tool_output_get |

## Interpretation

- **Zero-byte toggles** (Δbytes = 0): pure behavior, no prompt cost. Default candidates for a 'free upgrade' composite over stock.
- **+552 / +1 tool**: registers `tool_output_get`, triggered by `condense_reversible` OR a non-zero `tool_output_cap`. Pay for this when your tool outputs are large enough to hit the cap.
- **+852 / +2 tools**: `progressive_disclosure` registers `skills_list` + `skills_view`. Pay for this only if you have skills installed and want the agent to discover them on demand.
- **+1491 / +1 tool**: `self_manage` registers `skills_manage`. The single most expensive registration. Pay for this only if the agent should be authoring skills mid-session.

`baseline` and `security` strip web_fetch / vault entirely -- useful in sandboxed deployments where outbound HTTP is explicitly off.
