# Knowledgebase (RAG)

Index reference documents — manuals, books, source trees — so the agent can retrieve them while answering ("Big RAG" style, but operator-curated).

## Commands

```sh
pasclaw kb add ~/docs/delphi-book.md ~/projects/mylib/   # files and/or dirs
pasclaw kb list
pasclaw kb search "constructor constraints in generics"
pasclaw kb sync                                         # after documents change
pasclaw kb status
pasclaw kb remove ~/projects/mylib/
```

## Storage

Documents are indexed **in place** — never copied — into `$PASCLAW_HOME/workspace/kb.db`. Chunked by paragraph (~1.6 KB target). The vector sidecar lives at `workspace/kb.db.vec`.

## Supported types

- Markdown (`.md`, `.markdown`).
- Plain text (`.txt`).
- HTML (`.html`, `.htm`) — tags stripped.
- Source code: `.pas`, `.dpr`, `.dpk`, `.inc`, `.c`, `.h`, `.cpp`, `.py`, `.rs`, `.go`, `.js`, `.ts`, `.java`, `.cs`, `.rb`, `.lua`, `.sql`, `.sh`, `.bat`, `.ps1`, `.json`, `.yaml`, `.yml`, `.toml`, `.xml`.
- **PDF (`.pdf`)** — text extracted via the built-in parser (`PasClaw.KB.PDF`), no external tool required. Handles `/FlateDecode` streams and per-font `/ToUnicode` CMaps (Type0/CID + simple fonts). Image-only scans without an embedded text layer are skipped with a "no extractable text" warning.

File-size cap: **30 MB**. Larger files are skipped with a log line.

Binary files (other than PDF) are detected by NUL-byte sniff (same heuristic as `fs_grep`) and skipped silently.

## Tools (auto-registered)

Once at least one source is registered, two read-only agent tools appear automatically (and not before, so the model never sees an empty KB):

| Tool | Purpose |
|------|---------|
| `kb_search(query, k)` | Search the corpus; returns `path#cN` citations + snippets + scores. |
| `kb_get(path, chunk, window)` | Expand a citation into full chunk text ± `window` neighbouring chunks. |

Citation format `path#cN` means "chunk N of path". The model navigates via `kb_get(path, N, window=2)` to read N-2 through N+2.

## Ranking

**Default**: SQLite FTS5 BM25.

**Hybrid**: when the local embedding runtime is provisioned (`pasclaw memory provision` — the same sqlite-vec + ONNX Runtime + MiniLM artifacts `memory_search` uses, gated by the same `vector_search_enabled` flag), the KB automatically upgrades to **hybrid keyword + semantic** ranking with Reciprocal Rank Fusion. Embeddings are computed locally and never leave the host.

The vector sidecar (`workspace/kb.db.vec`) is rebuilt by `kb sync` when documents change.

## When to sync

Unlike `memory_search`, the KB does **not** re-index on every query — `kb sync` is the explicit refresh, keeping `kb_search` fast on large corpora.

Run `kb sync` after:

- Editing a file under a registered directory.
- Adding files inside a registered directory.
- A schema change in a new PasClaw release.

`kb sync` is incremental — only changed-since-last-sync files get re-chunked.

## Comparison with `memory_search`

| | `memory_search` | `kb_search` |
|---|---|---|
| Source | `workspace/memory/*.md` + `MEMORY.md` | Operator-registered files / directories. |
| Scope | "What did we decide earlier" | "What do my reference documents say" |
| Re-index | On every query (lazy). | Explicit `kb sync`. |
| Hybrid vector | Yes (when `vector_search_enabled`). | Yes (when provisioned). |
| Auto-registration | Always. | Only when at least one source is registered. |

Conversation memory and the knowledgebase are deliberately separate. Keep `memory_search` for the agent's own notes (handoffs, decisions, scars) and `kb_search` for external reference material (books, vendor docs, code you don't write).

## `kb status` output

```
sources:           3
files:             127
chunks:           4823
vector backend:    hybrid (sqlite-vec + MiniLM)
db:                /home/me/.pasclaw/workspace/kb.db (8.4 MB)
vector sidecar:    /home/me/.pasclaw/workspace/kb.db.vec (12.1 MB)
last sync:         2026-06-12 19:34:18
```

## Removing

```sh
pasclaw kb remove ~/projects/mylib/    # un-register; chunks deleted on next sync
pasclaw kb sync                         # actually delete chunks
```

`pasclaw kb remove` is cheap (drops the source registration). Actual chunk deletion happens on the next `kb sync`. To wipe everything: `rm workspace/kb.db workspace/kb.db.vec && pasclaw kb add ...` from scratch.

## See also

- [Memory](./memory.md) for the related `memory_search` / `memory_fetch` tools and the vector provisioning step.
- [Tools](./tools.md) for `kb_search` / `kb_get` schemas.
- [Commands](./commands.md#kb) for the full `pasclaw kb` flag set.
