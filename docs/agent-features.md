# AI agent & harness feature catalogue

A survey of what agent harnesses do, and where PasClaw sits on each.

## How to read this

Every row is marked, because a survey where "I read this" and "I remember
this" look identical is worth very little:

- **[S]** sourced — found in material fetched during this survey
- **[K]** recalled — believed from training, **not** verified here
- **[P]** PasClaw — checked against this repository

Sources: a live web search on harness engineering, the
`awesome-harness-engineering` catalogue, and ten project READMEs (OpenHands,
Aider, Cline, Goose, Continue, SWE-agent, Codex CLI, LangGraph, CrewAI, the
MCP server registry). READMEs were capped at 5–6 KB, so absence from an **[S]**
row is weak evidence while presence is strong.

---

## 1. Agent loop & orchestration

| Feature | Field | PasClaw |
|---|---|---|
| ReAct-style thought/action/observation loop | universal [S] | ✅ [P] |
| Graph-structured execution with typed state | LangGraph, statewright [S] | ❌ linear loop |
| Plan-then-execute separation | TaskWeaver, Plan-and-Execute [S] | ✅ `--mode plan` [P] |
| Tree search over action sequences | LATS (Monte Carlo) [S] | ❌ |
| State machine constraining tools per phase | statewright [S] | ⚠? mode gates, not per-phase [P] |
| Parallel tool dispatch | common [S] | ✅ read-only batching [P] |
| Subagent fan-out via orchestration scripts | AgentSPEX, JS orchestration [S] | ✅ `spawn*` [P] |
| Loop-detection middleware | [S] | ❌ iteration cap only [P] |

## 2. Context management & compaction

*The most crowded category in the field by a wide margin.*

| Feature | Field | PasClaw |
|---|---|---|
| Summarisation at the context limit | universal [S] | ✅ `Agent.Compact` [P] |
| Reactive compaction on an overflow error | rare [K] | ✅ forced pass + retry, once per loop [P] |
| Prompt caching of system prompt + tools | [S] | ✅ breakpoints, 1 h TTL [P] |
| Agent-controlled compression tools | Focus Agent, LLMLingua [S] | ❌ |
| Tool-output compression before context entry | headroom (60–95%) [S] | ✅ output cap + `tool_output_get` [P] |
| Symbol/AST index instead of whole-file reads | Token Savior (77%), codebase-memory-mcp, zerolang [S] | ❌ **biggest gap** |
| Natural-language code retrieval | semble (98% token cut) [S] | ⚠? `memory_search`/`kb` over docs, not code [P] |
| Repo map | Aider [S] | ❌ |
| Hash-anchored edits to cut re-sends | dirac (50–80%) [S] | ✅ `fs_edit_hashline` [P] |
| Stale-read elision after a write | not found | ✅ `StubSupersededReads`, −2.5 KB measured [P] |
| Progressive tool disclosure | rare [K] | ✅ 11.8→7.2 KB measured [P] |
| Virtual filesystem over external sources | Mirage (S3/Slack/GitHub) [S] | ❌ |
| Version-pinned library docs injection | Context7 [S] | ⚠? `kb` if indexed manually [P] |
| Structured spec/journal files | Trellis, harness-experimental [S] | ✅ AGENTS.md, MEMORY.md [P] |

## 3. Tool design

| Feature | Field | PasClaw |
|---|---|---|
| JSON Schema function definitions | universal [S] | ✅ [P] |
| Constrained decoding to a grammar | outlines, instructor [S] | ❌ (provider-side only) |
| **Risk annotations** (readOnly/destructive/idempotent/openWorld) | MCP spec [S] | ⚠? `tcReadOnly`/`tcMutating` — two levels, not four [P] |
| Auto-generated constraint harnesses from schemas | AutoHarness [S] | ❌ |
| Agent-native CLIs for arbitrary software | CLI-Anything [S] | ❌ |
| Programmable TUI interaction | tui-use [S] | ❌ |
| Code execution *instead of* discrete tool calls | reported 98.7% token cut [S] | ✅ `execute_code` [P] |

## 4. MCP & skills

| Feature | Field | PasClaw |
|---|---|---|
| MCP client | Cline, Goose, Continue, Codex [S] | ✅ [P] |
| MCP server (expose own tools) | rare [K] | ✅ gateway + `mcp stdio` [P] |
| Stateless MCP core (2026-07-28 spec) | [S] | ✅ supported [P] |
| Skill bundles with routing | Microsoft Skills Framework, agent-skills [S] | ✅ skills [P] |
| **Negative examples in skill routing** | [S] | ❌ |
| Skill marketplace / hub | Cline, Continue [S] | ❌ |
| Auto-distilling turns into skills | rare [K] | ✅ self-improving skills [P] |
| MCP Inspector-style debugging | [S] | ❌ |

