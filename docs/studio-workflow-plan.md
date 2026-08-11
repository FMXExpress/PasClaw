# Workflow tab: from painted diagram to workflow builder — the plan

The operator's verdict was "kind of janky", with two direct asks: outputs
should land somewhere defined (a workspace subdirectory), and the grid
should be a virtual space where everything — including INPUT/OUTPUT — can
be moved and panned. This plan grounds those in what the established
node-graph tools do, then sequences the work.

## What the field does (survey)

| pattern | n8n | ComfyUI | Node-RED | Langflow / Flowise | Blueprints / Blender | adopt? |
|---|---|---|---|---|---|---|
| infinite pannable canvas | ✅ drag empty space | ✅ | ✅ | ✅ | ✅ | **P1** |
| zoom to cursor + fit-view | ✅ | ✅ | ✅ | ✅ | ✅ | **P5** (fit first, zoom after) |
| IN/OUT are *nodes*, not chrome | triggers are nodes | Primitive/Output nodes | inject/debug nodes | Input/Output components | parameters are nodes | **P1** |
| positions/view saved in the doc | ✅ | ✅ (embeds in PNG!) | ✅ | ✅ | ✅ | **P1** |
| output to a per-workflow disk folder | via nodes | ✅ `output/` + filename prefix | via nodes | ✅ | n/a | **P2** |
| port-to-port wire drag, bezier wires | ✅ | ✅ | ✅ | ✅ | ✅ | **P3** |
| per-node run status badges + output preview | ✅ executions | ✅ previews | ✅ debug | ✅ | n/a | **P4** |
| searchable add-node palette | ✅ tab/⊕ | ✅ double-click | ✅ sidebar | ✅ sidebar | ✅ right-click | **P4** |
| snap-to-grid, box-select, dup, del, undo | ✅ | ✅ | ✅ | partial | ✅ | **P5** |
| minimap | ✅ | ✅ | – | ✅ | – | defer |
| subgraphs/groups | ✅ | ✅ | ✅ | – | ✅ functions | defer |

The unanimous items are the canvas model (infinite, panned, saved) and
IN/OUT as first-class movable things — exactly the two asks. ComfyUI is
the reference for the output contract: every run writes into an output
directory, subfoldered/prefixed per workflow, so results are *files you
can find*, not text in a results pane.

## Where PasClaw is today (measured, not felt)

- The canvas is a `TPaintBox` painted immediate-mode — actually the RIGHT
  substrate for this: a view transform is two additions per point.
- ~~Positions are not persisted~~ **Correction found while building**: node
  x/y DO round-trip through the spec (both clients, same convention). What
  was missing was pan, the IO positions, and any space beyond the viewport.
- Dragging clamps to the paintbox: `Min(Box.Width - 116, X)` — there is no
  space beyond the viewport, which is why the graph feels boxed in.
- INPUT/OUTPUT are painted chrome at fixed rects, not movable objects.
- Edges are created by clicking a source port then a target node —
  workable, but no drag feedback wire until after the first click.
- Node size is a constant 116×42; wires are straight lines.
- The engine (`PasClaw.Workflow`) already has typed `Outputs` with
  templates and `output_errors` — the *data* contract is ahead of the UI.

## The plan

### P1 — the virtual canvas (the direct ask) — ✅ built (Studio + web)
- **View transform**: `FWorkflowPan: TPointF` (zoom deferred; the transform
  is written zoom-ready as `screen = logical + pan`). ALL painting and ALL
  hit-testing go through two helpers — `WfToScreen`/`WfToLogical` — so a
  point can never be transformed in one place and not the other. That
  one-owner rule is non-negotiable: a pan bug is otherwise guaranteed.
- **Pan**: dragging empty canvas pans; the drag-clamp dies (positions are
  logical and unbounded). Grid lines paint offset by `pan mod 24` so the
  space visibly moves.
- **IN/OUT become movable**: their positions live in the same positions
  dictionary under reserved ids (`__input__`, `__output__`), default to
  the current left/right placements, drag like nodes, and derived wires
  follow them. They stay non-deletable (they are derived from the spec's
  inputs/outputs, as today).
- **Persistence**: positions + pan saved *in the workflow JSON* under a
  `ui` object. **Correction (Codex P1)**: the store does NOT round-trip
  unknown fields — `SaveWorkflow` rebuilds the document from the typed
  spec, so the engine now carries `ui` (and `output_dir`) explicitly as an
  opaque field on `TWorkflowSpec`, pinned by a save/load round-trip test.
  Every surveyed tool saves layout in the document; losing layout on
  reload is the single most janky-feeling defect the tab has.
- Fit-view button on the workflow toolbar (cheap, and the escape hatch for
  "I panned my graph off into space").

### P2 — the output contract (the direct ask, ComfyUI-style) — ✅ built (engine + both clients)
- `output_dir` field on the spec (engine: parse + carry; unknown-field
  round-trip means old files stay valid). Default when absent:
  `workflows/<workflow-id>/` under the workspace.
- After a run resolves the declared outputs, the ENGINE writes them into
  that folder: `output.json` always (the typed name→value object), plus
  one file per output whose resolved value is textual
  (`<name>.txt` / `.md` by sniff). URL-valued outputs are recorded in
  `output.json` as-is — downloading remote artifacts is a follow-up, not
  smuggled in here.
- Runs are subfoldered by timestamp (`.../20260811T093000/`) so a re-run
  never clobbers the last one — ComfyUI's filename-prefix lesson.
- Studio: an "Output folder" form row (grid, like the rest); run results
  panel links the folder so it opens in the Files tab.

### P3 — wires that feel physical
- Bezier wires (cubic, horizontal tangents) instead of straight lines —
  every surveyed tool; it is most of why their graphs read as graphs.
- Drag from an output port shows the wire following the cursor from
  mousedown (today the feedback wire only exists after a click); drop on a
  node/port connects, drop on space cancels.
- Hover highlights the wire + its endpoints; Del deletes the selected wire
  (selection exists today).

### P4 — the node experience
- Per-node status after a run: a small badge (ok / failed / skipped) from
  the run result, and the first line of the node's output as a preview
  under the node title — n8n/ComfyUI's single best affordance for
  debugging without leaving the canvas.
- Searchable add-node palette on double-click at the cursor (creates the
  node AT that spot), replacing tool-combo + Add as the primary path (the
  form remains for editing).

### P5 — canvas conveniences
- Snap-to-grid on drop (24px, the existing grid); box-select; Ctrl+D
  duplicate; Del deletes selection (nodes today only via list); fit-view
  keyboard (F). Zoom-to-cursor lands here once the P1 transform has soaked.

### deferred, deliberately
Minimap and subgraphs are real but heavy; neither unblocks daily use.
Undo on the canvas waits for the command-pattern refactor it deserves
rather than a half-undo that lies.

## Sequencing note
P1 and P2 are independent (canvas vs engine) and can land as separate PRs
in either order. P3 depends on P1's transform. P4/P5 stack on P3. Every PR
gates on `make lint-studio`; engine changes in P2 get a unit test on the
output-writing seam (path traversal from a hostile `output_dir` must be
refused — the store already guards ids the same way).
