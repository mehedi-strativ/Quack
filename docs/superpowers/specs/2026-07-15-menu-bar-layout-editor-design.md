# Menu Bar Layout Editor — design

**Date:** 2026-07-15
**Status:** Approved (brainstorm)

## Summary

Replace the `Arrange…` button in the Menu Bar settings tab with an Ice-style
drag editor: two labelled rows — **Shown** and **Hidden** — of real-glyph tiles
that the user drags between (to hide/show) and reorders within. A drop is
executed by synthesizing ⌘-drag(s) of the real menu-bar items on the live bar,
because macOS exposes no API to set a third-party status item's position.

This is a UI on top of Quack's existing single-boundary hidden-bar architecture
(one divider status item: items left of it are hidden, items right are shown).

## Goals

- Show every menu-bar item as a real-glyph preview tile, grouped Shown / Hidden.
- Drag a tile between sections to hide/show it.
- Reorder a tile within a section (true per-item reorder, Ice-style).
- Keep the existing hover-reveal panel, condition-reveal, and display-policy
  behavior unchanged.

## Non-goals (YAGNI)

- Always-Hidden third section (would need a second divider item).
- Palette / spacers / menu-bar-item groups.
- Editing on non-notched "show all" displays where nothing is hidden.

## Architecture

### Data model & glyph capture

- Reuse `MenuBarAXScanner.scanAll(menuBarBandY:)` — already returns all items
  sorted left→right with live frames.
- Classify each item by the divider's on-screen X: `frame.minX < dividerMinX`
  → Hidden, else → Shown. (Same rule `warmAndCollapse` uses today.)
- Extend `MenuBarItemImageCache` capture to cover **all** on-screen items, not
  just the hidden set, so both rows render real glyphs. Capture runs while the
  bar is expanded (`control.expand()`), so every item — including currently
  hidden ones — is on-screen and capturable. No Screen Recording grant → fall
  back to `appIcon`, and show the existing permission banner.

### Drag UI — `MenuBarLayoutEditor` (SwiftUI)

- Two rows, each a `dropDestination`; tiles are `draggable` carrying the AX
  item `id` (`"pid:index"`).
- Supports move-between-sections and reorder-within-section.
- Rendered inside `HiddenBarSection` in `SettingsView.swift`, replacing the
  Arrange button + its hint text.
- On appear (and on a manual Refresh), the editor asks the service to
  expand → scan → capture → collapse, then publishes the current layout so
  tiles are fresh.
- While the editor is visible, hover-reveal is suppressed (reuse the
  `isArranging` gate) so the real bar staying expanded during edits doesn't
  fight the panel.

### Drop execution

On drop, compute the **desired** ordered list of item ids plus the desired
boundary (index where Hidden ends / Shown begins), diff against the **current**
`(order, boundaryIndex)`, and produce a plan of drag operations:

- **Reorder op** — an item changed position among the real items: synth-⌘-drag
  that real item from its live midpoint to the target X, computed from the live
  frames of its new neighbors.
- **Boundary op** — an item crossed the Hidden/Shown split without needing a
  reorder: synth-⌘-drag Quack's own **divider** item to the new split X.

A single drop emits at most one reorder op plus one boundary op. Execution:

1. `control.expand()` so all frames are live and every item is on-screen.
2. Run the ops sequentially via `StatusItemDragger` (⌘-down at source midpoint,
   stepped mouse-moves to target X, ⌘-up), off the main actor.
3. Re-scan to confirm the achieved order; if it diverges from desired, log and
   leave the achieved state (no infinite retry).
4. Re-capture glyphs, collapse, publish the new layout to the editor.

### `StatusItemDragger`

Thin executor around the synth-⌘-drag primitive. Mirrors the existing
`SynthClick` off-main pattern:

```
static func drag(from: CGPoint, toX: CGFloat, y: CGFloat, steps: Int)
```

Posts `⌘` flags with `.leftMouseDown` / `.leftMouseDragged` × steps /
`.leftMouseUp`. Runs on `DispatchQueue.global(qos: .userInitiated)`. No CGEvent
tap is created, so the CLAUDE.md tap-freeze rule does not apply; AX reads and
synth posting stay off the main actor as elsewhere in the module.

### Testable core — `MenuBarLayoutPlan` (QuackKit)

Pure function, unit-tested like `TrackpadSwipe`:

```
struct DragOp { enum Kind { case reorderItem(id: String); case moveDivider }
                let kind: Kind; let targetIndex: Int }

func plan(currentOrder: [String], currentBoundary: Int,
          desiredOrder: [String], desiredBoundary: Int) -> [DragOp]
```

- `currentOrder` / `desiredOrder`: item ids left→right (divider excluded).
- `boundary`: count of items that are Hidden (0…n).
- Returns the minimal op list. The X-coordinate math and synth posting live in
  the Quack-side executor; the planner is coordinate-free and deterministic.

## Milestone 1 — mechanism spike (de-risk, build first)

Before the full UI, prove macOS honors a synth-⌘-drag of a **third-party**
status item:

1. Expand the bar, scan, pick one shown third-party item.
2. Synth-⌘-drag it left by one slot; re-scan.
3. Assert its `minX` decreased (order changed).

Outcome branches:

- **Works** → build the full real-item reorder as designed.
- **Fails** → **fallback model**: divider-only. Dragging a tile between sections
  still works (executed by moving Quack's own divider — reliable, we own it),
  but within-section reorder is disabled and those tiles render non-reorderable
  (subtle "reorder unavailable on this macOS" note). The UI is otherwise
  identical. The planner still runs; only `reorderItem` ops are dropped.

The spike is a temporary debug entry point (a button behind the existing
Status/diagnostics section, or a `#if DEBUG` hook) that logs the before/after
`minX`. Removed or gated once the outcome is known.

## Safety

- No CGEvent tap is created by this feature — only synthesized events are
  posted — so the "taps must run off the main thread or freeze the Mac" rule is
  not triggered. Existing taps are untouched.
- All AX scanning and synth posting run off the main actor, matching the module.
- Re-scan after every drop; never loop-retry a diverging result (avoids a
  runaway drag storm).

## Files

New:
- `Sources/QuackKit/MenuBar/MenuBarLayoutPlan.swift`
- `Tests/QuackKitTests/MenuBarLayoutPlanTests.swift`
- `Sources/Quack/MenuBar/HiddenBar/MenuBarLayoutEditor.swift`
- `Sources/Quack/MenuBar/HiddenBar/StatusItemDragger.swift`

Changed:
- `Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift` — expose all-items
  layout, capture-all, `executePlan`, editor-visible gate.
- `Sources/Quack/MenuBar/HiddenBar/MenuBarItemImageCache.swift` — capture all
  on-screen items.
- `Sources/Quack/Settings/SettingsView.swift` — `HiddenBarSection` renders the
  editor in place of the Arrange button.
- `Sources/Quack/AppEnvironment.swift` — publish the layout, forward editor
  actions.

## Testing

- Unit: `MenuBarLayoutPlanTests` — reorder-only, boundary-only, combined,
  no-op, and edge (empty section, move to end) cases.
- Manual: install via `./Scripts/install.sh`; run the spike; then verify drag
  between/within sections against the live bar and the hover panel.