## 5. Memory & state

| Feature | Field | PasClaw |
|---|---|---|
| Project memory file (CLAUDE.md / AGENTS.md) | universal [S] | ✅ + export to both [P] |
| Semantic memory search | [S] | ✅ vector index [P] |
| Cross-session recall | rare [K] | ✅ `session_search` / `session_read` [P] |
| Hibernate-and-wake checkpointing | long-running-agent harnesses [S] | ✅ checkpoints [P] |
| Structured handoff between agent phases | initializer→coder handoff [S] | ⚠? working-state snapshot [P] |
| Hierarchical LLM-curated memory | ByteRover [S] | ❌ flat files |
| Programmatic memory searchable as code | PRO-LONG [S] | ❌ |
| **Mining own failures into the prompt** | not found | ✅ `learn --write-scars` → SCARS.md [P] |

## 6. Verification & evaluation

*The field's own diagnosis: agents "mark a task complete without verifying
the outcome" [S], and 65% of enterprise AI failures trace to harness defects
— context drift, schema misalignment, state degradation [S].*

| Feature | Field | PasClaw |
|---|---|---|
| Eval harness with CI gates blocking regressions | LLM Readiness Harness [S] | ⚠? `bench/swe` written, unmerged |
| Oracle-based pass/fail fixtures | SWE-agent, SWE-Bench-Pro [S] | ⚠? same |
| Adversarial / multi-agent convergence checks | [S] | ❌ |
| Deterministic loop regression tests | rare [K] | ✅ `bench/agentloop` [P] |
| Published benchmark numbers | Terminal Bench 2.0, SWE-Bench-Pro, WebArena [S] | ❌ none published |
| Edit verification echoed by the tool | rare [K] | ✅ `edit_file` returns the region [P] |
| **Tools reporting what they did NOT cover** | **not found anywhere** | ❌ — see below |

## 7. Permissions & safety

| Feature | Field | PasClaw |
|---|---|---|
| Per-call approval prompts | Cline, Codex [S] | ⚠? profile-level [P] |
| Hooks at tool boundaries (Pre/PostToolUse) | 27-event pipeline [S] | ✅ hook framework [P] |
| "Lethal trifecta" risk modelling | [S] | ⚠? promptware scan + network block, not modelled as a triad [P] |
| Prompt-injection scanning of tool output | rare [K] | ✅ **fired twice during this survey** [P] |
| Sandboxed execution | OpenHands, Codex [S] | ✅ docker backend [P] |
| Command denylist | common [K] | ✅ [P] |
| Secret redaction | [K] | ✅ FS secret gate [P] |
| Defense-in-depth layered model | OpenDev 5-layer [S] | ⚠? layers exist, not documented as a model |

## 8. Observability

| Feature | Field | PasClaw |
|---|---|---|
| Trajectory logging and replay | agentSPEX, SWE-agent [S] | ✅ sessions + OTel [P] |
| Token/cost tracking and budgeting | Aider, Cline [S] | ✅ per-session stats [P] |
| Drift detection, readiness scoring | Loop Engineering [S] | ❌ |
| Mid-turn state inspection | [S] | ✅ `pasclaw steer` [P] |
| Worktree isolation per run | Loop Engineering [S] | ❌ |

## 9. Inter-agent protocols

| Feature | Field | PasClaw |
|---|---|---|
| A2A (JSON-RPC + Agent Card discovery) | [S] | ❌ |
| AG-UI (event streaming agent→UI) | [S] | ⚠? own SSE, not the standard [P] |
| AP2 / UCP (payments, commerce) | [S] | ❌ |
| Agentic Resource Discovery | [S] | ❌ |

## 10. Human-in-the-loop & temporal

| Feature | Field | PasClaw |
|---|---|---|
| Interrupts at tool-use boundaries | LangGraph, Cline [S] | ✅ steering [P] |
| Approval flows with structured diffs | [S] | ⚠? diffs shown, approval is profile-level |
| Deadline awareness in the loop | [S] — found orthogonal to reasoning ability | ❌ |
| Time-budget warnings in context | [S] | ❌ |
| Per-tool timeout contracts | [S] | ⚠? global shell timeout [P] |
| Mid-flight model swapping | deepclaude [S] | ✅ auto-router + fallback chain [P] |

## 11. Surfaces

