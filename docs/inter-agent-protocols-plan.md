# Supporting the inter-agent protocols the survey found missing

`docs/agent-features.md` §9 and §21 record what PasClaw does not speak.
This is a plan to close that, in the order the evidence supports rather
than the order the list happens to be written in.

## What the survey actually says we lack

| Protocol | Status | Survey evidence |
|---|---|---|
| **A2A** (JSON-RPC + Agent Card discovery) | ❌ | v1.0 stable with signed Agent Cards (Apr 2026); Linux Foundation since Jun 2025; 150+ orgs in production; SDKs in 5 languages, 22K+ stars; **GA in Copilot Studio, Azure AI Foundry, Bedrock AgentCore** |
| **AG-UI** (agent→UI event streaming) | ⚠️ | PasClaw has its own SSE, not the standard |
| **Agentic Resource Discovery** | ❌ | named, thin sourcing |
| **AP2 / UCP**, **x402**, **ACP** | ❌ | commerce; x402 under LF governance with Visa/Mastercard/Amex/Stripe/AWS/Google aboard |
| Agent-to-agent messaging | ❌ | solved in-family by TinyClaw's file queue |

Today PasClaw's interop is **MCP in both directions plus an
OpenAI-compatible API**. The survey's own conclusion: *"A2A at v1.0 with
three clouds GA is past the wait-and-see line for any harness that wants
its agents addressable from outside — an Agent Card over the existing
gateway would be the minimal entry."*

## The argument for doing A2A first, and mostly only A2A

Three reasons, in descending strength:

1. **It is the only one with adoption numbers.** Everything else in the
   list is either a name (Agentic Resource Discovery), a variant of
   something we already do (AG-UI vs our SSE), or commerce infrastructure
   for a use case a personal agent may never want.
2. **The transport already exists.** A2A is JSON-RPC 2.0 over HTTP. The
   gateway already serves JSON-RPC for MCP at `/mcp` and `/v1/mcp/rpc`,
   already has session plumbing, already streams SSE, and already has a
   bearer-token middleware. This is a new surface on existing pipes, not
   a new subsystem.
3. **It is the missing direction.** MCP makes PasClaw a *consumer* of
   tools and a *provider* of tools. Neither makes a PasClaw instance
   **addressable as an agent** by another agent. That is the actual gap,
   and it is what "150+ orgs, three clouds GA" is buying.

AP2 is explicitly layered on A2A, so A2A is also the prerequisite for the
commerce row if that is ever wanted.

## Phase 1 — Agent Card (discovery only, no execution)

The smallest thing that makes PasClaw visible to an A2A client.

- Serve `GET /.well-known/agent-card.json` (there is **no** `.well-known`
  route in the gateway today — verified, zero matches).
- Card contents: name, description, version, service endpoint URL,
  capabilities (streaming yes; push-notifications no), default input/output
  modes, and a `skills` array.
- **Populate `skills` from the existing skills registry**, not a
  hand-maintained list — PasClaw already loads SKILL.md manifests, and a
  card that drifts from what the agent actually does is worse than no card.
- Auth advertised as the bearer the gateway already enforces.

Ship-alone value: A2A directories and clients can *find* a PasClaw
instance and know what it claims to do. Zero execution risk, because
nothing can be invoked yet.

## Phase 2 — `message/send` (the one method that matters)

A2A's core is a small JSON-RPC surface. Implement the synchronous entry
first:

- `POST /a2a` (or reuse `/v1/a2a/rpc` for symmetry with `/v1/mcp/rpc`),
  dispatching JSON-RPC 2.0.
- `message/send` → run one agent turn and return the result. This maps
  almost exactly onto what `HandleChat` already does: parse a message,
  build a `TToolLoopConfig`, `RunCheckpointedLoop`, return content.
- Map A2A's `contextId` onto PasClaw's **session id**, so an A2A caller
  gets the same continuity, checkpointing, steering and persistence
  everything else gets. This is the single highest-leverage mapping in
  the whole plan — get it right and A2A inherits the entire session
  feature set for free.
- Errors returned as JSON-RPC error objects, reusing the shapes already
  emitted at `Gateway.Server.pas:1465`.

## Phase 3 — tasks, streaming, and cancellation

- `message/stream` over SSE — the streamer already exists
  (`TSSEStreamer`); this is a re-encoding of events we already emit, not
  new machinery.
- `tasks/get`, `tasks/cancel`: PasClaw already has cancel-on-disconnect
  and a session turn lock, so the state is there; it needs an id and a
  lookup.
- Long-running turns map to A2A's task lifecycle
  (`submitted → working → completed/failed`).

## Phase 4 — identity, and only then commerce

A2A v1.0's headline is **signed** Agent Cards. Signing is not meaningful
while §22 stands: PasClaw has *"no agent identity at all"* and the inbound
gateway is a single shared bearer token. So:

- Agent identity (§22's two-identity model) is a **prerequisite** for
  signed cards, not a follow-on.
- AP2 layers on A2A and needs identity plus spend mandates; x402 needs a
  wallet. Both are real standards with real governance, and both are
  further from a self-hosted personal agent's core value than anything in
  phases 1–3.

Recommendation: stop after phase 3 unless there is a concrete counterparty.

## Explicitly not doing

- **AG-UI.** PasClaw's SSE works and the web UI consumes it. Adopting the
  standard is churn unless a third-party UI is actually wanted; the survey
  marks this ⚠️, not ❌, for that reason.
- **Agentic Resource Discovery.** Thin sourcing, no adoption numbers. The
  survey's own retry rule says a lead like this stays a lead.
- **A2A client** (PasClaw calling *other* A2A agents). Worth having
  eventually, but the gap the survey names is being *addressable*, and a
  client without a server is the half nobody asked for. It also duplicates
  what MCP already gives us for tool consumption.

## Sequencing

| Phase | Deliverable | Depends on |
|---|---|---|
| 1 | `/.well-known/agent-card.json` from the skills registry | — |
| 2 | `message/send` over JSON-RPC, `contextId` → session | 1 |
| 3 | `message/stream`, `tasks/get`, `tasks/cancel` | 2 |
| 4 | agent identity → signed cards → (maybe) AP2/x402 | §22 work |

## How we will know it worked

- **Conformance over self-assertion.** The card must validate against the
  published A2A schema, and `message/send` must be driven by a real A2A
  SDK client (5 languages ship one) rather than by curl we wrote to match
  our own implementation. A protocol we only test against ourselves is a
  dialect.
- A turn started over A2A must be visible in `pasclaw sessions`, resumable,
  and steerable — proving the `contextId` → session mapping rather than
  asserting it.
- The survey's §9 row moves from ❌ to ✅ **with a `[P:ran]` mark**, not a
  `[P]` — per the notation change in the verification-scope work, because
  "checked" without depth is what four wrong rows in that document were
  made of.

## What this plan does not establish

That anyone will call us. The adoption numbers are for A2A the standard,
not for demand for a self-hosted Pascal agent on the other end of it. The
honest framing is that phases 1–3 are cheap because the transport already
exists, and cheap-and-standard beats waiting — not that there is a queue
of counterparties today.
