# Window-swipe ⌘ Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Require ⌘ (Command) held for any two-finger title-bar window-swipe action (fill / minimize / snap), so a plain space-switch or scroll no longer snaps the window under the cursor to half-screen.

**Architecture:** Add one pure predicate `TrackpadSwipe.shouldPerformAction(direction:commandHeld:snapEnabled:)` as the single source of truth for "will this swipe act?". `GestureMonitor` reads the live `NSEvent.modifierFlags` at both decision points (indicator display + end-of-gesture action) and defers the yes/no to that predicate. Settings copy updated to mention ⌘.

**Tech Stack:** Swift, SwiftPM (no Xcode project), swift-testing (`import Testing`), AppKit, CoreGraphics, os.log.

## Global Constraints

- Build/run the real app with `./Scripts/install.sh` — `swift build` only makes the dev binary; the running app is `/Applications/Quack.app`.
- The swipe event tap MUST stay `.listenOnly` — never consume events. Do not touch the tap lifecycle, run-loop thread, or Accessibility-change recreate logic (CLAUDE.md freeze rules).
- Modifier is fixed to ⌘ Command for v1. Not configurable.
- Pure logic lives in `Sources/QuackKit/…` and is unit-tested; AppKit/tap code in `Sources/Quack/…` is verified manually via log stream.

---

### Task 1: Pure `shouldPerformAction` predicate + unit tests

**Files:**
- Modify: `Sources/QuackKit/Display/TrackpadSwipe.swift` (add a static func to the existing `TrackpadSwipe` enum)
- Test: `Tests/QuackKitTests/TrackpadSwipeTests.swift`

**Interfaces:**
- Consumes: `SwipeDirection` (public enum, `Sources/QuackKit/Display/ScreenGeometry.swift:19`, cases `.up/.down/.left/.right`).
- Produces: `TrackpadSwipe.shouldPerformAction(direction: SwipeDirection?, commandHeld: Bool, snapEnabled: Bool) -> Bool` — used by `GestureMonitor` in Task 2.

- [ ] **Step 1: Write the failing tests**

Add these tests inside the existing `@Suite struct TrackpadSwipeTests { … }` in `Tests/QuackKitTests/TrackpadSwipeTests.swift` (before the closing brace at line 42):

```swift
    // ⌘ gate: no action without the Command modifier, in any direction.
    @Test func noActionWithoutCommand() {
        #expect(TrackpadSwipe.shouldPerformAction(direction: .up,    commandHeld: false, snapEnabled: true)  == false)
        #expect(TrackpadSwipe.shouldPerformAction(direction: .down,  commandHeld: false, snapEnabled: true)  == false)
        #expect(TrackpadSwipe.shouldPerformAction(direction: .left,  commandHeld: false, snapEnabled: true)  == false)
        #expect(TrackpadSwipe.shouldPerformAction(direction: .right, commandHeld: false, snapEnabled: true)  == false)
    }

    // No resolved direction (below threshold) => no action, even with ⌘.
    @Test func noActionWithoutDirection() {
        #expect(TrackpadSwipe.shouldPerformAction(direction: nil, commandHeld: true, snapEnabled: true) == false)
    }

    // Up/down (fill/minimize) fire with ⌘ regardless of the snap setting.
    @Test func upDownFireWithCommand() {
        #expect(TrackpadSwipe.shouldPerformAction(direction: .up,   commandHeld: true, snapEnabled: false) == true)
        #expect(TrackpadSwipe.shouldPerformAction(direction: .down, commandHeld: true, snapEnabled: false) == true)
    }

    // Left/right (snap) require ⌘ AND snap enabled.
    @Test func leftRightRequireSnapEnabled() {
        #expect(TrackpadSwipe.shouldPerformAction(direction: .left,  commandHeld: true, snapEnabled: true)  == true)
        #expect(TrackpadSwipe.shouldPerformAction(direction: .right, commandHeld: true, snapEnabled: true)  == true)
        #expect(TrackpadSwipe.shouldPerformAction(direction: .left,  commandHeld: true, snapEnabled: false) == false)
        #expect(TrackpadSwipe.shouldPerformAction(direction: .right, commandHeld: true, snapEnabled: false) == false)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TrackpadSwipeTests`