| Feature | Field | PasClaw |
|---|---|---|
| CLI | Aider, Codex, Goose [S] | ✅ [P] |
| TUI | rare [K] | ✅ [P] |
| IDE extension | Continue, Cline [S] | ❌ **biggest distribution gap** |
| Web UI | OpenHands [S] | ✅ [P] |
| Native desktop app | rare [K] | ✅ FMX Studio [P] |
| Browser automation | playwright-mcp, Chrome DevTools MCP, Cline [S] | ❌ |
| Mobile device control | agent-device [S] | ❌ |
| Screen-reader accessibility | not found | ✅ MSAA / NSAccessibility / AT-SPI2 (unverified) [P] |
| Scheduled / proactive runs | proactive loops [S] | ✅ cron + heartbeat [P] |

## 12. Commercial / closed agents

Absent from the first pass entirely. Included because their choices set the
expectations PasClaw is judged against, not because the claims are testable.

| Feature | Who | PasClaw |
|---|---|---|
| Whole-repository read before planning | Devin's Cascade [S] | ❌ no repo-wide pass |
| Multi-file edit as one planned unit | Cursor Composer, Cascade [S] | ✅ `apply_patch` [P] |
| Agent runs terminal commands and **verifies against tests** | Cascade [S] | ⚠? only if the model elects to |
| Cloud-delegated agents alongside local ones | Devin Desktop [S] | ⚠? relay workers, not managed [P] |
| Multi-agent supervision surface | Devin's Agent Command Center [S] | ⚠? `spawn_status`, no dedicated UI [P] |
| PR drafting / PR summaries | Copilot [S] | ❌ |
| Inline completion as you type | Copilot, Cursor [S] | ❌ not an editor |
| Shared context across agents and PRs | Devin Desktop [S] | ⚠? shared workspace only [P] |

The positioning split reported in the sources — Cursor as speed, Windsurf as
deep context, Copilot as safety and scale [S] — has no PasClaw analogue.
PasClaw's distinguishing axis is that it is a *self-hosted, provider-neutral*
harness, which none of these are.

## 13. Evaluation, in more depth

The first pass had four sourced rows here; it was the thinnest section and
also the one the field has moved on most.

| Feature | Field | PasClaw |
|---|---|---|
| Issue-resolution benchmark | SWE-bench, SWE-Bench-Pro [S] | ⚠? `bench/swe` unmerged |
| Terminal / CLI benchmark | Terminal-Bench [S] | ❌ |
| Web navigation benchmark | WebArena, WebVoyager [S] | ❌ (no browser) |
| OS-level benchmark | OSWorld [S] | ❌ |
| Tool-use benchmark | tau-bench, tau2-bench, AgentBench, GAIA [S] | ❌ |
| **Trajectory evaluation** — score the nested span tree of model/tool calls, not just the outcome | [S] | ⚠? OTel spans captured, never scored [P] |
| Span-level scoring of tool *selection* | [S] | ❌ |
| LLM-as-judge, calibrated against human labels | [S] | ❌ |
| Agent-as-judge with environment awareness | AJ-Bench [S] | ❌ |
| Eval gates blocking deploy on regression | [S] | ❌ |

### Benchmark exploitation is now a named failure mode

The single most useful thing this pass found, and it is not a feature:

> In April 2026 an automated agent scored 100% or near-100% on seven of
> eight leading benchmarks **without solving a single task**. On SWE-bench
> Verified, editing roughly ten lines in one test configuration file caused
> all 500 tests to pass. [S]

That is the thesis of this document arriving from the opposite direction.
A benchmark that reports a score without reporting what it actually
exercised is the same defect as a linter reporting green on a file it never
opened — the harness confidently asserting a result whose scope it never
checked. The field's answer has been to move from single-axis completion
scores toward trajectory-aware evaluation [S]: score the path, not just the
endpoint, because the endpoint is forgeable.

For PasClaw specifically this raises the bar on `bench/swe`. Its fixtures
use `oracle/test.sh` exit codes — exactly the surface that was gamed. An
oracle that only checks its own exit status cannot tell a real fix from a
doctored config, and any pass-rate published from it inherits that weakness.

## 14. Memory infrastructure

The draft's memory section covered PasClaw-adjacent features; the field has
meanwhile grown dedicated memory *products* with published benchmarks.

