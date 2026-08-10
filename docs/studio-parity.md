# PasClaw Studio (FMX) ↔ Web UI parity

Code-level evaluation of `studio/MasterDetail.pas` against `src/pkg/gateway/webui.html`,
with the exact gateway contracts the client must honor. Updated as parity work lands.

## Verified contracts (ground truth from the gateway source)

**Tool side-channel (SSE).** During `/v1/chat/completions` streaming the gateway
emits SSE *comment* lines:

```
: pasclaw-tool {"kind":"call","name":"<tool>","args":<argsJSON>}
: pasclaw-tool {"kind":"result","name":"<tool>","result":"...","error":"..."}
```

(`TSSEStreamer.NoteToolCall/NoteToolResult` → `WriteComment('pasclaw-tool ' + …)`).
Studio's `StreamChat` parser handles this correctly, including comment-only
events (`data:`-less blocks) and CRLF normalization — the structure is right;
what remains is the live soak test.

**tool_details persistence.** `PUT /v1/sessions/<id>` accepts a top-level
`tool_details` (bare JSON array, index-aligned to the flattened user/assistant
turn sequence); `GET` returns it. Studio writes it (`AddPair('tool_details', …)`)
and reads it on load — shape matches the store (`Session.Store` treats it as an
opaque blob).

**Steering.** `POST /v1/steer` body `{"text":"…"}` + `X-PasClaw-Session` header
(or `"session"` field). Queued server-side; folded into the running turn at the
next loop iteration as `[user steering]: …`. Bearer-gated.

**Import/export.** `POST /v1/sessions/import` (body = raw export file; server
auto-detects ChatGPT / Claude Code / Pi / OpenClaw / PasClaw; returns
`{imported, ids}`); `GET /v1/sessions/<id>/export[?format=md]` returns a
download. OpenCode is CLI-only (directory import).

## Endpoint coverage diff (grep-verified)

Studio already calls every `/v1/*` route the web UI does **except**, before this
pass: `/v1/steer`, `/v1/sessions/import`, `/v1/sessions/<id>/export`.
All three are added by the first parity PR (see below).

## Persistence mapping (web localStorage → studio INI)

| Web (localStorage)        | Studio (INI)                  | Status |
|---------------------------|-------------------------------|--------|
| `pasclaw.gw_token.v1`     | `[gateway] token` (+ url)     | ✅ |
| `pasclaw.model.v1`        | `[chat] model`                | ✅ |
| `pasclaw.mode.v1`         | `[chat] mode`                 | ✅ |
| `pasclaw.params.v1`       | `[chat] temperature/max_tokens/system` + per-session `SaveChatParams` | ✅ |
| `pasclaw.theme.v1`        | `[ui] dark_style`             | ✅ |
| `pasclaw.tooldetails.v1` (cards on/off) | —               | ❌ add `[chat] tool_details_visible` |
| `pasclaw.presets.v1` (prompt presets)   | `LoadPromptPresets` exists — verify save side | ⚠️ |
| (sidebar width — web: none)| `[sidebar] width/visible`    | studio-only, fine |

## Gap matrix (operator's assessment, annotated)

| Area | Finding | Priority |
|------|---------|----------|
| Chat side-channel | Parser structurally correct (see contracts). Needs the live soak: long tool args crossing socket chunk boundaries, and reload-after-save alignment when system/tool turns are present (web aligns to the *flattened* user/assistant view — mirror exactly or cards shift by one). | **P1 — live test** |
| Mid-turn steering | Was absent entirely (Send during streaming = abort only). **Added**: non-empty composer mid-turn → `/v1/steer`; empty → abort (Stop) as before. | **fixed in PR 1** |
| Session import/export | Absent. **Added**: Import/Export buttons in the sessions sidebar → the gateway endpoints above. | **fixed in PR 1** |
| Chat markdown | Web renders tables/links/nested lists/inline+block code (`PasClaw.Markdown` renderer server-side + webui CSS). FMX rendering simpler. Needs an FMX markdown pass — biggest visual gap in chat. | P1 |
| Generated-file affordances | Web chat inlines produced-file cards w/ download; FMX has Files-tab discovery but not transcript-integrated cards. | P2 |
| Workflow editor | FMX has graph editing/inspectors/run. Web extras to port: derived INPUT/OUTPUT boxes with dashed wires, drag-node-output→output-field template authoring, loop editor (`max`/`until`/feedback), reserved IO gutter so nodes can't spawn under boxes. | P2 |
| Relay/WebLLM | Web runs a WebLLM worker in-tab with a relay-scoped token (never the main token). FMX equivalent = LocalPal-backed worker; the **scoped-token rule must carry over** (worker gets `/v1/relay/*` only). | P2 |
| MCP tab | CRUD + invoke exist; gaps are nested-schema form handling and result presentation. Web renders results as MCP `content[]` text blocks — mirror that. | P3 |
| Files/KB/Memory | Panels exist; wire click-throughs (memory/kb hit → file preview) like web's result cards. | P3 |
| Cron/Stats/Checkpoints/Logs | Native versions exist; polish + consistent auto-refresh cadence (web refreshes stats on tab focus + 30s). | P3 |
| Visual QA | Full tab-by-tab pass on PasclawDark.style + PasclawLight.style after IDE save/reload. | P3 |

## Button icons

`ApplyButtonIcon` assigns `TButton.StyleLookup` using names from the RAD Studio
DocWiki table *Using Styled and Colored Buttons on Target Platforms* — only
rows that have both a Windows column and an `IconTintColor` entry, since the
tint column is what separates a lookup that carries a glyph from one that is
just a coloured button shape.

A **custom style book replaces the platform style outright**: it does not
inherit from it, so a lookup the book does not define falls back to that book's
own `buttonstyle`, not to the platform glyph. PasclawDark/PasclawLight
therefore have to define those lookups themselves —
`scripts/gen-studio-icons.py` clones each book's `buttonstyle` per icon name
and swaps the TGlyph placeholder for a TPath glyph, so the icon buttons keep
the theme's exact background, hover/press animation and focus glow. Run
`python3 scripts/gen-studio-icons.py` after editing either style file, or
`--check` to verify they are current.

`StyleLookupExists` is the backstop: it refuses to blank a caption for a
lookup the active book does not define, so a style without icon resources
degrades to plain text instead of blank buttons.

## Live parity test script (run against a real gateway)

1. sessions: create → chat → reload → delete (verify tool cards survive reload)
2. stream a multi-tool turn; confirm `: pasclaw-tool` cards render live and args
   > 8 KB don't tear across chunks
3. mid-turn: type + Send → gateway log shows `steer queued`; reply reflects it
4. Send with empty composer mid-turn → abort still works
5. import a ChatGPT `conversations.json` and a Claude Code `.jsonl`; verify
   list refresh + transcripts; export a session and re-import it
6. skills install/remove, MCP invoke, workflow create/run/save/load
7. relay connect; light/dark switch; restart app → all INI settings restored
