# Studio UI: professional upgrade plan

Written from live-use feedback ("buttons like + Session.. not professional")
plus a control-by-control audit of `studio/MasterDetail.pas`. Items marked ✅
are implemented in the PR that introduced this document; unmarked items are
the follow-on work, ordered inside each section.

## Principles (the rules every tab is judged against)

1. **The content is the interface.** Chrome (toolbars, headers, borders,
   captions) must be quieter than the data it frames. One accent color, used
   only for the primary action and live state — never for headers or borders
   at rest.
2. **One verb, one face.** A verb appears as the same icon everywhere
   (trash = remove, plus = create/attach, arrows = undo/redo). No verb
   appears as text in one tab and an icon in another.
3. **Buttons carry hints, always.** Icon-only is allowed exactly because
   hover explains it.
4. **No boxes around boxes.** A scroll area inside a bordered panel inside a
   bordered tab reads as scaffolding. Borders mark *interactive* or
   *elevated* surfaces only (inputs, popovers, user bubble, composer).
5. **State controls look like state, actions look like actions.** A toggle
   (`mode: build`, `Params +`) must not be styled identically to a
   destructive action (`Delete`).

## Global (affects every tab)

- ✅ Icon set halved in visual weight (8px glyphs in 34px buttons), flat
  faces — no border/gradient, hover wash + focus ring.
- ✅ Sun/moon icon for the theme toggle; `+ Session`, `Attach` → plus icon;
  attachment-clear trash appears only while attachments exist.
- ✅ Session list titles: regular weight, chrome ink.
- ✅ Light style: softened the two harsh strokes (`popupbuttonstyle`,
  `colorbuttonstyle` `$FF525252` → soft grey; combo popup `$FFACACAC`).
- ✅ Section headers de-accented: chrome ink instead of accent blue
  (accent-blue bold headers on 14 tabs was the single loudest global habit).
- ✅ Tab-body outline removed (the `UI_BG`+border chrome rect every endpoint
  tab wraps its whole body in) — same treatment the chat transcript got.
- ✅ Card-list titles (sessions, cron jobs, skills, MCP results…): regular
  weight.
- ✅ Sidebar footer: Delete Session → trash; Import / Export / Import Dir →
  tray and folder icons with hints.
- ✅ Hex viewer pager: First/Prev/Next/Last → chevrons and arrows.
- ✅ Settings: `Config` renamed `Advanced`; ZIP row labelled
  "Workspace backup".
- `Params +` / `Tools +` → disclosure chevron + label, not a button that
  looks like an action.
- `mode: build|plan` → segmented two-state control.
- Empty states: every list shows a one-line muted hint when empty (what this
  is, how to add one) instead of blank space.

## Tab by tab

**Chat** — ✅ measure + gutters, ✅ borderless assistant/scroll, ✅ muted
tool cards, ✅ auto-open newest session. Remaining: transcript-inline
generated-file cards (P2 from the parity doc); streaming status chip in the
composer instead of the status-bar text.

**Sessions sidebar** — ✅ softer titles. Remaining: relative timestamps
("2h ago" instead of ISO); footer row to icons (trash / import / export)
with hints; filter box full-width.

**Memory (Notes/Facts/Setup)** — sub-tab captions are fine; Facts list
needs the same card treatment as sessions; `Forget` → trash icon; Setup
form labels right-aligned at a fixed gutter so fields align.

**KB** — `Sources`, `Upload`, `Search`: Search is an icon already; keep
Upload as text+icon (it's the tab's primary action). Result cards: title
line + muted snippet, click-through already wired.

**Files** — `Hex`, `Download`, `Preview`, `Up`, `Go`: Up → arrow icon,
Go merges into the path edit (Enter submits, hidden button). Breadcrumb
instead of the raw path edit when not focused.

**MCP (Server/Tool/Result)** — `Save Server`, `New`, `Invoke`: fine as
text (infrequent, consequential). ✅ Result tab already renders MCP
`content[]` as typed cards (`McpRenderInvokeResult`) — the parity-doc gap
was stale.

**Cron** — `New`/`Save`/`Delete` already iconed where safe. The
detail memo's "New Cron Job ====" ASCII header → real section header.

**Skills** — `Load Catalog`, `Install Selected`, `Approve`: keep text
(consequential). Pending-approval rows need a warning tint, not plain cards.

**Workflow** — ✅ light canvas, ✅ AV fixes, ✅ Run/Pause icons. Remaining:
inspector form field alignment (labels right-aligned on a gutter); node
palette as icon chips with hints instead of combo + Add.

**Vault** — `Show`/`Hide` → eye toggle on the row, `X` → trash icon.

**Logs** — `Tail`/`Stop`/`Clear` are correct as text+icon (state verbs);
replace the O(n²) append with a ring buffer (perf, not looks).

**Stats** — ✅ idle-refresh discipline. Remaining: summary cards to a
fixed 3-up grid; token tables right-align numerics.

**Checkpoints** — `First/Last/Undo/Redo` arrows exist; group them as one
segmented cluster; detail memo → structured rows.

**Relay** — ✅ idle-refresh discipline. `Worker Token`, `Connect`,
`Disconnect`: Connect/Disconnect keep text (consequential); token row gets
the eye toggle treatment.

**Settings** — flip the frame: Gateway connection first, then Providers,
then Config (raw JSON demoted to an "Advanced" sub-tab); `Save ZIP` /
`Import ZIP` / `Onboard` get one "Workspace" section header.

## Sequencing

1. ✅ Global chrome quieting (this PR).
2. Sidebar footer icons + relative timestamps + empty states (small, visible).
3. Settings reframe + Files breadcrumb + segmented mode control.
4. Per-tab forms alignment pass (Memory setup, Workflow inspector).
5. Parity leftovers folded in where they intersect (MCP content[], file
   cards in transcript).