Expected: FAIL — compile error, `type 'TrackpadSwipe' has no member 'shouldPerformAction'`.

- [ ] **Step 3: Add the predicate**

In `Sources/QuackKit/Display/TrackpadSwipe.swift`, inside `public enum TrackpadSwipe { … }`, add after `requiredDisplacement(sensitivity:)` (after line 33, before the enum's closing brace at line 34):

```swift

    /// Whether a completed title-bar swipe should perform a window action.
    /// - direction:   resolved swipe direction (nil = below threshold → no action).
    /// - commandHeld: ⌘ modifier state at the decision moment.
    /// - snapEnabled: the `windowSnapEnabled` setting.
    ///
    /// Every action requires ⌘. Left/right (snap) additionally require snapping
    /// to be enabled; up/down (fill/minimize) do not. This is the single source
    /// of truth shared by the indicator badge and the end-of-gesture action, so
    /// the badge shows exactly when the action will fire.
    public static func shouldPerformAction(
        direction: SwipeDirection?,
        commandHeld: Bool,
        snapEnabled: Bool
    ) -> Bool {
        guard commandHeld, let direction else { return false }
        switch direction {
        case .up, .down:    return true
        case .left, .right: return snapEnabled
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TrackpadSwipeTests`
Expected: PASS — all tests in the suite (existing + 4 new) green.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/Display/TrackpadSwipe.swift Tests/QuackKitTests/TrackpadSwipeTests.swift
git commit -m "feat(swipe): pure ⌘-gate predicate for window-swipe actions

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Gate GestureMonitor on ⌘ + update Settings copy

**Files:**
- Modify: `Sources/Quack/Windows/GestureMonitor.swift` (`updateCursor()` ~:179, `endGesture()` ~:194)
- Modify: `Sources/Quack/Settings/SettingsView.swift` (`WindowSwipeSection` ~:1142–1149)

**Interfaces:**
- Consumes: `TrackpadSwipe.shouldPerformAction(direction:commandHeld:snapEnabled:)` (Task 1); `NSEvent.modifierFlags` (AppKit, already imported in `GestureMonitor.swift`); existing `ScreenGeometry.direction(forDelta:minMagnitude:)`, `WindowMover.move(window:currentFrame:swipe:snapEnabled:)`.
- Produces: no new API — behavior change only.

- [ ] **Step 1: Gate the indicator in `updateCursor()`**

In `Sources/Quack/Windows/GestureMonitor.swift`, replace the current body of `updateCursor()` (lines 179–192) with:

```swift
    private func updateCursor() {
        guard eligible else { return }
        let threshold = TrackpadSwipe.requiredDisplacement(sensitivity: settings.settings.swipeSensitivity) * 0.4
        guard let direction = ScreenGeometry.direction(forDelta: accumulated, minMagnitude: threshold) else {
            indicator.hide()
            return
        }
        // Show the arrow only when the swipe will actually act (⌘ held, and snap
        // enabled for left/right). Keeps the badge honest — it appears exactly
        // when releasing would perform the action.
        if TrackpadSwipe.shouldPerformAction(direction: direction,
                                             commandHeld: NSEvent.modifierFlags.contains(.command),
                                             snapEnabled: settings.settings.windowSnapEnabled) {
            indicator.show(direction: direction, at: NSEvent.mouseLocation)
        } else {
            indicator.hide()
        }
    }
```

- [ ] **Step 2: Gate the action in `endGesture()`**

In the same file, replace the current body of `endGesture()` (lines 194–208) with:

```swift
    private func endGesture() {
        defer { resetGesture() }
        guard eligible, let window = trackedWindow,
              let frame = AXHelpers.frame(of: window) else { return }

        let threshold = TrackpadSwipe.requiredDisplacement(sensitivity: settings.settings.swipeSensitivity)
        let magnitude = (accumulated.dx * accumulated.dx + accumulated.dy * accumulated.dy).squareRoot()
        guard magnitude >= threshold else {
            Log.swipe.debug("gesture below threshold: mag=\(Int(magnitude)) need=\(Int(threshold))")
            return
        }
        // Require ⌘ held so a plain space-switch / horizontal scroll over a title
        // bar never snaps the window. Same predicate the indicator uses.
        let direction = ScreenGeometry.direction(forDelta: accumulated, minMagnitude: threshold)
        guard TrackpadSwipe.shouldPerformAction(direction: direction,
                                                commandHeld: NSEvent.modifierFlags.contains(.command),
                                                snapEnabled: settings.settings.windowSnapEnabled) else {
            Log.swipe.debug("swipe ignored: ⌘ not held (or snap disabled)")
            return
        }
        let moved = WindowMover.move(window: window, currentFrame: frame, swipe: accumulated,
                                     snapEnabled: settings.settings.windowSnapEnabled)
        Log.swipe.log("swipe dx=\(Int(self.accumulated.dx)) dy=\(Int(self.accumulated.dy)) -> \(moved ? "moved/snapped" : "no-op")")
    }
```

- [ ] **Step 3: Update Settings copy**

In `Sources/Quack/Settings/SettingsView.swift`, in `WindowSwipeSection`:

Replace the fill/minimize description (line 1144):

```swift
                Text("Point at a window's title bar, then hold ⌘ and swipe two fingers: up to fill the screen, down to minimize.")
```

Replace the snap description (line 1149):

```swift
                Text("Hold ⌘ and swipe left or right to align the window to that half of the current screen.")
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 5: Install and verify manually via log stream**

Rebuild + relaunch the real app:

```bash
./Scripts/install.sh
```

In a second terminal:

```bash
log stream --predicate 'subsystem == "com.quack.menubar"' --level debug
```

Then, with the cursor over a window's title bar:
1. Two-finger swipe left/right **without ⌘**. Expected log: `gesture began on title bar …` then `swipe ignored: ⌘ not held (or snap disabled)` — and the window does NOT move; no arrow badge appears.
2. **Hold ⌘** and two-finger swipe left/right. Expected log: `swipe dx=… dy=… -> <private>` (moved/snapped) — the window snaps to that half; arrow badge appears during the swipe.
3. Switch spaces with your normal three-finger swipe. Expected: no window snaps; at most `gesture began …` / `swipe ignored …`, never a `moved/snapped`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Quack/Windows/GestureMonitor.swift Sources/Quack/Settings/SettingsView.swift
git commit -m "fix(swipe): require ⌘ for window-swipe actions

A two-finger horizontal swipe over a title bar no longer snaps the window
during a space-switch or scroll; window-swipe (fill/minimize/snap) now fires
only while ⌘ is held. Indicator badge and action share the same predicate.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Pure predicate `shouldPerformAction` — Task 1 ✓
- Unit tests for the predicate (nil, up/down±⌘, left/right±snap, no-⌘) — Task 1 Step 1 ✓
- `updateCursor()` indicator gate — Task 2 Step 1 ✓
- `endGesture()` action gate + debug log — Task 2 Step 2 ✓
- All-four-directions scope (up/down gated too) — encoded in predicate (returns false without ⌘ for every case) ✓
- Live `NSEvent.modifierFlags.contains(.command)` at both sites — Task 2 Steps 1–2 ✓
- Settings copy mentions ⌘ (both descriptions) — Task 2 Step 3 ✓
- `.listenOnly` / tap lifecycle untouched — no task modifies `installTap`/`reinstall`/`handleScroll` phase routing ✓
- Manual log-stream verification — Task 2 Step 5 ✓

**Placeholder scan:** none — every code + command step is concrete.

**Type consistency:** `shouldPerformAction(direction:commandHeld:snapEnabled:)` signature identical in Task 1 (definition) and Task 2 (both call sites). `SwipeDirection?` return of `ScreenGeometry.direction(forDelta:minMagnitude:)` feeds directly into the predicate's `direction:` param. `windowSnapEnabled` / `swipeSensitivity` names match the existing settings usage.
