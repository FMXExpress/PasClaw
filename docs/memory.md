# Memory

PasClaw's memory subsystem is an operator-curated SQLite FTS5 + (optional) hybrid vector index over markdown notes under `$PASCLAW_HOME/workspace/memory/`.

## Files

```
workspace/memory/
├── MEMORY.md                 ← the primary note file; injected wholesale into the system prompt
├── SCARS.md                  ← Atlas-style stable §ANCHOR-NAME ids per recurring failure (pasclaw learn --write-scars)
├── 2026-06-12.md             ← per-day daily notes (cron output appended here; agent writes too)
├── 2026-06-13.md
└── fetched-<sanitised>.md    ← URL bodies written by memory_fetch
```

The index is rebuilt lazily on every `memory_search` call (small N, fast rebuild). For large corpora use the [knowledgebase](./knowledgebase.md) instead — its index is explicit-sync, not lazy.

## Tools

| Tool | Purpose |
|---|---|
| `memory_search(query, k?)` | FTS5 BM25 (+ optional hybrid vector) over `workspace/memory/*.md` and `MEMORY.md`. |
| `memory_fetch(url, name?)` | Fetch a URL and write it to `workspace/memory/fetched-<sanitised>.md`. Registered when `web_fetch_enabled: true`. |
| `session_search(query, k?)` | FTS5 over the full text of every saved session under `workspace/sessions/`. Indexed separately at `workspace/sessions/.search.db`. |

## `memory_search`

```
memory_search({"q": "anthropic streaming retry", "k": 5})
```

Returns up to `k` snippets ranked by BM25. With `vector_search_enabled: true` (default) and the local embedding runtime provisioned (`pasclaw memory provision`), ranking switches to hybrid keyword + vector with Reciprocal Rank Fusion. Embeddings are computed locally and never leave the host. Falls back to FTS-only silently when the runtime artifacts aren't yet provisioned under `$PASCLAW_HOME/cache/localvector/`.

The FTS5 query normaliser strips punctuation, lowercases, and folds Unicode whitespace. Same normaliser `session_search` uses, so both tools treat a query identically.

## `memory_fetch`

```
memory_fetch({"url": "https://blog.example.com/post", "name": "example-post"})
```

Fetches the URL through the same SSRF-guarded pipeline `web_fetch` uses, runs the content through HTML→text extraction, and writes it to `workspace/memory/fetched-<name>.md` with a 4-line provenance header:

```
---
source:      https://blog.example.com/post
fetched_at:  2026-06-12T19:34:18Z
name:        example-post
size_bytes:  18432
---

<body...>
```

The body **never enters context**. The next `memory_search` indexes the file via the same lazy-sync path as any other `workspace/memory/*.md`.

### Auto-dedup

A second `memory_fetch` against the same URL within 24h short-circuits the HTTP and returns "already indexed (cached Nh ago)". The check matches the existing cached file's `source:` and `fetched_at:` header lines against the request before any network round-trip — no provider HTTP made.

The 24h window is deliberate: long enough that a normal agent session doesn't keep re-fetching the same URLs, short enough that legitimately stale content gets refreshed when the conversation comes back to it days later.