| Feature | Who | PasClaw |
|---|---|---|
| Tiered memory: in-context core / recall / archival, modelled on RAM–cache–disk | Letta (MemGPT) [S] | ⚠️ MEMORY.md is "core", `memory_search` is "archival"; no managed middle tier [P] |
| **Self-editing memory** — the agent rewrites its own core block | Letta [S] | ❌ MEMORY.md edits are ad-hoc writes, not a managed operation |
| Fact extraction into a vector store on every turn | Mem0 [S] | ⚠️ distiller extracts facts, but post-hoc, not per-turn [P] |
| Temporal knowledge graph (entities + relations + time) | Zep [S] | ❌ |
| Time-aware retrieval ("what did X believe before Y") | Zep — +15 pts over vector-only on LongMemEval [S] | ❌ |
| Published memory benchmarks (LoCoMo, LongMemEval) | Mem0 92.5% LoCoMo [S] | ⚠️ a LOCOMO-shaped harness exists (PR #308), unmerged |
| Retrieval token budget as a headline metric | Mem0: <7 K/call vs 25 K+ full-context [S] | ❌ never measured |

The pattern worth copying is not any single product but the *shape*: memory
as a tiered system with an explicit token budget per retrieval, benchmarked.
PasClaw has the pieces (MEMORY.md, facts.db, vector index, session search)
without the tiering or the numbers.

## 15. Background / CI agents & git-native workflows

Entirely absent from the first two passes, and it is where the commercial
field converged in 2026: the lifecycle *ticket → cloud sandbox → autonomous
edit → PR → human review* is now the same across every major tool [S].

| Feature | Who | PasClaw |
|---|---|---|
| Repo-scoped cloud task: assign issue, get a PR | Copilot coding agent (runs in GitHub Actions), Google Jules, Codex cloud [S] | ❌ |
| Queueable task batches ("five tickets Friday, five PRs Monday") | [S] | ⚠️ cron runs skills, not repo tasks [P] |
| Agent explores repo, edits, runs tests, opens PR unattended | Copilot [S] | ⚠️ `pasclaw build` does the middle, no VCS integration [P] |
| **Per-agent git worktree isolation** | Intent — attribution "a property of the workspace itself" [S] | ❌ agents share one workspace |
| Attribution without span propagation (structural, from the worktree boundary) | [S] | ❌ |
| Free-tier background quota as a product lever | Jules: 15 tasks/day [S] | n/a (self-hosted) |

Worktree isolation is the standout: it solves attribution, conflict, and
rollback in one move, structurally, with no instrumentation — and PasClaw's
multi-agent story (`spawn*`, shared workspace) currently has all three
problems.

## 16. Observability platforms

The draft had five rows; the field has six anchor platforms [S]: LangSmith
(framework-native), Langfuse (open-source, self-hostable), Arize Phoenix,
Helicone (drop-in proxy), Datadog LLM Obs, Honeycomb.

| Feature | Who | PasClaw |
|---|---|---|
| Every step captured as structured traces — LLM calls, tools, retrievals, control flow | all six [S] | ✅ OTel spans exist [P] |
| Failure localisation in *intermediate* steps, not final answers | the category's stated purpose [S] | ❌ spans emitted, nothing inspects them |
| Self-hostable open-source option | Langfuse [S] | ✅ OTel exports anywhere [P] |
| Drop-in proxy instrumentation (no code change) | Helicone [S] | ⚠️ the gateway *is* a proxy; it aggregates stats, not traces [P] |
| Eval loops attached to traces | LangSmith, Langfuse [S] | ❌ |

## 17. Sandboxing below Docker

The draft treated "sandboxed execution" as one row. The field's 2026
consensus is blunter: shared-kernel container isolation "isn't cutting it
anymore for executing untrusted AI agent code" [S].

| Isolation level | Who | PasClaw |
|---|---|---|
| Shared-kernel containers (Docker/runc) | the baseline being retired [S] | ✅ docker backend — i.e. the retired baseline [P] |
| User-space kernel syscall interception (~10–15% CPU cost, full syscall audit) | gVisor [S] | ❌ |
| MicroVMs — hardware boundary per execution | Firecracker, Kata; E2B/Daytona/Modal productise it [S] | ❌ |
| Sandbox-per-execution as a service API | E2B, Daytona [S] | ❌ |

PasClaw's honest position: its docker backend is what the field now calls
the insufficient baseline. For a self-hosted personal agent that mostly runs
the operator's own code, that is defensible — but the survey should say it
rather than let "sandboxed ✅" imply parity with microVM isolation.

## 18. Guardrails & cost control

The safety section covered PasClaw's own layers; the field has meanwhile
standardised on dedicated guardrail frameworks and hot-path spend control.

| Feature | Who | PasClaw |
|---|---|---|
| Rail orchestration DSL (input/dialog/retrieval/execution/output rails) | NeMo Guardrails (Colang) [S] | ⚠️ promptware scan + hooks, no rail model [P] |
| LLM-based content classifier against a harm taxonomy | Llama Guard [S] | ❌ |
| Structured-output validation rails | Guardrails AI [S] | ⚠️ JSON repair on tool args only [P] |
| **Per-team / per-agent spend budgets enforced before the call** | LiteLLM ("rate-limit errors before spend accumulates") [S] | ❌ stats are recorded after, never enforced |
| Configurable budget windows + spend alerts | LiteLLM, gateways [S] | ❌ |
| Six routing modes incl. lowest-cost and rate-limit-aware | LiteLLM [S] | ⚠️ auto-router is capability-based only [P] |
| Market-informed model routing | OpenRouter Auto Router (community spend data) [S] | ❌ |
| Guardrails themselves as an attack surface (DoS on rails) | arXiv 2606.14517 [S] | n/a — a reason not to over-build them |

The budget row is the actionable one: PasClaw *counts* every token
(per-session stats, gateway buckets) and *enforces* nothing. A runaway loop
is discovered on the bill. LiteLLM's model — refuse before spend, scoped per
team/agent — is the shape, and the counters already exist.

## 19. Computer use & GUI agents

A production category in 2026, absent from the draft entirely.

| Feature | Who | PasClaw |
|---|---|---|
| Full-desktop control (screen/mouse/keyboard) | Claude computer use — 82.3% OSWorld (Opus 4.7) [S] | ❌ |
| Web-only operator agents | OpenAI Operator, Gemini/Mariner [S] | ❌ |
| Open-source browser automation | browser-use (89.1% WebVoyager), Stagehand, Browser MCP [S] | ❌ |
| Accessibility-tree snapshots as the agent's view (vs pixels) | playwright-mcp [S] | ⚠️ PasClaw *implements* the a11y tree side (Studio, #557) but consumes nothing |

The last row is an odd near-miss worth naming: the field's preferred
browser-automation representation is the accessibility tree, and PasClaw
just built accessibility-tree *emission* for its own GUI — the same
structure from the other side. A browser tool consuming a11y snapshots
would reuse concepts already in the codebase.

## 20. Managed agent runtimes

| Feature | Who | PasClaw |
|---|---|---|
| Durable agent objects: state, sessions, scheduling, WebSockets | Cloudflare Agents SDK [S] | ⚠️ gateway + sessions + cron, self-hosted [P] |
| Per-agent computer: durable FS + routed isolate/container backends | @cloudflare/computer (Aug 2026 preview) [S] | ❌ |
| Managed cross-framework runtime with shared context | Bedrock AgentCore (Strands/LangGraph/ADK/Claude SDK interop) [S] | ❌ |
| Platform-managed sandbox for autonomous code delivery | Claude Managed Agents on Cloudflare [S] | ❌ |

PasClaw is deliberately the opposite of these — self-hosted, no platform —
but the *durable agent object* pattern (state + schedule + inbox as one
addressable thing) is portable and close to what gateway sessions + cron
already approximate.

## 21. Inter-agent protocols, revisited

The 4-row section was thin because the first passes found names, not
adoption. The picture now has numbers:

| Fact | Source |
|---|---|
| A2A donated to the Linux Foundation, June 2025 | [S] |
| 150+ organisations, production use, first year | [S] |
| v1.0 stable with signed Agent Cards, April 2026 | [S] |
| SDKs in 5 languages; 22K+ GitHub stars | [S] |
| GA inside Copilot Studio, Azure AI Foundry, Bedrock AgentCore | [S] |
| AP2 (payments) layered on top | [S] |

PasClaw interop today is MCP (both directions) plus an OpenAI-compatible
API. A2A at v1.0 with three clouds GA is past the wait-and-see line for
any harness that wants its agents addressable from outside — an Agent Card
over the existing gateway would be the minimal entry.

## 22. Agent identity & authorization

Zero coverage in four passes; meanwhile the field has a draft IETF standard.

| Feature | Who | PasClaw |
|---|---|---|
| OAuth 2.1 + PKCE as the MCP authorization model | MCP spec, Stytch/Aembit guides [S] | ❌ gateway token is a single shared secret [P] |
| **On-behalf-of delegation**: `requested_actor` / `actor_token` binding agent identity into the token exchange | IETF draft-oauth-ai-agents-on-behalf-of [S] | ❌ |
| Two-identity model: user identity + agent identity, both in every call | [S] | ❌ no agent identity at all |
| Short-lived scoped tokens + policy engine in front of tools | [S] | ⚠️ sandbox policy exists; tokens do not expire [P] |
| Immutable audit log of delegated actions | [S] | ⚠️ sessions record actions, mutable files [P] |

For a single-operator personal agent this is mostly future-proofing — but
the moment PasClaw's gateway serves more than one human (it already has
multi-workspace), "which agent did this as which user" has no answer.

