# Hidden Bar Foundation Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `HiddenBarService`'s accumulating-retry-counter bug with a
single reusable settle-and-retry primitive, use it to also fix a related
click-latency bug, and add scroll/swipe reveal — without touching the
already-correct AX/notch/click-synthesis primitives around it.

**Architecture:** One new generic class, `AXSettleWaiter<Value>` (QuackKit,
unit-tested), replaces `warmAndCollapse`'s `warmAttempts`/`isRetry`
accumulating-counter bug, and separately upgrades `forwardClick`'s fixed
0.15s delay (a latency bug, not a counter bug, but the same primitive fixes
it) — its second real use, not a duplicate. A new `NSEvent` global scroll
monitor feeds the existing `HiddenBarReveal` state machine the same way
chevron-hover already does, so no new reveal state is needed.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit, Swift Testing (`import Testing`,
`@Suite`/`@Test`/`#expect`) for the QuackKit target only — the `Quack`
executable target has no test target; AX/CGEvent behavior is verified
manually via `./Scripts/install.sh`.

## Global Constraints

- Never touch `NotchGeometry`, `NotchProbe`, `MenuBarGeometry`/`MenuBarBand`,
  `MenuBarAXScanner`, `SynthClick`, `MenuBarItemImageCache`,
  `StatusWindowList`, `HiddenBarConditionMonitor`, `ControlItemManager`,
  `HiddenBarPanel`, `HiddenBarView`, `HiddenBarLayout`, `HiddenBarReveal` /
  `RevealState` / `RevealEvent`, `ChevronPlacement`, `ControlItemSeeding` —
  these are the proven primitives per the design doc.
- New monitors must be listen-only (`NSEvent.addGlobalMonitorForEvents`, not
  `CGEvent.tapCreate`) — per CLAUDE.md, only `CGEventTap`s can gate/freeze
  input; this rebuild adds none.
- Any closure that touches `HiddenBarService`'s state from a background
  queue must hop back via `DispatchQueue.main.async` before touching it
  (the class is `@MainActor`) — follow the existing idiom already used
  throughout the file, don't introduce Swift Concurrency's `Task`/`async`
  into this GCD-based file.
- Rebuild the app via `./Scripts/install.sh` to see changes — `swift build`
  alone does not update the running `/Applications/Quack.app`.

---

### Task 1: `AXSettleWaiter` primitive

**Files:**
- Create: `Sources/QuackKit/HiddenBar/AXSettleWaiter.swift`
- Test: `Tests/QuackKitTests/AXSettleWaiterTests.swift`

**Interfaces:**
- Produces: `public final class AXSettleWaiter<Value>` with
  `public init()`, `public enum Outcome { case settled(Value), exhausted(Value) }`
  (conditionally `Equatable` when `Value: Equatable`),
  `public func start(on: DispatchQueue, maxAttempts: Int = 25, interval: TimeInterval = 0.2, probe: @escaping () -> Value, isSettled: @escaping (Value) -> Bool, completion: @escaping (Outcome) -> Void)`,
  `public func cancel()`. Tasks 2 and 3 consume this exact signature.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import QuackKit

@Suite struct AXSettleWaiterTests {

