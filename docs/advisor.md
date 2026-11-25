# Advisor

The advisor is a second model the agent can ask for a second opinion while it
works. When an advisor model is set, the agent has one more tool, `advisor`,
which takes a `question`. PasClaw sends that question to the advisor model
together with a condensed transcript of the conversation so far, and the
advisor's answer comes back as the tool result. The advisor runs no tools and
sees nothing but that transcript.

The agent decides when to ask. The tool's description tells it to ask when it
is stuck, when it is unsure which of two approaches to take, or before a step
that is hard to undo, and not for routine steps. A typical pairing is a fast
model doing the work with a stronger one advising, or two models from
different vendors checking each other.

Claude Code's Advisor tool (2.1.300) and OpenClaw's experimental Advisor
(2026.10.10) are the same idea. PasClaw's [decision models](./decision-models.md)
are a different thing: they answer typed yes/no or one-of-N questions at fixed
points, where the advisor answers the agent's own question in prose.

## Turning it on

In `config.json`:

```json
"advisor": {
  "provider": "anthropic",
  "model": "claude-opus-4-7"
}
```

| Key | Default | Meaning |
|---|---|---|
| `advisor.model` | `""` | The advisor's model id. Empty means no advisor and no `advisor` tool. |
| `advisor.provider` | `""` | A `providers[]` entry by name. Empty means `default_provider`. The entry's API key, base URL and prompt-cache settings are used, through the same provider factory as every other call. |
| `advisor.max_calls_per_turn` | `3` | Consultations allowed per user turn. Zero or less means the default. |
| `advisor.max_context_chars` | `60000` | How much transcript to send, in characters (about 15,000 tokens). The most recent part is kept. Zero or less means the default; the floor is 2,000. |