## 23. Prompt-injection defense, beyond scanning

The draft credited PasClaw's promptware scanner; the field's frontier is
architectural rather than detectional.

| Approach | Who | PasClaw |
|---|---|---|
| Output scanning against known patterns | the baseline [S] | ✅ promptware scan — this IS the baseline [P] |
| Spotlighting: mark/transform untrusted input so the model can tell it apart | [S] | ❌ tool results enter context undifferentiated |
| Dual-LLM: privileged planner never sees untrusted data; quarantined reader has no tool access | [S] | ❌ |
| **CaMeL**: compile the user's intent to a checked program; data flows validated per step (67% of benchmark injections blocked) | DeepMind [S] | ❌ |
| Inference-time scaling as defense | SecInfer [S] | ❌ |

Honest placement: PasClaw's scanner fired correctly twice during this
survey, and it is still the weakest tier of a ladder the field has been
climbing for two years. Spotlighting is the cheapest rung up — a wrapper on
tool-result messages, no architecture change.

## 24. The apply layer: fast-edit models

A category the survey missed entirely because it sits *below* the agent: a
second, small model whose only job is merging the big model's sloppy edit
into the real file.

| Feature | Who | PasClaw |
|---|---|---|
| Dedicated 7B merge model, "existing code" markers in, merged file out | Morph Fast Apply — 10,500 tok/s, ~98% accuracy [S] | ❌ |
| Trained on lazy-edit → merged-file pairs across languages | Relace Instant Apply, ~96% [S] | ❌ |
| Speculative decoding tuned on the model's own output | Relace, Blazedit [S] | n/a (provider-side) |
| Deterministic merge + scoped inputs beating fragile patching | Morph's stated thesis [S] | ⚠️ this is exactly the `edit_file`-vs-rewrite tension measured earlier in this repo |

