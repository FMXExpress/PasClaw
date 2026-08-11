# Studio UI: typography, spacing & controls pass — the plan

Successor to `studio-ui-plan.md` (chrome/verbs, largely executed). This pass
is about **metrics**: type, rhythm, alignment, and the controls themselves.
Plan first, execution phased so every step is a small reviewable PR.

## Why (measured, not felt)

A census of `MasterDetail.pas` as of this writing:

| dimension | today | verdict |
|---|---|---|
| body font sizes | 9, 10, 11, 12, 13, 17, 18, 20 — with 11 (22 uses) and 12 (25 uses) mixed arbitrarily | no scale |
| row heights | 22, 24, 26, 28, 30, 32, 34, 36, 38, 40, 44 all used as "a row" | no rhythm |
| padding signatures | 14 distinct 4-tuples | no tokens |
| sibling gaps | 6px (97 uses) **and** 8px (46+32 uses) competing | two grids |
| button widths | 20+ hand-tuned values, 58–104 | caption-by-caption tailoring |
| detail views | 31 ASCII `====`-underlined memos | terminal dressing |
| form rows | 50 TEdits, fixed widths 128–220, no shared label gutter | nothing aligns |

Every number above is a place where two screens disagree for no reason.
The fix is the same one that fixed the colour system: **tokens + one owner**,
not per-site tuning.

## The tokens (phase 0 — everything else consumes these)

```pascal
{ type scale — FOUR sizes, no other Font.Size anywhere }
TXT_CAPTION = 10;    // meta, hints-adjacent, column headers
TXT_BODY    = 11;    // default for everything
TXT_TITLE   = 12;    // emphasized: section headers, active items
TXT_DISPLAY = 18;    // stats numerals only

{ spacing — 4px base grid; the only gaps that exist }
GAP_XS = 4;  GAP_S = 8;  GAP_M = 12;  GAP_L = 16;

{ rhythm — the only heights a row may have }
ROW_BAR   = 36;      // toolbars and action rows
ROW_FORM  = 32;      // label + input rows
ROW_LIST  = 40;      // list items (56 for two-line cards)
H_INPUT   = 28;      // TEdit/TComboBox inside a ROW_FORM

{ padding — three surfaces }
PAD_PANEL : 12,10,12,12   // tab-level panels
PAD_CARD  : 8,6,8,6       // list cards
PAD_BAR   : 8,4,8,4       // toolbars

{ button widths — TEXT buttons only }
BTN_W_S = 64;  BTN_W_M = 88;  BTN_W_L = 104;
```

**ICON_BTN_W (34) is not part of this scale and does not move.** Icon-only
buttons are already sized by `SetIconButton`, and `SetButtonWidth`
deliberately ignores them — that guard is what stopped the layout pass
resetting Params and Tools to text widths. So the width tokens above apply
to buttons that still carry a caption; anywhere a control is icon-only,
34px stands and the correct change is *no change*. Any plan line that reads
"S-token width" for an already-iconified control is wrong: those keep
ICON_BTN_W.

Mechanics: helpers own application (`AddFormRow`, `AddToolbar`,
`SetButtonWidth` already exists) so a new call site *cannot* pick its own
numbers. The 6px-vs-8px war ends: **8 wins** (97 call sites move; sed-able).
Button widths collapse to three tokens (S=64 icon+, M=88, L=104) plus
caption-measured for long captions.

## Shared control upgrades (phase 1)

- **`AddFormRow(label, control)`** — right-aligned label column on a fixed
  110px gutter, `ROW_FORM` height, input at `H_INPUT`. Replaces every ad-hoc
  label+edit pair (≈50 sites). This is what makes forms *look* professional;
  nothing else comes close per line of code changed.
- **`BuildDetailPane`** — title label (TXT_TITLE) + meta line (TXT_CAPTION,
  muted) + body. Replaces the 31 ASCII `====` memo views. Memo stays for
  genuinely long/selectable content.
- **Empty states** — every list gets the sessions-list treatment (one muted
  line: what belongs here, how to add one).

## Tab by tab

**Chat** — already carries the reading measure, tiers, icons. Remaining:
composer buttons to `ROW_BAR` rhythm; Params drop-down panel to
`AddFormRow`; status footer at TXT_CAPTION.

**Sessions drawer** — rows to `ROW_LIST`; header to `ROW_BAR`; search box
`H_INPUT`.

**Memory** — *Notes*: detail pane via `BuildDetailPane`. *Facts*: card list
to `ROW_LIST` + empty state. *Setup*: the poster child for `AddFormRow` —
every field currently free-floats at a different width.

**KB** — toolbar to `ROW_BAR`; results as two-line cards (title TXT_BODY,
snippet TXT_CAPTION muted); upload row de-crowded (Sources/Upload/Search on
one bar with tokens).

**Files** — toolbar `ROW_BAR`; the path edit full-width `H_INPUT`;
detail/preview headers via `BuildDetailPane`. The hex pager
(First/Prev/Next/Last) is already icon-only at ICON_BTN_W and stays there —
`SetButtonWidth` ignores iconified buttons by design, so assigning a text
width token would be a silent no-op. Its only change is the row rhythm.

