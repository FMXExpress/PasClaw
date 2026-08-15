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
6. **Trajectory evaluation.** PasClaw already emits OTel spans covering every
   model and tool call — the exact structure trajectory evaluators consume
   [S] — and never scores them. The data is collected and thrown away; this
   is the cheapest eval capability available to it.
7. **Published benchmark numbers.** Competitors lead with them; the harness
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
- [Cursor vs Claude Code vs Windsurf (Now Devin Desktop) 2026](https://www.shareuhack.com/en/posts/cursor-vs-claude-code-vs-windsurf-2026)
- [Harness Engineering: Making AI Coding Agents Work in 2026](https://www.faros.ai/blog/harness-engineering)
- [Best AI Coding Agents in 2026](https://www.firecrawl.dev/blog/best-ai-coding-agents)
- [All Agent Harnesses: The Live Comparison](https://htek.dev/articles/all-agent-harnesses-live-comparison)
- [Top 10 AI Agent Harnesses — Open vs Closed](https://explainx.ai/blog/top-10-open-closed-source-agent-harnesses-2026)
- Project READMEs: OpenHands, Aider, Cline, Goose, Continue, SWE-agent,
  Codex CLI, LangGraph, CrewAI, modelcontextprotocol/servers