The relevance is direct: this session previously measured PasClaw's model
choosing whole-file rewrites over `edit_file` because exact-match patching
is fragile. The field's answer is not better prompts — it is a second model
that makes sloppy edits safe to apply. For a self-hosted harness the
portable idea is the *contract* (lazy edit in, merged file out, verify by
re-parse), which a deterministic merger could implement without any model.

Two candidates from this pass found no sourced coverage and stay recalled
leads only: prompt versioning as a harness feature, and RL from agent
trajectories. They are deliberately NOT tabled.

## 25. Session persistence, branching & time travel

| Feature | Who | PasClaw |
|---|---|---|
| Thread-scoped checkpoints of full graph state | LangGraph checkpointers [S] | ✅ checkpoints + sessions [P] |
| Pluggable checkpoint backends | LangGraph (e.g. Couchbase) [S] | ⚠️ file-based only [P] |
| **Time travel: rewind to a node, alter context, fork the path** | LangGraph [S] | ⚠️ checkpoint restore/redo rewinds; no fork-into-branch [P] |
| Fault tolerance via resume-from-checkpoint | LangGraph [S] | ✅ `--session` resume [P] |
| Multi-user shared session state | thread ids over a shared store [S] | ⚠️ shared store exists; no per-user identity (see §22) |

RBAC and org-level config found no direct sourcing this pass either — two
passes running. Either it lives in closed enterprise tiers the public docs
do not describe, or the field genuinely has not standardised it. Recorded
as an open question, not a table row.

## 26. Realtime & voice agents

Out of coding scope, in "every agent feature everywhere" scope. A production
category with its own engineering vocabulary.

| Feature | Who | PasClaw |
|---|---|---|
| Speech pipeline abstraction (STT → LLM → TTS, or speech-to-speech) | LiveKit Agents 1.x [S] | ❌ |
| Voice activity detection vs semantic turn detection (model predicts turn end; +100–200 ms) | AssemblyAI, LiveKit, OpenAI [S] | ❌ |
| Barge-in: stop talking, discard in-flight audio (`response.cancel` server-side) | OpenAI Realtime [S] | ❌ |
| Measured interruption engineering (−87% mid-thought cuts for +20 ms) | [S] | ❌ |
| Multi-agent handoffs inside a live call | LiveKit [S] | ❌ |
| Native MCP tools in the voice loop | LiveKit 1.5 [S] | n/a — MCP yes, voice no |

No PasClaw column argument here: this is a genuinely different substrate
(WebRTC media servers). The transferable observation is that voice forced
the field to solve *interruption* rigorously — the text-agent equivalent
(steering mid-loop) is something PasClaw already has and most text
harnesses do not.

## 27. Retrieval as a harness feature

