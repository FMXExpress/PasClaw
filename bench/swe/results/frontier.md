# SWE bench sweep results

Generated: 2026-08-15T14:15:27Z

| variant | n | pass | pass-rate | tok/solved | oos/run | turns/run | frontier |
|---|---|---|---|---|---|---|---|
| `baseline` | 13 | 4 | 0.31 | 4096 | 0.00 | 0.9 | yes |
| `stock` | 13 | 4 | 0.31 | 4096 | 0.00 | 0.9 | yes |
| `max-build` | 13 | 4 | 0.31 | 4096 | 0.00 | 0.9 | yes |
| `max-build-low-iters` | 13 | 4 | 0.31 | 4096 | 0.00 | 0.9 | yes |
| `low-token` | 13 | 4 | 0.31 | 4096 | 0.00 | 0.9 | yes |
| `max-build-plan-mode` | 13 | 0 | 0.00 | - | 0.00 | 0.9 |  |

`frontier=yes` means no other variant strictly dominates on
(pass-rate higher, tokens-per-solved lower, oos lower). Pick
the frontier row whose tradeoff matches your deployment.
