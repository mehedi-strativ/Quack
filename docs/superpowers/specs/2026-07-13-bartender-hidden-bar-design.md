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
- **Capture (capture-at-hide + cache)** — because off-screen items capture as nil
  (Task 0), real glyphs are grabbed **while the items are on-screen** and cached:
  - Enumerate hidden-zone items **while they are still on-screen** (before the
    first collapse, and after each re-arrangement) and `CGWindowListCreateImage`
    each by window ID (layer-25 windows, any owner — they belong to Control
    Center, not the app). Cache by window ID, then collapse.
  - Reveal renders **from cache** — flicker-free, no per-reveal temp-show.
  - Cache warming that must expand the divider to bring items on-screen causes one
    brief flash; do it rarely (startup if items already hidden, and on detected
    re-arrangement), never on every reveal.
  - **Staleness:** a glyph that changes while hidden (battery %, clock) stays as
    last captured until the next on-screen moment. Accepted tradeoff.
  - **Fallback:** any item with no cached capture yet (or Screen Recording denied)
    renders as its **application icon + title** (AX style). Feature always works.
- **Trigger** — hover the chevron reveals the panel; moving the pointer into the
  panel keeps it open; leaving hides it after a short grace delay. Clicking the
  chevron pins it open. Hover is detected via the `NSStatusItem` button's
  tracking area and the panel's own mouse events — **no new CGEvent tap**, so the
  CLAUDE.md freeze rules are not triggered.

### Click-forwarding: full fidelity

When the user clicks an icon in the secondary bar:

1. **Temp-show** — set `hiddenDivider.length = variableLength`, so the real item
   snaps back on-screen just left of the chevron (public API).
2. **Synthesize a left-click** at the item's live on-screen frame center. Its
   real menu opens at the correct location. (Task 12 finding: `AXPress` reports
   success but does NOT open most third-party popovers — TickTick, Notion
   Calendar — so a real posted click is required, as Ice/Bartender do. Posting a
   click is safe; the CLAUDE.md freeze rule is about event *taps*, not posting.)
3. **Re-collapse** — restore `hiddenDivider.length = 10_000` on the next real
   mouse-up after the menu (armed after the synth-click's own mouse-up passes),
   with a 5s fallback.

The menu drops from the real menu-bar row (top of screen), exactly as
Bartender/Ice behave — the secondary bar is a replica strip plus a launcher, not
a live menu host.

## Components / module layout

New module `Sources/Quack/MenuBar/HiddenBar/`:

| File | Responsibility |
|------|----------------|
| `ControlItemManager.swift` | Owns the `chevron` + `hiddenDivider` `NSStatusItem`s; length toggle; autosave position; hover detection on the chevron button. |
| `MenuBarAXScanner.swift` | AX-tree scan of every app's `AXExtrasMenuBar` — real app, icon, AX element, frame. The identity source (window pid is Control Center's, so pid is unusable). |
| `StatusWindowList.swift` | On-screen layer-25 window `(id, frame)` list, used only to match a windowID to an AX item by X so its glyph can be captured. |
| `MenuBarItemImageCache.swift` | Captures each item's glyph via `CGWindowListCreateImage(windowID)` **while on-screen only** (off-screen returns nil); caches keyed by AX item id; scales by `backingScaleFactor`. |
| `HiddenBarGeometry.swift` | `MenuBarBand` (AX scan Y band) and `NotchProbe` (main-display notch span) helpers. |
| `HiddenBarPanel.swift` | The `NSPanel`, its geometry under the menu bar, and the hover-in/hover-out lifecycle with grace delay + pin-on-click. |
| `HiddenBarView.swift` | SwiftUI replica strip: row of glyphs (or app-icon fallback), click targets, permission-missing banner. |
| `HiddenBarService.swift` | Orchestrator: warm-at-hide capture of the hidden set, cache render on reveal, `expand → AXPress(element) → collapse` click-forward, permission gating. |

**Screen Recording permission** is already wired in `PermissionsManager`
(`.screenRecording`, `refreshScreenRecording()` via `CGPreflightScreenCaptureAccess`,
`requestScreenRecording()` via `CGRequestScreenCaptureAccess`) — reuse it; no new
permission file.

**Reused / repurposed:** `AXStatusItemScanner` stays — extended with a
`press(element:)` for click-forward. Item discovery is AX-based; the notch
`isHiddenByNotch` scanning path is retired.

**No private APIs.** Public `CGWindowListCopyWindowInfo` supplies window IDs and
frames; AX supplies identity; `NSStatusItem` length supplies hiding. No CGS/CGES
enumeration or event injection is needed (Task 0 confirmed the public list is
sufficient).

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
- **Off-screen capture returns nil (confirmed, Task 0)** — resolved by the
  capture-at-hide + cache design above; do not attempt to capture items while they
  are off-screen.
- **Temp-show flicker:** real items flash into the bar during the AXPress click
  flow. Ice accepts this; minimize with tight collapse-after-dismiss timing.
- **Menu-dismiss detection:** need to know when the opened menu closes to
  re-collapse the divider. Watch via AX notifications / a global mouse-up
  observer, with a timeout fallback.
- **Retina:** scale captures by `backingScaleFactor`.
- **Live glyph updates:** items whose glyph changes (battery %, clock) need
  periodic re-capture while the bar is revealed.
- **Fail soft:** if the AX scan or window list returns nothing (permission not
  yet granted, transient), render an empty bar — never crash.

## Out of scope (v1)

- Multi-display / external menu bar — main display only for v1; note as
  follow-up.
- Third "Always Hidden" zone (Bartender parity) — two zones only.
- Automatic item movement / checklist config — manual ⌘-drag only.
- "Show when updated" per-item reveal rules.

## Task 0 spike result (2026-07-13, macOS 26.5.1, 14" MBP)

Run on hardware before building. Two findings:

- **On-screen capture works.** `CGWindowListCreateImage(windowID)` returns
  non-black images for other apps' menu-bar item windows (layer 25) with Screen
  Recording granted.
- **Off-screen capture FAILS.** Items pushed to negative X by the divider trick
  still appear in the all-windows list (`CGWindowListCopyWindowInfo` without
  `.optionOnScreenOnly`) but `CGWindowListCreateImage` returns **nil** for them —
  the window server keeps no capturable backing for off-screen windows. The
  zero-flicker Ice-style off-screen capture does **not** work on this machine.
- **Architecture note:** menu-bar status-item windows (ours and third-party) are
  owned by **Control Center**, not the originating app, in the window list.
  Enumerate by layer 25 across all owners, not by pid.

**Consequence:** real-glyph rendering requires the items to be on-screen at
capture time. See the reveal-rendering decision below (temp-show-to-capture vs.
AX app-icons); the pure off-screen-capture panel is not viable here.

## Verification approach

- **Spike (done):** see the Task 0 result above.
- Manual: hide several real apps' icons via ⌘-drag; confirm collapse, hover
  reveal with correct glyphs, click opens each app's real menu, re-collapse.
- Confirm no input freeze on toggling Accessibility / Screen Recording (regression
  guard for the CLAUDE.md freeze class), even though no new tap is added.