| Feature | Who | PasClaw |
|---|---|---|
| Hybrid sparse+dense with rank fusion (RRF) | the 2026 default stack [S] | ⚠️ FTS + vectors exist; fusion is ad hoc [P] |
| **Cross-encoder reranking of top-k** | Cohere/Voyage/BGE — +15–30% on RAGAS [S] | ✅ ships a bge-reranker (`Memory.Rerank.Serve`, XLM-R tokenizer, byte-exact-vs-HF tests) [P] |
| Graph layer for entities/relations (GraphRAG) | Microsoft GraphRAG, MIT-licensed [S] | ❌ |
| Agent chooses retrieval strategy per query | agentic RAG (GraphRAG vs VectorRAG selection) [S] | ❌ one path |
| **Retrieval inside the loop** (re-query, rewrite, stop early) | Self-RAG, FLARE [S] | ✅ `memory_search`/`kb_search` are loop tools, not a front-end stage [P] |
| Retrieve-50 → rerank-5 pipeline shape | production default [S] | ⚠️ components exist, pipeline not assembled [P] |

The rerank row is a correction in PasClaw's favour: five passes of this
survey nearly missed that it ships a real cross-encoder reranker with
byte-exactness tests against HuggingFace. The gap is not the parts — it is
that the parts are not composed into the retrieve→fuse→rerank pipeline the
field treats as the default.

---

## Where PasClaw leads

Three things I did not find anywhere in the surveyed material:

1. **Failure mining into the prompt.** `learn --write-scars` extracts
   recurring tool failures; SCARS.md feeds them back. Others persist memory;
   none observed learn from their own mistakes automatically.
2. **A discipline mode.** `--mode improve` changes *method*, not capability —
   measure, change one thing, re-measure.
3. **Screen-reader accessibility in a native GUI.**

## Gaps worth closing, in evidence order

1. **Symbol/AST code index.** The field's densest cluster of work — Token
   Savior, codebase-memory-mcp, semble, zerolang, dirac — all attacking
   whole-file reads, reporting 77–98% token reductions [S]. PasClaw reads
   whole files. Navigating a 25 k-line unit cost real turns during this
   survey.
2. **Browser automation.** Two MCP servers and several agents have it [S];
   any web-facing task is out of reach.
3. **IDE extension.** Where most users actually are.
4. **Four-level tool risk annotations.** MCP already defines
   `readOnlyHint` / `destructiveHint` / `idempotentHint` / `openWorldHint`
   [S]; PasClaw has two categories. This is a small change with immediate
   value for per-call approvals.
5. **Per-call approvals.** Depends on 4.
6. **Spend budgets enforced before the call.** Every token is already
   counted; nothing refuses. LiteLLM's refuse-before-spend model is the
   shape, and the counters exist [S].
7. **Per-agent worktree isolation.** Structural attribution/conflict/rollback
   for multi-agent work [S]; `spawn*` currently shares one workspace and has
   all three problems.
8. **Memory tiering with a retrieval token budget.** The pieces exist
   (MEMORY.md, facts, vectors); the field ships them as a measured system
   [S] and PasClaw has never measured a retrieval.
9. **Trajectory evaluation.** PasClaw already emits OTel spans covering every
   model and tool call — the exact structure trajectory evaluators consume
   [S] — and never scores them. The data is collected and thrown away; this
   is the cheapest eval capability available to it.
10. **Published benchmark numbers.** Competitors lead with them; the harness
   exists here but is unmerged — and per the exploitation finding above, it
   needs oracles that verify more than their own exit code before any number
   from it is worth publishing.

## The gap nobody has

**No surveyed system reports what its verification did not cover.**

Every tool answers *did this succeed*. None answers *what did I not look at*.
The field's own literature says agents "mark a task complete without
verifying the outcome" [S] and blames 65% of enterprise failures on harness
defects [S] — but the proposed remedies are all more verification, never
honest reporting of verification's *scope*.

Four bugs found while building toward this document had exactly that shape:
a linter reporting green on a file it never opened; `make all` reporting
success without rebuilding; a shell command succeeding in the wrong
directory; and an error message confidently recommending a fix that could
not work.

It is also the cheapest item here, because it needs no model change:
`0 findings in 1 file; 3 files not examined` is a one-line diff anywhere a
tool already knows its own scope.

---

## Method & limits

- One live web search, one deep fetch of a curated catalogue, ten READMEs.
- **[K]** rows are unverified recall — leads, not findings.
- **[S]** rows reflect what a source *claims*; no capability was tested.
- Reported token-reduction figures (77%, 98%, 60–95%) are vendor/author
  claims carried through from the source, not measurements.

## Sources

