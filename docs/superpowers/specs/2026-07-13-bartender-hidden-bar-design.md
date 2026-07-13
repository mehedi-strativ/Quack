# Bartender-style Hidden Menu Bar — Design

**Date:** 2026-07-13
**Status:** Approved design, pending implementation plan
**Target OS:** macOS 26 (Tahoe), notched MacBook Pro

## Goal

Replace Quack's current notch drop-down "hidden icons" row with a full
Bartender-style hidden menu bar: the user designates which status-bar icons to
hide, they collapse off the visible menu bar, and hovering a chevron control
icon reveals a secondary bar directly under the main menu bar showing the hidden
icons with their real rendered glyphs. Clicking an icon in the secondary bar
opens that app's real menu. Zero icons are ever lost.

Reference product: [Bartender](https://www.macbartender.com/). Reference
open-source implementation: [Ice](https://github.com/jordanbaird/Ice) (MIT),
plus Dozer and Hidden Bar for the resilient manual-arrangement variant.

## Decisions (from brainstorming)

| # | Decision | Choice |
|---|----------|--------|
| Q1 | What the bar holds | User-designated hiding (true Bartender), not just notch-crushed |
| Q2 | Click fidelity | Full fidelity — real app menu opens |
| Q3 | Section model | Two zones: Shown + Hidden |
| Q4 | Reveal trigger | Chevron control icon, hover |
| Q5 | How items get hidden | ⌘-drag arrangement (manual, pure public API) |
| Q6 | Screen Recording permission | Yes, require it (with graceful fallback) |
| Q7 | Existing notch hidden-icons row | Replace it |

### Why manual ⌘-drag, not auto-move

Ice avoids manual arrangement by synthesizing ⌘-drag `CGEvent`s (with private
`CGEventField` window-targeting) to relocate other apps' status items. That path
**broke / went sluggish on macOS 26 (Tahoe)** — Ice issues #679, #711 — and it
is the same CGEvent-injection class that historically froze the Mac in Quack
(see CLAUDE.md). Manual ⌘-drag arrangement (Dozer / Hidden Bar style) is pure
public API, has no event injection, and keeps working across OS updates. Given
Quack targets macOS 26 and carries CGEvent-freeze scars, resilience wins.

## Mechanism overview

Adapted from Ice's proven approach, minus the fragile auto-move.

### Hide: expandable-length divider trick

Menu-bar layout, left → right:

```
[hidden-zone items] [hiddenDivider] [chevron »] [shown-zone items] [system: clock / Control Center]
```

- **`chevron`** — a visible `NSStatusItem` (`»` glyph), always
  `NSStatusItem.variableLength`. The trigger and the boundary between zones.
  Never moves once placed.
- **`hiddenDivider`** — an empty, thin `NSStatusItem` positioned immediately
  left of the chevron. Its length toggles between two states:
  - **Collapsed** = `10_000` pt. Because macOS packs status items right-to-left,
    a 10,000-pt-wide item shoves everything to its left off the **left screen
    edge** (negative X), hiding it.
  - **Expanded** = `NSStatusItem.variableLength` (~narrow). Used only during the
    temp-show click flow, never for passive reveal.

Off-screen-left items sit at negative X but **retain their windows** (they are
not behind the notch, so not unmapped). That keeps them capturable — this is the
key reason the chevron must sit to the right of the notch (see Edge cases).

- **Arrangement**: the user ⌘-drags icons to the left of the chevron to hide
  them, to the right to keep them shown. Position *is* the setting; macOS
  persists it via `NSStatusItem.autosaveName` / preferred-position defaults. No
  per-app config storage needed.

### Reveal: secondary bar renders captured images

Passive reveal does **not** shrink the divider (that would flash the items into
the real bar). The items stay hidden off-screen; the secondary bar renders
**captured bitmap images** of them.

- **`HiddenBarPanel`** — a borderless, non-activating `NSPanel` at window level
  `.mainMenu + 1`, positioned flush under the main menu bar, spanning from the
  chevron leftward. Hosts SwiftUI via `NSHostingView`.
- **Capture** — `CGWindowListCreateImage` per hidden item's window ID (window
  IDs and frames enumerated via CGS, as Ice does). Cached by item identity,
  refreshed on reveal and periodically while revealed. Requires Screen
  Recording; without it capture returns black (fallback below).
- **Trigger** — hover the chevron reveals the panel; moving the pointer into the
  panel keeps it open; leaving hides it after a short grace delay. Clicking the
  chevron pins it open. Hover is detected via the `NSStatusItem` button's
  tracking area and the panel's own mouse events — **no new CGEvent tap**, so the
  CLAUDE.md freeze rules are not triggered.

### Click-forwarding: full fidelity

When the user clicks an icon in the secondary bar:

1. **Temp-show** — set `hiddenDivider.length = variableLength`, so the real item
   snaps back on-screen just left of the chevron (public API).
2. **AXPress** the item via the existing `AXStatusItemScanner.press`. Its real
   menu opens at the now-correct on-screen location.
3. **Re-collapse** — restore `hiddenDivider.length = 10_000` once the opened
   menu dismisses.

The menu drops from the real menu-bar row (top of screen), exactly as
Bartender/Ice behave — the secondary bar is a replica strip plus a launcher, not
a live menu host. Click-forwarding uses AXPress (already proven in Quack, run
off-main as IPC), not fragile CGEvent click synthesis.

## Components / module layout

New module `Sources/Quack/MenuBar/HiddenBar/`:

| File | Responsibility |
|------|----------------|
| `ControlItemManager.swift` | Owns the `chevron` + `hiddenDivider` `NSStatusItem`s; length toggle; autosave position; hover detection on the chevron button. |
| `StatusItemEnumerator.swift` | Enumerates the hidden-zone third-party status items — window IDs, frames, owning pid — via CGS (`CGSGetProcessMenuBarWindowList` and friends). |
| `MenuBarItemImageCache.swift` | Captures each hidden item image via `CGWindowListCreateImage(windowID)`; caches by item identity; scales by `backingScaleFactor`; periodic refresh while revealed. |
| `HiddenBarPanel.swift` | The `NSPanel`, its geometry under the menu bar, and the hover-in/hover-out lifecycle with grace delay + pin-on-click. |
| `HiddenBarView.swift` | SwiftUI replica strip: row of captured images, click targets, permission-missing banner. |
| `HiddenBarService.swift` | Orchestrator: reveal, temp-show → AXPress → re-collapse, menu-dismiss detection, cache warming, permission gating. |

In `Sources/Quack/Permissions/`:

| File | Responsibility |
|------|----------------|
| `ScreenRecordingPermission.swift` | Status check (`CGPreflightScreenCaptureAccess`) and request (`SCShareableContent.getWithCompletionHandler` on macOS 15+, `CGRequestScreenCaptureAccess()` below), wired into Quack's existing permission model. |

**Reused / repurposed:** `AXStatusItemScanner` stays — its `.press` powers the
click-forward step. Item discovery moves to CGS window enumeration; the notch
`isHiddenByNotch` scanning path is retired.

**CGS private APIs** are read-only enumeration (window lists and frames), less
fragile than event injection, and are isolated behind a single shim file
alongside the existing bridging code.

## Removal (replacing the old notch row)

Per Q7, remove the current notch drop-down hidden-icons row:

- `NotchService.swift` — `hiddenIconsCache`, `hiddenIconsRowHeight`, the
  `model.hiddenIcons` assignments, the scan-scheduling and `forwardHiddenIconTap`
  logic (roughly the lines around 27–37, 68, 188, 212, 217–260), and the height
  contribution.
- `NotchContentViewModel.swift` — `hiddenIcons` and `onHiddenIconTap`.
- `NotchContentView.swift` — the hidden-icons row view.

The notch panel keeps the media player and agent cards only; its height shrinks
accordingly.

## Permissions + graceful degradation

- **Screen Recording** — new requirement, requested through the Sequoia/Tahoe
  workaround path. Needed because `CGWindowListCreateImage` returns black
  without it.
- **Accessibility** — already granted in Quack; powers the AXPress click-forward.
- **Fallback** — with Screen Recording denied, capture yields black images;
  render each hidden item as **app icon + title** (the current AX style) and show
  a banner in the secondary bar prompting the grant. Feature stays functional,
  just less authentic.

## Edge cases + risks

- **Chevron vs notch (highest-priority placement rule):** the chevron must sit
  to the right of the notch so hidden items push off the left edge rather than
  behind the notch (behind the notch = unmapped = uncapturable). If the user
  drags the chevron left of the notch, warn and/or auto-nudge it back.
- **Capture of off-screen (negative-X) windows** is the **highest-risk
  assumption**. Ice relies on it working, but validate with an early spike before
  building the full panel. If it fails, the fallback is a brief on-screen
  temp-show to capture, then re-collapse (flickers).
- **Temp-show flicker:** real items flash into the bar during the AXPress click
  flow. Ice accepts this; minimize with tight collapse-after-dismiss timing.
- **Menu-dismiss detection:** need to know when the opened menu closes to
  re-collapse the divider. Watch via AX notifications / a global mouse-up
  observer, with a timeout fallback.
- **Retina:** scale captures by `backingScaleFactor`.
- **Live glyph updates:** items whose glyph changes (battery %, clock) need
  periodic re-capture while the bar is revealed.
- **CGS API fragility:** private, may shift between OS releases; isolate behind
  one shim and fail soft (empty hidden list → empty bar, no crash).

## Out of scope (v1)

- Multi-display / external menu bar — main display only for v1; note as
  follow-up.
- Third "Always Hidden" zone (Bartender parity) — two zones only.
- Automatic item movement / checklist config — manual ⌘-drag only.
- "Show when updated" per-item reveal rules.

## Verification approach

- **Spike first:** confirm `CGWindowListCreateImage` captures an off-screen
  (negative-X) status-item window with Screen Recording granted. Gate the rest of
  the build on this.
- Manual: hide several real apps' icons via ⌘-drag; confirm collapse, hover
  reveal with correct glyphs, click opens each app's real menu, re-collapse.
- Confirm no input freeze on toggling Accessibility / Screen Recording (regression
  guard for the CLAUDE.md freeze class), even though no new tap is added.
