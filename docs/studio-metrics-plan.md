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
```

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

**Files** — toolbar `ROW_BAR`; hex pager buttons S-token width; the
path edit full-width `H_INPUT`; detail/preview headers via `BuildDetailPane`.

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

**Vault** — rows to `ROW_LIST` with eye/trash at S-width; add form to
`AddFormRow`.

**Logs** — toolbar `ROW_BAR`; body stays a memo (it *is* a log); status
line TXT_CAPTION.

**Stats** — numerals TXT_DISPLAY, labels TXT_CAPTION; summary cards on one
fixed 3-up grid at `ROW_LIST`×1.4; token tables right-align numerics.

**Checkpoints** — pager cluster S-width segment; detail via
`BuildDetailPane` (turn/timestamp/files as rows, not ASCII).

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

1. **Tokens + helpers** (`AddFormRow`, `BuildDetailPane`, gap unification
   6→8). Mechanical; biggest diff, lowest risk.
2. **Settings + Memory Setup + MCP Server** — the three worst forms, all
   pure `AddFormRow` consumers. Visible payoff immediately.
3. **Detail panes** — the 31 `====` views through `BuildDetailPane`
   (Cron, Checkpoints, Files, Skills, Memory Notes, Relay).
4. **Workflow inspectors + generated schema forms.**
5. **Lists/cards rhythm + empty states + Stats/Relay metric cards.**
6. **Sweep**: delete the then-unused ad-hoc constants; census re-run goes in
   the PR description as proof (target: 4 font sizes, 4 gaps, 3 paddings,
   4 row heights).

Not in scope: transcript virtualisation (perf, separate track), web-UI
feature parity (tracked in `studio-parity.md`), dark/light palette (done).