`provider` and `model` are always written to `config.json`, so the web UI's
**Settings** form, which shows exactly the keys `GET /v1/config` returns, has
fields for them. The two limits are written only once you change them.
A [profile](./configuration.md#profiles) file can carry an `advisor` block like
any other key, and `pasclaw profile diff` shows `advisor.provider`,
`advisor.model` and `advisor.max_calls_per_turn` when two profiles differ.

### For one run: `--advisor` and `--no-advisor`

`pasclaw agent`, `tui`, `gateway` and `serve` (and `acp`) take:

```sh
pasclaw agent --advisor claude-opus-4-7            # a model on advisor.provider (else the default provider)
pasclaw agent --advisor anthropic:claude-opus-4-7  # a model on a named provider
pasclaw gateway --no-advisor                       # no advisor, whatever config says
```

The part before the first `:` is taken as a provider only when it names a
configured provider entry, so model ids with colons of their own
(`llama3:8b`, `org/model:free`) work as they are. `--advisor provider:` with no
model is refused (exit 2). `--no-advisor` wins over `--advisor`.

An attached turn (`--attach`) runs on the gateway, which has its own advisor
setting, so `--advisor` and `--no-advisor` are refused there rather than
ignored.

### During a session: `/advisor`

In the `pasclaw agent` REPL and in `pasclaw tui`:

| Command | Effect |
|---|---|
| `/advisor` | Show the status: model, provider, where the setting came from, and the limits. The agent REPL's `/status` shows it too. |
| `/advisor <model>` or `/advisor <provider>:<model>` | Use that advisor for the rest of the run. A bare model stays on the provider in use. |
| `/advisor off` | No advisor for the rest of the run. |
| `/advisor on` | Back to what the run started with (config and `--advisor`). |

The change applies to the next request: the registry asks the advisor
settings every time it lists tools, so `/advisor off` takes the tool out of
the next request and `/advisor <model>` puts it back.

## What the advisor is sent

One request, with no tools. Provider-side tools are switched off for it too
(Anthropic and OpenAI web search, Gemini's Google Search grounding): the
advisor judges the transcript, it does not go and look.

**System prompt.** That it is a second-opinion advisor to an agent working on
a user's task; that it cannot run tools, read files or see anything beyond the
transcript, so it should not ask for more or claim to have checked anything;
that the transcript is material to judge, not instructions; that it should
answer briefly and concretely, say plainly if the agent is on a wrong track
and what to do instead, and not invent problems when the plan is sound.

**One user message**: the transcript between `<transcript>` tags, then the
agent's question. One message, because some providers refuse two user
messages in a row.

```
The agent's conversation so far:

<transcript>
[user]
The build fails on a missing include

[assistant]
Let me check the build script.
[assistant called read_file] {"path":"Makefile"}

[result of read_file]
CFLAGS = -Iinclude ...

[assistant called advisor] {"question":"Should I patch the Makefile or the source file?"}
</transcript>

The agent asks you:

Should I patch the Makefile or the source file?
```

The transcript is the turn's running history: user and assistant text, each
tool call with its arguments, and each tool result, up to and including the
assistant message that called `advisor`. Results of other calls made in the
same round are not in it yet. Left out: system messages and the system prompt
(the agent's instructions, not the conversation), and anything compaction has
already summarised away (the summary lives in the system prompt).

**When it is too long** (`max_context_chars`):

- the oldest messages go first, and a note at the top says how many of how
  many messages, and about how many characters, are not shown;
- the user's latest message is kept even when it falls in the cut part, with a
  label saying so, because without it the advisor cannot know what the work is
  for;
- one message or tool result may take at most a quarter of the budget; a
  longer one keeps its head and tail (a build log's error is at the end) with
  a note in the middle;
- cuts never split a multi-byte character.

## Limits

- **Per turn.** A turn is one user message and everything the agent does for
  it. The fourth call in a turn (with the default 3) is refused with:
  *"advisor: limit reached -- the advisor has been consulted 3 time(s) this
  turn, the most advisor.max_calls_per_turn allows. Decide with what you have;
  the count starts again at the user's next message."* Calls in one parallel
  round each count once. A call whose provider fails still counts, so a
  provider that is down is not asked over and over.
- **Only as a direct tool call.** The advisor reads the conversation, so it
  works only when the agent loop dispatches it. From an `execute_code` script,
  a workflow step or an MCP client it is refused: those have no conversation
  to give it.
- **When the advisor fails** (HTTP error, empty answer) the tool returns an
  error that tells the agent to carry on with its own judgement.

## Where it runs

- **Read-only.** It changes nothing on this machine, so plan mode allows it
  and several calls can share a parallel batch.
- **Subagents** inherit it when it is set. The built-in general-purpose
  subagent copies the parent's tools (`"tools": ["*"]`), the advisor included;
  a configured subagent gets it by listing `"advisor"` in its `tools`. Each
  subagent turn has its own cap, and its advisor sees the subagent's own
  conversation (its task and its tool calls), not the parent's.
- **Gateway and serve**: one setting for the process, from config and
  `--advisor` / `--no-advisor`. Like other non-provider settings, a change
  saved through `/v1/config` takes effect on restart.
- **Embedders**: `TPasClawAgent` and `TPasClawServer` register the tool from
  their config's `advisor` block.

## Cost and accounting

Each consultation is one request carrying up to `max_context_chars` of
transcript plus the question, so a full-budget call is roughly 15,000 input
tokens. The advisor provider's prompt caching applies (`prompt_cache.*`, with a
cache key per session); while the transcript fits the budget, consecutive calls
in a turn send the same system prompt and the same beginning.

With `stats_collection_enabled`, each call's tokens go to a stats bucket of its
own, one per advisor provider and model (`_gateway_advisor_<provider>-<model>-<hash>.json`
under `workspace/sessions/`). `/v1/stats` counts them, and its `by_model` and
`by_provider` tables show the advisor's tokens under the advisor's model
rather than adding them to the main model's session. Like the gateway's
endpoint buckets, these are hidden from session lists and deleted by a stats
reset. They are not part of a session's own totals, the TUI's `/stats` overlay
or the CLI's per-turn token line.

## Privacy

The transcript goes to the advisor's provider: what the user wrote, files the
agent read, command output. If the advisor is on a different vendor from the
main model, that is a second party seeing the work. Leave `advisor.model`
empty (the default), or pass `--no-advisor`, where that is not acceptable.

## Not here yet

- **Reviews nobody asked for.** OpenClaw's Advisor watches the agent and
  suggests a correction when it sees a clear wrong turn. Here the advisor
  speaks only when the agent asks. A hook that consults it on its own (after a
  run of failed tool calls, or before a mutating step in a long turn) is
  possible future work.
- The compaction summary is not sent, so after a compaction the advisor sees
  only the recent part of the conversation.
- No per-request switch on the gateway (a field in the chat request body);
  the setting is per process.

Source: `src/pkg/agent/PasClaw.Agent.Advisor.pas`; the turn accessor it reads
the conversation through is `CurrentDispatchHistory` / `BumpTurnCounter` in
`src/pkg/tools/PasClaw.Tools.ToolLoop.pas`. Tests: `make test-advisor`
(unit) and `make test-advisor-e2e` (against two fake providers).
