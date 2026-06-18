# LOCOMO memory-retrieval bench

Self-contained harness that measures PasClaw's `memory_search` retrieval quality on [LOCOMO](https://github.com/snap-stanford/locomo)-shaped multi-session conversations. Designed to run **without a real LLM provider** — the harness only exercises the retrieval layer, which is the upper bound on agent performance.

## What it measures

For each question in a persona, the harness:

1. Writes the persona's multi-session conversations into `$PASCLAW_HOME/workspace/memory/` as date-stamped markdown files.
2. Calls PasClaw's `memory_search` (via the `memory_recall` helper here) for the question text.
3. Scores the top-K results two ways:
   - **Snippet-level**: did the gold answer (or any alias) appear in the FTS5-bounded snippet text? This is what the model sees in *one* `memory_search` call.
   - **Doc-level**: did it appear anywhere in the full document body of the top-K hits' source files? This is what an agent reaches with a follow-up `fs_read` on the cited path.

Both numbers tell different parts of the story. Snippet-level is the agent's *first* round of retrieval; doc-level is what an iterating agent can recover.

## What it does NOT measure

- Agent-loop reasoning, multi-step tool use, hallucination on missing facts.
- The model's ability to *synthesize* across multiple retrieved chunks (multi-hop questions get credit for retrieving each constituent fact separately, not for the synthesis).

Those need a full LLM in the loop. For PasClaw the natural extension is to run [`pasclaw build`](../../docs/commands.md#build) with a real provider and tally end-to-end answer accuracy.

## Running

### Smoke test (bundled fixture, no LOCOMO download)

```sh
# Compile the Pascal helper once.  Uses PasClaw's standard
# FPCFLAGS so unit paths resolve.
make build/pasclaw      # ensures dependencies are already built

fpc -MDelphi -Sh -O2 -Xs -XX \
    $(...the same -Fu list `make` uses; see the build commands the
    Makefile prints for the full set...) \
    -FEbench/locomo -FUbuild/lib \
    bench/locomo/memory_recall.pas

# Run.
python3 bench/locomo/run.py
```

Output goes to `bench/locomo/results/<persona_id>.json` plus a console summary.

### Against real LOCOMO

```sh
git clone https://github.com/snap-stanford/locomo /tmp/locomo
# write a small adapter that maps LOCOMO's session_summary + conversation
# fields into the shape this harness expects -- see load_persona() in
# run.py.  Then:
python3 bench/locomo/run.py --persona /tmp/locomo/data/locomo10.json
```

The shape adapter is a few dozen lines because LOCOMO's raw format names the same content differently ("date" → "session_date", "messages" → "dialogue", etc.). Not bundled here because the dataset license has its own download terms.

## Persona JSON schema

```json
{
  "persona_id": "string -- unique label, used as the tempdir + results filename",
  "sessions": [
    {
      "session_id": "string",
      "date": "YYYY-MM-DD",
      "messages": [
        {"role": "user" | "assistant", "content": "string"}
      ]
    }
  ],
  "questions": [
    {
      "id": "string",
      "category": "single-hop" | "multi-hop" | "temporal" | "adversarial" | "open-domain",
      "question": "string",
      "answer": "string -- the gold answer",
      "answer_aliases": ["string", ...],   // optional; defaults to [answer]
      "source_session": "string or comma-separated"   // optional, for debugging
    }
  ]
}
```

A `score_question` hit is **any case-insensitive substring match** of any alias against the snippet/doc body. Substring is generous — it gives credit for noisy snippets that contain the answer somewhere — and matches what most LOCOMO baselines do.

## Ablation knobs

Set `vector_search_enabled` in the seeded `config.json` (see `write_config()` in `run.py`) to compare:

- **FTS5-only**: `vector_search_enabled: false`. PasClaw skips the hybrid path; just BM25.
- **Hybrid (default)**: `vector_search_enabled: true` *and* the vector runtime is on disk (`pasclaw memory provision`). Hybrid FTS5 + sqlite-vec via RRF.

For a quick FTS-only run, edit `write_config()` to flip the flag and re-run.

## Files

```
bench/locomo/
├── README.md            you're here
├── fixture/
│   └── alice_synthetic.json    1 persona, 3 sessions, 8 questions
├── memory_recall.pas    Pascal CLI helper -- calls PasClaw.Memory.Index.Search
├── memory_recall        compiled binary (gitignored)
├── run.py               main harness -- load persona, recall per Q, score
└── results/             per-persona JSON dumps (gitignored)
```

## Honest caveats

- **The bundled fixture is hand-rolled**, not a LOCOMO sample. It exists to smoke-test the harness end-to-end without the dataset download. Real LOCOMO has 10+ personas with 35+ sessions each; expect lower numbers (more distractor content per persona).
- **No automatic consolidation.** PasClaw treats memory as operator-curated notebooks (`MEMORY.md`, daily notes). The bench writes raw conversation content directly; an "automatic episode → semantic fact" pass like [Mem0](https://github.com/mem0ai/mem0) or the [Elastic agent-memory architecture](https://www.elastic.co/search-labs/blog/agent-memory-elasticsearch) would change these numbers materially. The harness can serve as the regression target if/when such a pass lands in PasClaw.
- **The adversarial category is currently a single question** in the fixture and isn't representative. Real LOCOMO has dozens; that's where supersession + confidence scoring would show up in the numbers (or their absence in PasClaw's current memory model).
