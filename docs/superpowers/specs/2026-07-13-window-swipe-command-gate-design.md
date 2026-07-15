# Window-swipe ⌘ gate — design

**Date:** 2026-07-13
**Status:** approved, pre-implementation

## Problem

A two-finger horizontal swipe that begins with the cursor over a window title
bar makes Quack snap that window to the left/right half of the screen
(`WindowMover.move`, left/right case). The gesture is indistinguishable from an
ordinary horizontal two-finger scroll or a Mission-Control space-switch swipe,
so switching spaces accidentally snaps the window under the cursor. The snapped
window fills half the screen for a moment, then slides off as the space changes
— perceived as a ~0.5 s dark shade over half the screen.

Root cause confirmed via `log stream --predicate 'subsystem ==
"com.quack.menubar"'`: every reproduction logged
`[swipe] gesture began on title bar …` followed by a large horizontal
`swipe dx=… dy=…` — the window-swipe firing on the user's space-switch gesture.
`windowSnapEnabled` defaults to `true`; `swipeSensitivity` 0.5 → threshold 125,
which the horizontal deltas (200–370) clear easily.

## Decision

Require the **⌘ (Command) modifier** to be held during the swipe for **any**
window-swipe action (fill / minimize / snap) to fire. Without ⌘ the swipe is
ignored and the OS gesture (space switch, scroll) passes through untouched.

- **Modifier:** ⌘ Command.
- **Scope:** all four directions (up = fill, down = minimize, left/right =
  snap). Gating up/down too removes the parallel accidental-trigger path where
  a vertical two-finger scroll over a title bar maximized/minimized a window.

The event tap stays `.listenOnly` — it never consumes events, so the CLAUDE.md
input-tap freeze safeguards are unaffected. ⌘⌥+arrow keyboard shortcuts,
pinch-to-close, and the sensitivity slider are untouched.

## Design

### Pure predicate (testable)

Add to `TrackpadSwipe` (`Sources/QuackKit/Display/TrackpadSwipe.swift`):

```swift
/// Whether a completed title-bar swipe should perform a window action.
/// - direction:   resolved swipe direction (nil = below threshold → no action).
/// - commandHeld: ⌘ modifier state at the decision moment.
/// - snapEnabled: the `windowSnapEnabled` setting.
///
/// Every action requires ⌘. Left/right (snap) additionally require snapping to
/// be enabled; up/down (fill/minimize) do not.
public static func shouldPerformAction(
    direction: SwipeDirection?,
    commandHeld: Bool,
    snapEnabled: Bool
) -> Bool {
    guard commandHeld, let direction else { return false }
    switch direction {
    case .up, .down:      return true
    case .left, .right:   return snapEnabled
    }
}
```

This is the single source of truth for "will this swipe act?", used by both the
indicator badge and the end-of-gesture action so they always agree: the badge
shows **iff** the action will fire.

### Call sites — `GestureMonitor`

Both read the live modifier state via `NSEvent.modifierFlags.contains(.command)`
(current physical state; no per-gesture tracking needed).

- **`updateCursor()`** — resolve the direction as today (0.4× threshold min),
  then show the directional arrow badge iff
  `TrackpadSwipe.shouldPerformAction(direction:, commandHeld:, snapEnabled:)`;
  otherwise hide it. Replaces the current bespoke `snapOff` left/right check.

- **`endGesture()`** — after the existing eligibility + magnitude check, resolve
  the direction via `ScreenGeometry.direction(forDelta: accumulated,
  minMagnitude: threshold)` and
  `guard TrackpadSwipe.shouldPerformAction(...) else { Log.swipe.debug("swipe
  ignored: ⌘ not held / disabled"); return }` before calling
  `WindowMover.move(...)`. `WindowMover.move` keeps its own snap-enabled guard
  (defense in depth).

### UI text — `SettingsView.WindowSwipeSection` (~:1142)

- Toggle label / body: "Point at a window's title bar, then **hold ⌘** and
  swipe two fingers: up to fill the screen, down to minimize."
- Snap sub-text: "**Hold ⌘** and swipe left or right to align the window to that
  half of the current screen."

## Testing

Unit tests in `Tests/QuackKitTests/TrackpadSwipeTests.swift` for
`shouldPerformAction`:

- `direction == nil` → `false` (even with ⌘ held).
- `.up` / `.down`, ⌘ held → `true`; ⌘ not held → `false`.
- `.left` / `.right`, ⌘ held + snap on → `true`.
- `.left` / `.right`, ⌘ held + snap off → `false`.
- `.left` / `.right`, ⌘ not held → `false` (regardless of snap).

Existing direction/threshold/fingerDelta tests unchanged.

Manual verification (log stream, the method that found the bug): swipe over a
title bar **without** ⌘ → `gesture began …` appears but **no** `swipe … ->`
action line; swipe **with** ⌘ held → action fires.

## Out of scope

- Configurable modifier choice (⌘ is fixed for v1).
- Any change to the tap lifecycle, `.listenOnly` mode, or freeze safeguards.
- ⌘⌥+arrow shortcuts, pinch-to-close, sensitivity math.