Inspired by [chopratejas/headroom](https://github.com/chopratejas/headroom)'s cross-agent memory dedup.

## `session_search`

FTS5 keyword search over the full text of every **saved** session, not just the current one. Index at `workspace/sessions/.search.db`, lazily rebuilt (reindexes a session only when its `UpdatedAt` advances). Returns session id + title + snippet + BM25 score with a `pasclaw resume <id>` hint per hit. Gateway stat buckets (`_gateway_v1_chat.json` et al.) are excluded.

Reuses `memory_search`'s FTS query normaliser so both tools treat a query identically.

## System-prompt injection

The system prompt always carries:

1. `MEMORY.md` verbatim (or task-aware slices when `orient_task_aware: true`).
2. Today's daily note (`<today>.md`).
3. Yesterday's daily note (`<yesterday>.md`).
4. `SCARS.md` if present.

Operators wanting **only** task-relevant slices instead of the verbatim files can try it for a single run without editing config:

```sh
pasclaw agent --orient -m "…"      # --no-orient forces it back off
```

or enable it persistently in `config.json`:

```json
"orient_task_aware": true
```

`PasClaw.Agent.Orient` slices each memory file into markdown-heading sections (paragraph blocks for headingless prose), scores each section against the current task by distinct-token overlap (lowercased, stopword-stripped, length ≥ 3 — deliberately lexical: this runs synchronously in prompt assembly and must not depend on the vector stack's provisioned weights), and injects only the sections that score > 0 — original document order preserved, 4 KB budget per file, with an `(N sections elided — memory_search reaches them)` note so the model knows what it isn't seeing.

The task hint is the current user message (one-shot `-m`, each interactive turn, each `/goal` turn). Call sites without a clear task (gateway requests, embedders that don't pass one) keep verbatim whole-file injection regardless of the flag.

Off by default on every profile — the only ways to turn it on are the `--orient` CLI flag (per run) or `orient_task_aware: true` (persistent).

Inspired by [Abbasi-Alain/atlas](https://github.com/Abbasi-Alain/atlas)'s `orient` step.

## Hybrid vector backend

```sh
pasclaw memory provision     # fetch sqlite-vec + ONNX Runtime + MiniLM into cache/localvector/
pasclaw memory status        # show provisioned artifact state
```

Provisioning artifacts land under `$PASCLAW_HOME/cache/localvector/`:

| Artifact | Purpose |
|---|---|
| `sqlite-vec.so` / `.dll` / `.dylib` | SQLite extension for vector search. |
| `onnxruntime.so` / `.dll` / `.dylib` | ONNX Runtime (the embedder runs ONNX). |
| `all-MiniLM-L6-v2.onnx` | MiniLM 384-d embedder. |
| `tokenizer.json` | HF-style tokenizer for MiniLM. |

The embedder runs **locally**. Embeddings never leave the host — no provider API key required for vector search.

Toggle: `vector_search_enabled: true` (default). When provisioning hasn't happened yet, `memory_search` and `kb_search` fall back to FTS5-only silently.

## `pasclaw learn` — failure mining

```sh
pasclaw learn --min 2 --since 30
pasclaw learn --write             # append a dated block to MEMORY.md
pasclaw learn --write-scars       # also emit SCARS.md
```

Walks `$PASCLAW_HOME/workspace/sessions/*.json` and scans every `mrTool` message for failure-shaped lines (`error:`, `command not found`, `permission denied`, `no such file`, non-zero `exit=`, etc.). Each candidate normalises into a clustering signature that strips per-session variability — digit runs ≥ 2 collapse to `<n>`, hex runs ≥ 8 (with at least one letter) to `<hash>`, absolute paths to `<path>` — so "fs_write to /tmp/abc123/foo.pas line 42 failed" and "fs_write to /tmp/xyz789/foo.pas line 17 failed" cluster as one pattern. Patterns above `--min` (default 2 occurrences) print sorted by frequency with the tool that triggered them, a verbatim sample, and a first/last-seen window. `--write` appends a dated `### Patterns observed` block to `workspace/memory/MEMORY.md`. `--write-scars` additionally emits `workspace/memory/SCARS.md` with Atlas-style stable `§ANCHOR-NAME` ids per pattern — citable from commit messages and PRs via `git log --grep "§"`. Operator-edited Root-cause / Do / Do-NOT rationale survives re-runs (only new patterns get fresh anchor blocks). `--since <days>` limits the scan window so old sessions don't keep resurfacing fixes the operator has already applied.

Inspired by [chopratejas/headroom](https://github.com/chopratejas/headroom)'s `headroom learn` (mining + MEMORY.md) and [Abbasi-Alain/atlas](https://github.com/Abbasi-Alain/atlas) (SCARS anchor convention).

## See also

- [Knowledgebase](./knowledgebase.md) for explicit-sync RAG over large corpora.
- [Tools](./tools.md) — full schemas for `memory_search` / `memory_fetch` / `session_search`.
- [Configuration](./configuration.md) for `vector_search_enabled` / `orient_task_aware` / `web_fetch_enabled`.
- [Sessions](./sessions.md) for the session JSON shape `session_search` indexes.