- [Awesome Harness Engineering](https://github.com/ai-boost/awesome-harness-engineering)
- [AI Agent Evaluation (2026): Metrics, Frameworks, and Production Failures](https://www.morphllm.com/ai-agent-evaluation)
- [AI Agent Benchmarks 2026 — SWE-bench, WebArena, AgentBench, Terminal-Bench, OSWorld, Tau-Bench](https://benchmarkingagents.com/agent-benchmarks/)
- [AJ-Bench: Benchmarking Agent-as-a-Judge](https://arxiv.org/pdf/2604.18240)
- [Top AI Coding Agents and Development Platforms in 2026](https://www.marktechpost.com/2026/06/10/ai-coding-agents-development-platforms-2026/)
- [Mem0 vs Letta (MemGPT): AI Agent Memory Compared (2026)](https://vectorize.io/articles/mem0-vs-letta)
- [Mem0 vs Zep vs Letta: AI Agent Memory in 2026](https://datapace.ai/blog/ai-agent-memory-tools-2026)
- [Copilot Coding Agent vs Codex vs Cursor Background Agents: 2026 Workflow Map](https://ralphable.com/blog/copilot-coding-agent-vs-codex-vs-cursor-background-agents-2026)
- [Agent Observability: LangSmith, Langfuse, Arize 2026](https://www.digitalapplied.com/blog/agent-observability-platforms-langsmith-langfuse-arize-2026)
- [How to sandbox AI agents in 2026: MicroVMs, gVisor & isolation strategies](https://northflank.com/blog/how-to-sandbox-ai-agents)
- [Guardrails AI vs NeMo Guardrails: Complete Comparison 2026](https://is4.ai/blog/our-blog-1/guardrails-ai-vs-nemo-guardrails-comparison-2026-352)
- [LiteLLM Budget Routing](https://docs.litellm.ai/docs/proxy/provider_budget_routing)
- [OpenRouter: How Model Routing Works](https://openrouter.ai/blog/insights/model-routing/)
- [Computer Use Agents 2026: Claude vs OpenAI vs Gemini](https://www.digitalapplied.com/blog/computer-use-agents-2026-claude-openai-gemini-matrix)
- [Cloudflare Agents runtime docs](https://developers.cloudflare.com/agents/)
- [A2A Protocol Surpasses 150 Organizations (Linux Foundation)](https://www.linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year)
- [Bedrock AgentCore A2A support](https://aws.amazon.com/blogs/machine-learning/introducing-agent-to-agent-protocol-support-in-amazon-bedrock-agentcore-runtime/)
- [Agent-to-agent OAuth guide (Stytch)](https://stytch.com/blog/agent-to-agent-oauth-guide/)
- [IETF draft: OAuth for AI agents on behalf of users](https://www.ietf.org/archive/id/draft-oauth-ai-agents-on-behalf-of-user-02.txt)
- [CaMeL: mitigating prompt injection (Simon Willison)](https://simonwillison.net/2025/Apr/11/camel/)
- [Dual LLM & Capability Security (CaMeL)](https://agentic-design.ai/patterns/security-privacy/dual-llm-capability-security)
- [Morph Fast Apply](https://www.morphllm.com/fast-apply-model)
- [LangGraph persistence & time travel](https://docs.langchain.com/oss/python/langgraph/persistence)
- [LiveKit: turn detection and interruption handling](https://livekit.com/blog/turn-detection-and-interruption-handling)
- [Hybrid Search: BM25, Vector & Reranking Reference 2026](https://www.digitalapplied.com/blog/hybrid-search-bm25-vector-reranking-reference-2026)
- [RAG in Production 2026: GraphRAG, Hybrid Retrieval, and Evals](https://ailearningguides.com/rag-production-patterns-2026/)
- [Relace: A Year of Fast Apply](https://relace.ai/blog/relace-apply-3)
- [AI Agent Sandboxing in 2026: Docker, E2B, Firecracker, gVisor, Modal & Daytona Compared](https://amux.io/guides/ai-agent-sandboxing/)
- [Cursor vs Claude Code vs Windsurf (Now Devin Desktop) 2026](https://www.shareuhack.com/en/posts/cursor-vs-claude-code-vs-windsurf-2026)
- [Harness Engineering: Making AI Coding Agents Work in 2026](https://www.faros.ai/blog/harness-engineering)
- [Best AI Coding Agents in 2026](https://www.firecrawl.dev/blog/best-ai-coding-agents)
- [All Agent Harnesses: The Live Comparison](https://htek.dev/articles/all-agent-harnesses-live-comparison)
- [Top 10 AI Agent Harnesses — Open vs Closed](https://explainx.ai/blog/top-10-open-closed-source-agent-harnesses-2026)
- Project READMEs: OpenHands, Aider, Cline, Goose, Continue, SWE-agent,
  Codex CLI, LangGraph, CrewAI, modelcontextprotocol/servers