    @Test func settlesImmediatelyWhenProbeAlreadyPasses() async throws {
        let waiter = AXSettleWaiter<Int>()
        var result: AXSettleWaiter<Int>.Outcome?
        waiter.start(on: .global(), maxAttempts: 3, interval: 0.01,
                     probe: { 5 },
                     isSettled: { $0 == 5 },
                     completion: { result = $0 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(result == .settled(5))
    }

    @Test func exhaustsAfterMaxAttemptsWithLastProbedValue() async throws {
        let waiter = AXSettleWaiter<Int>()
        var calls = 0
        var result: AXSettleWaiter<Int>.Outcome?
        waiter.start(on: .global(), maxAttempts: 3, interval: 0.01,
                     probe: { calls += 1; return calls },
                     isSettled: { _ in false },
                     completion: { result = $0 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(calls == 3)
        #expect(result == .exhausted(3))
    }

    @Test func newWaitCancelsThePriorInFlightWait() async throws {
        let waiter = AXSettleWaiter<Int>()
        var firstResult: AXSettleWaiter<Int>.Outcome?
        waiter.start(on: .global(), maxAttempts: 10, interval: 0.05,
                     probe: { 1 },
                     isSettled: { _ in false },
                     completion: { firstResult = $0 })
        var secondResult: AXSettleWaiter<Int>.Outcome?
        waiter.start(on: .global(), maxAttempts: 1, interval: 0.01,
                     probe: { 2 },
                     isSettled: { $0 == 2 },
                     completion: { secondResult = $0 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(secondResult == .settled(2))
        #expect(firstResult == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AXSettleWaiterTests`
Expected: FAIL to build — `AXSettleWaiter` does not exist.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Polls `probe` on `queue` every `interval`, up to `maxAttempts` times, until
/// `isSettled` passes. Starting a new wait cancels whichever wait from this
/// instance is still in flight, so there's no shared counter to leak across
/// retriggers — just one cancellable chain per waiter.
public final class AXSettleWaiter<Value> {
    private var token: DispatchWorkItem?

    public init() {}

    public enum Outcome {
        case settled(Value)
        case exhausted(Value)
    }

    /// `probe` and `completion` both run on `queue` — pass `.main` for
    /// AppKit/NSStatusItem reads, a background queue for cross-process AX
    /// calls (and hop back to `.main` yourself inside `completion`).
    public func start(
        on queue: DispatchQueue,
        maxAttempts: Int = 25,
        interval: TimeInterval = 0.2,
        probe: @escaping () -> Value,
        isSettled: @escaping (Value) -> Bool,
        completion: @escaping (Outcome) -> Void
    ) {
        token?.cancel()
        let myToken = DispatchWorkItem {}
        token = myToken

        func attempt(_ n: Int) {
            guard !myToken.isCancelled else { return }
            let value = probe()
            if isSettled(value) { completion(.settled(value)); return }
            if n >= maxAttempts { completion(.exhausted(value)); return }
            queue.asyncAfter(deadline: .now() + interval) {
                guard !myToken.isCancelled else { return }
                attempt(n + 1)
            }
        }
        queue.async { attempt(1) }
    }

    /// Cancels any in-flight wait without calling `completion`.
    public func cancel() {
        token?.cancel()
        token = nil
    }
}

extension AXSettleWaiter.Outcome: Equatable where Value: Equatable {}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AXSettleWaiterTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/HiddenBar/AXSettleWaiter.swift Tests/QuackKitTests/AXSettleWaiterTests.swift
git commit -m "feat(hiddenbar): add AXSettleWaiter cancellable poll-until-settled primitive"
```

---

### Task 2: Replace `warmAndCollapse`'s retry counter with `AXSettleWaiter`

**Files:**
- Modify: `Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift:19-25` (fields)
- Modify: `Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift:103-188` (`warmAndCollapse`)

**Interfaces:**
- Consumes: `AXSettleWaiter<Value>` from Task 1 (exact signature above).
- Produces: `private func warmAndCollapse()` (no `isRetry` param — every
  existing call site in this file already calls it with no arguments, so no
  other file needs updating), `private func proceedAfterSettled(chevronFrame: CGRect, dividerFrame: CGRect)`.
  `refreshTimer`/`refreshWhileShowing` (lines 24, 190-198) are untouched and
  keep calling `warmAndCollapse()` the same way.

- [ ] **Step 1: Replace the field block**

Find (lines 19-25):
```swift
    private var graceTimer: Timer?
    private var mouseUpMonitor: Any?
    private var activeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var policyTimer: Timer?
    private var refreshTimer: Timer?
    private var warmAttempts = 0
```

Replace with:
```swift
    private var graceTimer: Timer?
    private var mouseUpMonitor: Any?
    private var scrollMonitor: Any?
    private var activeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var policyTimer: Timer?
    private var refreshTimer: Timer?
    private let warmWaiter = AXSettleWaiter<(chevron: CGRect?, divider: CGRect?)>()
    private let clickWaiter = AXSettleWaiter<CGRect?>()
```

(`scrollMonitor` is wired in Task 4 — declared now so this task's diff and
Task 4's diff don't collide on the same lines. `clickWaiter` is consumed
starting Task 3 — declaring both waiters together keeps the field block a
single edit.)

- [ ] **Step 2: Replace `warmAndCollapse`**

Find the whole method (lines 103-188, from the doc-comment through the
closing brace right before `refreshWhileShowing`):
```swift
    /// Capture glyphs for the currently-on-screen hidden set, then collapse.
    private func warmAndCollapse(isRetry: Bool = false) {
        guard let control, !isArranging else { return }   // don't collapse mid-arrange
        // Reset the retry budget on every FRESH trigger (startup, display change,
        // app-activate). Otherwise the counter accumulates across 1.5s timer ticks
        // and, once it passes the cap, every later call gives up immediately —
        // the feature then never recovers without a relaunch.
        if !isRetry { warmAttempts = 0 }
        control.expand()
        // A hidden chevron (isVisible=false) reports a (0,0) frame, which would
        // fail the on-screen gate below forever. Make it visible first so its
        // frame is readable; the end of this routine decides final visibility.
        control.setChevronVisible(true)
        // expand() relayouts asynchronously; the chevron/divider frames aren't
        // valid immediately (chevron reads (0,-22) at launch; the divider still
        // reports its collapsed off-screen X right after expand). Wait until BOTH
        // sit ON a real screen — this rejects the launch garbage AND the collapsed
        // divider, while (unlike an X>0 test) still accepting displays at negative
        // global X, i.e. external monitors positioned left of the built-in.
        // A settled menu-bar item sits at the TOP edge of the screen it's on
        // (frame.maxY ≈ that screen's maxY). This rejects the unpositioned garbage
        // frames we get right after toggling visibility/length — both (0,-22) at
        // launch and (0,0) after setChevronVisible/expand — while still accepting
        // valid positions on any display, including external ones at negative X.
        let settled: (CGRect?) -> Bool = { r in
            guard let r, let screen = NSScreen.screens.first(where: { $0.frame.intersects(r) }) else { return false }
            return abs(screen.frame.maxY - r.maxY) < 40
        }
        guard let chevronFrame = control.chevronFrameOnScreen, settled(chevronFrame),
              let dividerFrame = control.dividerFrameOnScreen, settled(dividerFrame) else {
            warmAttempts += 1
            if warmAttempts <= 25 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.warmAndCollapse(isRetry: true) }
            }
            return
        }
        warmAttempts = 0
        control.refreshRoles()   // assign chevron glyph to the rightmost item now
        let chevronMinX = (control.chevronMinX ?? chevronFrame.minX)
        let dividerMinX = (control.dividerMinX ?? dividerFrame.minX)
        // No connected display has a notch → nothing to hide.
        guard shouldHideOnCurrentDisplay() else {
            showingAll = true
            control.expand()
            control.setDividerVisible(false)
            control.setChevronVisible(false)   // nothing hidden here → no chevron
            panel.hide()
            state = .hidden
            hiddenItems = []
            onHiddenSetChanged?([])
            return
        }
        showingAll = false
        if let notch = NotchProbe.current(), !ChevronPlacement.isSafe(chevronMinX: chevronMinX, notch: notch) {
            Log.notch.notice("hidden bar: chevron left of notch — ⌘-drag it right of the notch")
        }
        // (Divider is by definition the leftmost of the two control items now,
        // so it's always left of the chevron — no flip possible.)
        // Classify by the DIVIDER, not the chevron: collapse() only pushes items
        // left of the divider off-screen, so the panel must show exactly those.
        let boundaryX = dividerMinX
        let bands = MenuBarBand.all()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = MenuBarAXScanner.scanAll(menuBarBands: bands)
            let hidden = items.filter { $0.frame.minX < boundaryX }
            let windows = StatusWindowList.onScreen()
            DispatchQueue.main.async {
                guard let self, !self.showingAll else { return }
                self.imageCache.captureOnScreen(items: hidden, windows: windows)
                self.hiddenItems = hidden
                self.control?.collapse()
                // Keep the chevron visible on the hiding (notched) display even
                // when nothing is hidden yet — it's the control + Arrange anchor.
                // (It's hidden only in the external show-all path above.)
                self.control?.setChevronVisible(true)
                self.onHiddenSetChanged?(hidden.map {
                    .init(id: $0.id, name: $0.appName, icon: self.imageCache.image(forID: $0.id) ?? $0.appIcon)
                })
                // A hover/pinned panel already on screen was rendered from the
                // now-stale set — refresh it in place with the glyphs just
                // captured. (The condition-reveal panel doesn't need this: it
                // re-renders from `hiddenItems` on its own 1.5s policy tick.)
                if self.state == .revealed || self.state == .pinned { self.renderPanel(self.hiddenItems) }
            }
        }
    }
```

Replace with:
```swift
    /// Capture glyphs for the currently-on-screen hidden set, then collapse.
    private func warmAndCollapse() {
        guard let control, !isArranging else { return }   // don't collapse mid-arrange
        control.expand()
        // A hidden chevron (isVisible=false) reports a (0,0) frame, which would
        // fail the on-screen gate below forever. Make it visible first so its
        // frame is readable; the end of this routine decides final visibility.
        control.setChevronVisible(true)
        // expand() relayouts asynchronously; the chevron/divider frames aren't
        // valid immediately (chevron reads (0,-22) at launch; the divider still
        // reports its collapsed off-screen X right after expand). Wait until BOTH
        // sit ON a real screen — this rejects the launch garbage AND the collapsed
        // divider, while (unlike an X>0 test) still accepting displays at negative
        // global X, i.e. external monitors positioned left of the built-in.
        // A settled menu-bar item sits at the TOP edge of the screen it's on
        // (frame.maxY ≈ that screen's maxY).
        let settled: (CGRect?) -> Bool = { r in
            guard let r, let screen = NSScreen.screens.first(where: { $0.frame.intersects(r) }) else { return false }
            return abs(screen.frame.maxY - r.maxY) < 40
        }
        warmWaiter.start(
            on: .main,
            probe: { [weak self] in
                (chevron: self?.control?.chevronFrameOnScreen, divider: self?.control?.dividerFrameOnScreen)
            },
            isSettled: { settled($0.chevron) && settled($0.divider) },
            completion: { [weak self] outcome in
                // On exhaustion, give up silently — matches the prior behavior
                // (no final action was taken when the 25-attempt budget ran out).
                guard case .settled(let frames) = outcome,
                      let chevronFrame = frames.chevron, let dividerFrame = frames.divider else { return }
                self?.proceedAfterSettled(chevronFrame: chevronFrame, dividerFrame: dividerFrame)
            })
    }

    /// Runs once the chevron/divider frames are confirmed on-screen: assigns
    /// roles, decides hide-vs-show-all, warns on an unsafe chevron placement,
    /// then scans + captures the hidden set off the main thread and collapses.
    private func proceedAfterSettled(chevronFrame: CGRect, dividerFrame: CGRect) {
        guard let control else { return }
        control.refreshRoles()   // assign chevron glyph to the rightmost item now
        let chevronMinX = (control.chevronMinX ?? chevronFrame.minX)
        let dividerMinX = (control.dividerMinX ?? dividerFrame.minX)
        // No connected display has a notch → nothing to hide.
        guard shouldHideOnCurrentDisplay() else {
            showingAll = true
            control.expand()
            control.setDividerVisible(false)
            control.setChevronVisible(false)   // nothing hidden here → no chevron
            panel.hide()
            state = .hidden
            hiddenItems = []
            onHiddenSetChanged?([])
            return
        }
        showingAll = false
        if let notch = NotchProbe.current(), !ChevronPlacement.isSafe(chevronMinX: chevronMinX, notch: notch) {
            Log.notch.notice("hidden bar: chevron left of notch — ⌘-drag it right of the notch")
        }
        // (Divider is by definition the leftmost of the two control items now,
        // so it's always left of the chevron — no flip possible.)
        // Classify by the DIVIDER, not the chevron: collapse() only pushes items
        // left of the divider off-screen, so the panel must show exactly those.
        let boundaryX = dividerMinX
        let bands = MenuBarBand.all()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = MenuBarAXScanner.scanAll(menuBarBands: bands)
            let hidden = items.filter { $0.frame.minX < boundaryX }
            let windows = StatusWindowList.onScreen()
            DispatchQueue.main.async {
                guard let self, !self.showingAll else { return }
                self.imageCache.captureOnScreen(items: hidden, windows: windows)
                self.hiddenItems = hidden
                self.control?.collapse()
                // Keep the chevron visible on the hiding (notched) display even
                // when nothing is hidden yet — it's the control + Arrange anchor.
                // (It's hidden only in the external show-all path above.)
                self.control?.setChevronVisible(true)
                self.onHiddenSetChanged?(hidden.map {
                    .init(id: $0.id, name: $0.appName, icon: self.imageCache.image(forID: $0.id) ?? $0.appIcon)
                })
                // A hover/pinned panel already on screen was rendered from the
                // now-stale set — refresh it in place with the glyphs just
                // captured. (The condition-reveal panel doesn't need this: it
                // re-renders from `hiddenItems` on its own 1.5s policy tick.)
                if self.state == .revealed || self.state == .pinned { self.renderPanel(self.hiddenItems) }
            }
        }
    }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: succeeds (no other file passes `isRetry:` or reads `warmAttempts`
— confirm with `grep -rn "warmAttempts\|isRetry" Sources/Quack` returning
nothing).

- [ ] **Step 4: Run the existing QuackKit test suite (regression guard)**

Run: `swift test`
Expected: PASS — `HiddenBarRevealTests`, `HiddenBarLayoutTests`,
`HiddenBarFeatureTests`, and the new `AXSettleWaiterTests` all still pass
(this task doesn't touch QuackKit, but a full-suite run is the cheapest
regression check available since `Quack` itself has no test target).

- [ ] **Step 5: Commit**

```bash
git add Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift
git commit -m "refactor(hiddenbar): replace warmAndCollapse retry counter with AXSettleWaiter"
```

---

### Task 3: Upgrade click-forward's fixed delay to `AXSettleWaiter`

**Files:**
- Modify: `Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift:352-370`
  (`forwardClick`)

**Interfaces:**
- Consumes: `clickWaiter: AXSettleWaiter<CGRect?>` field added in Task 2.
- Produces: `private func forwardClick(_ item: MenuBarAXItem)` (same
  signature and caller as before — `renderPanel`'s `onClick:` closure at
  line 343 is unchanged), `private func sendForwardedClick(frame: CGRect)`
  (new — extracted so both the settled and exhausted outcomes can share it).
  `armCollapseAfterMenu()` (lines 372-381) is unchanged and still called the
  same way.

- [ ] **Step 1: Replace `forwardClick`**

Find (lines 352-370):
```swift
    private func forwardClick(_ item: MenuBarAXItem) {
        control?.expand()          // real item snaps on-screen; menu opens there
        panel.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                // Synthesize a real click at the item's LIVE on-screen frame (it
                // just snapped back via expand()). AXPress reports success but
                // doesn't open most third-party popovers — a real click does.
                let frame = MenuBarAXScanner.elementFrame(item.element) ?? item.frame
                SynthClick.left(at: CGPoint(x: frame.midX, y: frame.midY))
            }
            // Arm collapse-on-next-mouseUp AFTER the synth click's own mouseUp has
            // passed, so we don't immediately dismiss the menu we just opened.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.armCollapseAfterMenu()
            }
        }
    }
```

Replace with:
```swift
    /// `expand()` just changed the divider's `.length`, which relayouts
    /// asynchronously — sometimes with a multi-second lag (see the hidden-bar
    /// capture-findings memory) — so the item's live AX frame can still be
    /// mid-transition well after a fixed 0.15s wait. Clicking too early either
    /// missed (nothing under the cursor) or hit the item's stale/off-screen
    /// position — the "clicking sometimes does nothing" bug. Poll for the
    /// frame to actually be on-screen instead of guessing a fixed delay.
    private func forwardClick(_ item: MenuBarAXItem) {
        control?.expand()          // real item snaps on-screen; menu opens there
        panel.hide()
        clickWaiter.start(
            on: DispatchQueue.global(qos: .userInitiated),
            probe: { MenuBarAXScanner.elementFrame(item.element) },
            isSettled: { ($0?.minX ?? -1) >= 0 },
            completion: { [weak self] outcome in
                let frame: CGRect
                switch outcome {
                case .settled(let f):   frame = f ?? item.frame
                case .exhausted(let f): frame = f ?? item.frame   // last resort: stale beats nothing
                }
                DispatchQueue.main.async { self?.sendForwardedClick(frame: frame) }
            })
    }

    private func sendForwardedClick(frame: CGRect) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Synthesize a real click at the item's LIVE on-screen frame. AXPress
            // reports success but doesn't open most third-party popovers — a real
            // click does.
            SynthClick.left(at: CGPoint(x: frame.midX, y: frame.midY))
        }
        // Arm collapse-on-next-mouseUp AFTER the synth click's own mouseUp has
        // passed, so we don't immediately dismiss the menu we just opened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.armCollapseAfterMenu()
        }
    }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds (confirm `grep -n "asyncAfter(deadline: .now() + 0.15)" Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift` returns nothing — the fixed delay is gone).

- [ ] **Step 3: Commit**

```bash
git add Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift
git commit -m "refactor(hiddenbar): replace click-forward retry counter with AXSettleWaiter"
```

---

### Task 4: Scroll/swipe reveal

**Files:**
- Modify: `Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift:45-83` (`start()`)
- Modify: `Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift:85-101` (`stop()`)
- Modify: `Sources/Quack/Settings/SettingsView.swift:1672` (copy)

**Interfaces:**
- Consumes: `scrollMonitor: Any?` field (added in Task 2), `handle(_:)`
  and the `RevealEvent` cases already defined in QuackKit's
  `HiddenBarReveal.swift` — no new event case.
- Produces: `private func handleScroll(_ event: NSEvent)`.

- [ ] **Step 1: Wire the monitor into `start()`**

Find:
```swift
        control = c
        panel.onPanelHover = { [weak self] in self?.handle(.hoverPanel) }
        panel.onPanelExit  = { [weak self] in self?.handle(.exitAll) }
```

Replace with:
```swift
        control = c
        panel.onPanelHover = { [weak self] in self?.handle(.hoverPanel) }
        panel.onPanelExit  = { [weak self] in self?.handle(.exitAll) }
        // Listen-only — NOT a CGEventTap, so it cannot gate input (CLAUDE.md
        // freeze rule only applies to taps). Bartender/Vanilla-style scroll-
        // to-reveal: scrolling anywhere in the menu bar band reveals, same as
        // hovering the chevron.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            Task { @MainActor in self?.handleScroll(event) }
        }
```

- [ ] **Step 2: Tear it down in `stop()`**

Find:
```swift
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m); mouseUpMonitor = nil }
```

Replace with:
```swift
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m); mouseUpMonitor = nil }
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
```

- [ ] **Step 3: Implement `handleScroll`**

Add this new method right after `private func handle(_ event: RevealEvent) { ... }`:
```swift
    /// A scroll (or two-finger swipe, reported as the same event type) over
    /// the menu bar reveals the hidden set, same as chevron-hover. There's no
    /// natural "exit" event for a scroll the way there is for a tracking-area
    /// hover, so each tick immediately follows the reveal with `.exitAll` —
    /// which (per `HiddenBarReveal`) keeps the state `.revealed` but (re)arms
    /// the same short grace-hide timer hover already uses. As long as scroll
    /// ticks keep arriving faster than the grace delay, the panel stays open;
    /// once they stop, it grace-hides exactly like a hover would.
    private func handleScroll(_ event: NSEvent) {
        guard !isArranging, !showingAll,
              event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return }
        let point = NSEvent.mouseLocation   // Cocoa, bottom-left origin
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              point.y >= screen.frame.maxY - NSStatusBar.system.thickness - 12
        else { return }
        handle(.hoverChevron)
        handle(.exitAll)
    }