**MCP** — *Server*: `AddFormRow` (name/url/enabled). *Tool*: schema form
rows are generated — point the generator at `AddFormRow` so generated and
hand-built forms are indistinguishable. *Result*: cards to `ROW_LIST`
metrics, `====` memos out.

**Cron** — editor form to `AddFormRow` (id/spec/skill/args/channel);
detail memo to `BuildDetailPane`; list cards `ROW_LIST`.

**Skills** — catalog/install lists to card tokens; pending-approval rows
keep the warning tint; `====` memos out.

**Workflow** — inspector to `AddFormRow` (currently the worst offender:
five inspectors × free-floated fields); node/edge lists to `ROW_LIST`;
run-inputs memo keeps memo (it's real JSON editing).

**Vault** — rows to `ROW_LIST`, eye/trash stay at ICON_BTN_W (icon-only);
add form to `AddFormRow`.

**Logs** — toolbar `ROW_BAR`; body stays a memo (it *is* a log); status
line TXT_CAPTION.

**Stats** — numerals TXT_DISPLAY, labels TXT_CAPTION; summary cards on one
fixed 3-up grid at `ROW_LIST`×1.4; token tables right-align numerics.

**Checkpoints** — pager cluster keeps ICON_BTN_W (icon-only), grouped as
one segment; detail via `BuildDetailPane` (turn/timestamp/files as rows,
not ASCII).

**Relay** — status metrics same card treatment as Stats; worker form to
`AddFormRow`; token row gets the eye toggle.

**Settings** — the named offender, so concretely:
- *Gateway*: one `AddFormRow` card — URL / token(+eye) / Connect on the
  form grid, connection state line under it (TXT_CAPTION). Kill the fixed
  `Height := 104` guess: the card sizes from its rows.
- *Providers*: `AddFormRow` throughout; provider picker `H_INPUT`.
- *Advanced*: raw JSON memo keeps memo, but gains a one-line warning header
  (TXT_CAPTION, muted) instead of sitting unexplained.
- *Workspace backup* row: to `ROW_BAR` with M-width buttons.

## Sequencing (each lands as its own PR, `make lint-studio` gated)

Status: **phase 1 done** (#506), **phase 2 done**. Phases 3-6 not started.

1. ✅ **Tokens + helpers** (`AddFormRow`, `BuildDetailPane`, gap unification
   6→8). Mechanical; biggest diff, lowest risk.
2. **Settings + Memory Setup + MCP Server** — the three worst forms, all
   pure `AddFormRow` consumers. Visible payoff immediately.
   - ✅ Settings/Gateway: two labelled rows on the grid, panel sized from
     them, the `Height := 104` guess gone.
   - ✅ Memory Setup: the checkbox/two combos/edit that shared one row at
     four hand-picked widths are four labelled rows.
   - ✅ MCP Server: name/command/args/state on the grid, actions on their
     own bar below them.
3. **Detail panes** — the 31 `====` views through `BuildDetailPane`
   (Cron, Checkpoints, Files, Skills, Memory Notes, Relay).
4. **Workflow inspectors + generated schema forms.**
5. **Lists/cards rhythm + empty states + Stats/Relay metric cards.**
6. **Sweep**: delete the then-unused ad-hoc constants; census re-run goes in
   the PR description as proof (target: 4 font sizes, 4 gaps, 3 paddings,
   4 row heights).

## Found while executing (not in the original census)

**Backgrounds were laid out as content.** `AddPanelChrome` gave its rect
`Align.Client`, so a "background" competed with its own siblings for space:
it took what was left after the Top-aligned rows and drew its outline around
THAT. On Settings/Gateway the visible result was an empty rounded box under
the form rather than a border around it — reported as *"why is that box
there?"*. `Contents` fills the parent's content rect and takes part in no
such negotiation. 42 `AddPanelChrome` call sites plus 11 direct rects were
affected, so stray outlines elsewhere in the app very likely have the same
cause.

**Static chrome never re-themes.** `StyleChromeRect` resolves its colours at
CALL time, and `RestyleCoreControls` walks labels and controls but not
`TRectangle` brushes — so anything built once during `BuildInterface` keeps
the palette that was current then, which is always the DARK one (the theme
preference is read afterwards, in `LoadLocalSettings`). The header rule hit
this and is fixed by being held as a field and repainted from `ApplyTheme`.
Other static chrome very likely has the same defect. A general fix wants a
registry of themeable rects, but must not hold pointers to the ones that are
rebuilt per render (chat cards, schema forms) or it will dangle — worth its
own PR rather than a rushed hook here.

**A separator was drawn as a border.** The top bar carried a full rectangle
outline; three edges hug the window frame and the fourth reads as a stray
dark rule under the title. Rules BETWEEN things want their own token
(`UI_SEPARATOR`), softer than the border AROUND something.

Not in scope: transcript virtualisation (perf, separate track), web-UI
feature parity (tracked in `studio-parity.md`), dark/light palette (done).
