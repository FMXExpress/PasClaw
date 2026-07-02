# bench/agentloop — deterministic agent-loop harness benchmark

Measures **harness** quality, not model quality (that's [`bench/swe`](../swe)):
the "model" is a script played by the bench process itself through the
**relay provider**, so every run is fully reproducible, costs zero API
tokens, and every request envelope the loop builds is inspectable.

This is the codified version of the methodology that found the
`MALFORMED_FUNCTION_CALL` death spiral (#406), the workspace/CWD split
(#408), and the goal-drift failure (#412): start a real gateway, connect
as a relay worker, answer each inference request from a script, and assert
on what the **loop** did.

## Run

```sh
make bench-agentloop     # compiles bench/agentloop/agentloop_bench.pas + runs it
```

Pure FPC -- no external runtime; the harness reuses the repo's own pieces
(`TProcess` to spawn the built binary, the `Cmd.Relay`-style Indy SSE
client, `PasClaw.JSON`, `PostJSON`/`GetJSONURL`). Exit code 0 = all
scenarios pass. Needs a free port 8140 and `build/pasclaw` built. Not part
of `make test` (it binds a port and spawns a server); run it when touching
`PasClaw.Tools.ToolLoop`, `PasClaw.Stream.Reliability`, or the gateway
loop paths. FPC-only (`TProcess`).

## Scenarios

| scenario | asserts | key metric |
|---|---|---|
| `build-site` | progress ledger folds into iteration 2's system prompt (goal + written file + todo checklist), iteration 1 stays pristine (prefix-cache), deliverable lands on disk | `iterations_to_deliverable` |
| `malformed-recovery` | a Gemini-shaped `MALFORMED_FUNCTION_CALL` empty turn is auto-retried with the corrective nudge naming a *registered* tool, and the turn still delivers | `retries_to_recover` |
| `resume-after-cap` | the 25-iteration stop carries the resume ledger ("do NOT redo", written files, read counts) in the notice; a follow-up "continue" turn anchors its ledger goal to the original task, not to the word "continue" | `max_request_body_bytes` (context-growth baseline across 25 iterations) |

## Adding a scenario

A scenario is: a handler `function(N: Integer; const EnvJSON: string): string`
returning the relay response JSON for the Nth provider call, registered via
`ResetScenario(@Handler)`; then `Chat(...)` a task and assert on the
recorded envelopes (`EnvSystemPrompt` / `EnvLastMessage` on `EnvAt(i)`),
the returned answer text, and the workspace on disk. Responses use the
relay envelope shape (`content`, `finish_reason`, `tool_calls[]` in
OpenAI form — see [`docs/providers-relay.md`](../../docs/providers-relay.md)).

Report numbers with `metric(name, value)` — the point of this bench is
that harness changes land with before/after numbers, not vibes.