```

- [ ] **Step 4: Update the Settings copy**

Find (`Sources/Quack/Settings/SettingsView.swift:1672`):
```swift
            Text("Hide chosen menu bar icons behind a chevron (‹). Hover the chevron to reveal them; click one to open its menu.")
```

Replace with:
```swift
            Text("Hide chosen menu bar icons behind a chevron (‹). Hover or scroll over the menu bar to reveal them; click one to open its menu.")
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/Quack/MenuBar/HiddenBar/HiddenBarService.swift Sources/Quack/Settings/SettingsView.swift
git commit -m "feat(hiddenbar): reveal on scroll/swipe over the menu bar, not just chevron hover"
```

---

### Task 5: Manual QA + close out the phase

**Files:**
- Modify: `docs/superpowers/specs/2026-07-23-hidden-bar-foundation-rebuild-design.md:3` (status line)

No code changes beyond the status-line edit — this task is verification.

- [ ] **Step 1: Rebuild and relaunch the installed app**

Run: `./Scripts/install.sh`

- [ ] **Step 2: Manual QA checklist**

Exercise each and confirm the expected result. Use a notched MacBook display
for the notch-dependent items; if unavailable, note which items you could
not verify.

1. Hide a couple of real apps' menu bar icons via **Arrange…**
   (⌘-drag left of the accent bar), click **Done**. Expected: icons
   disappear from the real bar; chevron (‹) remains.
2. **Hover** the chevron. Expected: secondary bar appears below the menu
   bar showing the hidden icons' real glyphs.
3. Move the mouse away and wait ~1s. Expected: secondary bar grace-hides.
4. **Scroll** (two-finger scroll on trackpad, or mouse wheel) with the
   cursor anywhere in the menu bar strip. Expected: secondary bar appears,
   same as hover; stops and grace-hides ~1s after the scroll ticks stop.
5. **Click** a hidden icon in the secondary bar. Expected: the real app's
   menu opens at the correct on-screen position; the bar re-collapses
   shortly after the menu is dismissed.
6. **Click the chevron** (no prior hover). Expected: bar pins open
   (chevron flips to ›); clicking again unpins.
7. Disconnect the notched display (or close the lid with an external
   monitor attached, if available). Expected: hiding turns off, all icons
   show, chevron hides.
8. Reconnect it. Expected: hiding resumes.
9. Toggle **on-battery** / **Wi-Fi off** (whichever you can trigger).
   Expected: the corresponding hidden icon (if the reveal setting is on)
   pops out on its own, and hides again when the condition clears.
10. **Freeze regression guard** (per CLAUDE.md): toggle Quack's
    Accessibility permission off and on in System Settings while the app
    is running. Expected: no input freeze; the hidden-bar feature recovers
    (may need a moment) without needing a relaunch.

- [ ] **Step 3: Mark the spec implemented**

Find (`docs/superpowers/specs/2026-07-23-hidden-bar-foundation-rebuild-design.md:3`):
```markdown
**Status:** Approved design, pending implementation plan
```

Replace with:
```markdown
**Status:** Implemented
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-07-23-hidden-bar-foundation-rebuild-design.md
git commit -m "docs(hiddenbar): mark foundation rebuild spec implemented"
```
