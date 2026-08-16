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

## Before any of that: is this just an exploit vector?

Largely yes, as first drafted. Three specific things were wrong with the
phasing below, each verified in the source rather than assumed:

**1. It adds remote invocation with no write gate.** `message/send` means
a remote party causes this agent to run a tool loop with whatever tools
are registered — `shell_exec`, `write_file`, `web_fetch`. That is remote
code execution by design. The comparable surface already ships a gate:
MCP-as-server defaults to `MCPAllowWrite := False` and needs an explicit
`--mcp-allow-write` to expose mutating tools. The A2A plan specified no
equivalent. It must mirror that gate, defaulting closed.

**2. It turns prompt injection from fetched content into direct input.**
`PasClaw.Promptware` annotates three chokepoints — tool output, recalled
memory, stored skill descriptions. **Inbound user messages are not one of
them**, because until now "the user" was the operator. An A2A message is
a stranger's text arriving in the *user role*, which is the most trusted
non-system position in the conversation, with no annotation at all.
Untrusted-peer input has to become a fourth chokepoint before the
endpoint exists, not after.

**3. The `contextId` → session mapping I called "highest-leverage" is a
hijack.** `ReqSessionId` is literally
`Trim(RawHeaders['X-PasClaw-Session'])` — caller-chosen, unvalidated,
with no ownership check. That is acceptable when the only caller is the
local operator. Handing the same mechanism to arbitrary remote agents
lets a caller name any session and inherit its history, checkpoints and
persistence. The mapping must namespace per authenticated peer
(`a2a:<peer-id>:<their-context>`), never accept a raw session id from the
wire.

And the backdrop: the gateway ships with **bearer auth off unless a token
is configured** (`gasOpen` — "every route is reachable by any caller").
An Agent Card on such an instance is a public advertisement of an
unauthenticated agent, complete with a skills list. Discovery is not
harmless when the thing being discovered is open.

### What that changes

- **The whole A2A surface is off by default**, behind explicit config —
  not merely undocumented, but absent from routing until enabled.
- **Identity moves from phase 4 to phase 0.** The original ordering
  shipped remote invocation first and authentication last, which is
  backwards. §22 records that PasClaw has no agent identity and one
  shared inbound bearer; that is the gating work, and A2A v1.0's signed
  Agent Cards need it anyway.
- **Phase 1 becomes card-only and opt-in**, which is still useful: a card
  cannot be invoked.
- If the answer to "who is the counterparty?" stays *nobody concrete*,
  the correct outcome is to ship phases 0–1 and stop. An addressable
  agent with no caller is pure attack surface.

The honest summary: A2A is worth planning for and cheap to transport,
but it is the first feature in this codebase that would let a stranger
start a tool loop. Every other remote surface either reads (`/v1/fs`,
gated) or exposes read-only tools by default (MCP). This one executes,
and the plan below is only safe with the reordering above applied.

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

## Phase 1 — Agent Card (discovery only, no execution, opt-in)

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
- **Served only when A2A is explicitly enabled.** On a `gasOpen` instance
  the card would otherwise advertise an unauthenticated agent and its
  skill list to anyone who can reach the port.

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
- Map A2A's `contextId` onto a session id **namespaced by authenticated
  peer** — `a2a:<peer-id>:<their-context>` — so an A2A caller gets the
  continuity, checkpointing, steering and persistence everything else
  gets WITHOUT being able to name an existing session. Never pass a
  caller-supplied string through as a session id: `ReqSessionId` is an
  unvalidated header today, which is safe only because the caller is
  the local operator.
- **Mutating tools gated, closed by default**, mirroring
  `--mcp-allow-write`. A read-only A2A agent is a useful agent; a
  stranger-invokable `shell_exec` is not a default anyone should get.
- **Inbound peer messages annotated as untrusted** — the fourth
  promptware chokepoint. Today the three chokepoints assume "user" means
  the operator.
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

## Phase 4 — signed cards, and only then commerce (identity itself is phase 0)

A2A v1.0's headline is **signed** Agent Cards. Signing is not meaningful
while §22 stands: PasClaw has *"no agent identity at all"* and the inbound
gateway is a single shared bearer token. So:

- Agent identity (§22's two-identity model) is a **prerequisite** for
  signed cards, not a follow-on.
- AP2 layers on A2A and needs identity plus spend mandates; x402 needs a
  wallet. Both are real standards with real governance, and both are
  further from a self-hosted personal agent's core value than anything in
  phases 1–3.

Recommendation: stop after phase 1 unless there is a concrete
counterparty, and do not build phase 2 at all without phase 0.

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
| **0** | **agent identity + per-peer auth (§22); A2A off by default** | — |
| 1 | `/.well-known/agent-card.json` from the skills registry, opt-in | 0 |
| 2 | `message/send`; `contextId` namespaced per peer, never raw; **write gate mirroring `--mcp-allow-write`, closed by default**; inbound messages annotated as untrusted (promptware chokepoint 4) | 0, 1 |
| 3 | `message/stream`, `tasks/get`, `tasks/cancel` | 2 |
| 4 | signed cards → (maybe) AP2/x402 | 0 |

Phase 0 is not preparation for the feature; it is the feature's
precondition. Phases 2+ should not merge while it is outstanding.

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
