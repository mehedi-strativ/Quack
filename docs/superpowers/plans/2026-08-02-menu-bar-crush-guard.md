# Menu Bar Crush Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When macOS notch-crushes one of Quack's own menu-bar items (duck, countdown, CPU-temp, activity-timer), automatically hide lower-priority Quack items to free space, and reveal them again once it's safe.

**Architecture:** A pure decision function (`MenuBarCrushGuard` in QuackKit, unit-tested) takes each item's current visibility/frame/priority plus the notch span and returns one action per tick (hide/reveal/none), with hysteresis on reveal. A thin AppKit driver (`MenuBarCrushMonitor` in the Quack target) polls the four real `NSStatusItem`s every 3s, feeds the pure function, and applies the result. Reuses the existing `NotchGeometry`/`NotchScreenReader` pair verbatim — no new AX, CGWindowList, or screen-recording code.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit (`NSStatusItem`), Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect` — this repo does not use XCTest).

## Global Constraints

- Priority order (lower number = more important, never yields first): `duck = 0`, `countdown = 1`, `temperature = 2`, `timer = 3`.
- Poll interval: 3s (matches `TemperatureStatusItem`'s existing timer cadence — no new granularity).
- Reveal hysteresis: 2 consecutive clear ticks (~6s) before revealing a hidden item. Hide is immediate (safety first), never debounced.
- Hide/reveal via `.isVisible` only — never `.length` mutation (the documented cause of the old relayout-drift bug).
- No handling of third-party apps' status items. No AX, no `CGWindowListCopyWindowInfo`, no Screen Recording.
- Inert (no-op) on non-notched screens by construction (`NotchGeometry.notchSpan` / `NotchScreenReader.currentLayout()` return nil there).
- New pure logic lives in `QuackKit` (unit-tested); the AppKit driver lives in the `Quack` target (no test target exists for it — this repo only has `QuackKitTests`, matching precedent for all other AppKit-only code like `StatusItemController`).

---

### Task 1: `MenuBarCrushGuard` — pure decision logic

**Files:**
- Create: `Sources/QuackKit/MenuBar/MenuBarCrushGuard.swift`
- Test: `Tests/QuackKitTests/MenuBarCrushGuardTests.swift`

**Interfaces:**
- Consumes: `NotchGeometry.NotchSpan`, `NotchGeometry.isHiddenByNotch(itemMinX:notch:)` (both already exist in `Sources/QuackKit/Notch/NotchGeometry.swift`).
- Produces (used by Task 4):
  - `MenuBarCrushGuard.Item(id: String, priority: Int, isVisible: Bool, frameMinX: CGFloat)`
  - `MenuBarCrushGuard.Action` — enum `.hide(id: String)` / `.reveal(id: String)`
  - `MenuBarCrushGuard.Decision(action: Action?, isClear: Bool)`
  - `MenuBarCrushGuard.decide(items: [Item], notch: NotchGeometry.NotchSpan?, clearStreak: Int) -> Decision`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/QuackKitTests/MenuBarCrushGuardTests.swift
import Testing
import CoreGraphics
@testable import QuackKit

@Suite struct MenuBarCrushGuardTests {

    // Same fixture notch as NotchGeometryTests: 14" MBP, notch 663–848.
    private let notch = NotchGeometry.NotchSpan(minX: 663, maxX: 848)

    private func item(_ id: String, priority: Int, visible: Bool, minX: CGFloat) -> MenuBarCrushGuard.Item {
        .init(id: id, priority: priority, isVisible: visible, frameMinX: minX)
    }

    @Test func noNotchIsAlwaysInert() {
        let items = [item("duck", priority: 0, visible: true, minX: 500)]
        let decision = MenuBarCrushGuard.decide(items: items, notch: nil, clearStreak: 0)
        #expect(decision.action == nil)
        #expect(decision.isClear)
    }

    @Test func nothingCrushedIsNoAction() {
        let items = [
            item("duck", priority: 0, visible: true, minX: 900),
            item("countdown", priority: 1, visible: true, minX: 950),
            item("temperature", priority: 2, visible: true, minX: 1050),
        ]
        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: 0)
        #expect(decision.action == nil)
        #expect(decision.isClear)
    }

    @Test func crushedNonTopItemHidesTheLowestPriorityVisibleItem() {
        // countdown (priority 1) is crushed; duck (priority 0) and temperature
        // (priority 2) are fine. Lowest-priority VISIBLE item is temperature —
        // that's what gets hidden to free space, not countdown itself.
        let items = [
            item("duck", priority: 0, visible: true, minX: 900),
            item("countdown", priority: 1, visible: true, minX: 700),   // crushed
            item("temperature", priority: 2, visible: true, minX: 1000),
        ]
        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: 0)
        #expect(decision.action == .hide(id: "temperature"))
        #expect(!decision.isClear)
    }

    @Test func onlyDuckVisibleAndCrushedHasNoAction() {
        // No lower-priority item exists to sacrifice — duck never yields.
        let items = [item("duck", priority: 0, visible: true, minX: 700)]
        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: 0)
        #expect(decision.action == nil)
    }

    @Test func crushedTopmostVisibleItemAloneIsIgnored() {
        // duck (topmost, priority 0) is crushed but nothing else is —
        // the "other than the single highest-priority visible one" exclusion
        // means this alone never triggers a hide.
        let items = [
            item("duck", priority: 0, visible: true, minX: 700),      // crushed but excluded
            item("countdown", priority: 1, visible: true, minX: 900),
        ]
        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: 0)
        #expect(decision.action == nil)
    }

    @Test func clearWithHiddenCandidateDoesNotRevealBeforeTwoTicks() {
        let items = [
            item("duck", priority: 0, visible: true, minX: 900),
            item("temperature", priority: 2, visible: false, minX: 1000),
        ]
        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: 0)
        #expect(decision.action == nil)
        #expect(decision.isClear)
    }

    @Test func clearForTwoConsecutiveTicksReveals() {
        let items = [
            item("duck", priority: 0, visible: true, minX: 900),
            item("temperature", priority: 2, visible: false, minX: 1000),
        ]
        // clearStreak: 1 (this is the tick that makes streak reach 2)
        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: 1)
        #expect(decision.action == .reveal(id: "temperature"))
        #expect(decision.isClear)
    }

    @Test func revealPrefersHigherPriorityAmongMultipleHiddenItems() {
        // Both temperature (priority 2) and timer (priority 3) are hidden.
        // temperature is higher priority (lower number) — reveal it first.
        let items = [
            item("duck", priority: 0, visible: true, minX: 900),
            item("temperature", priority: 2, visible: false, minX: 1000),
            item("timer", priority: 3, visible: false, minX: 1100),
        ]
        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: 1)
        #expect(decision.action == .reveal(id: "temperature"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MenuBarCrushGuardTests`
Expected: FAIL — `MenuBarCrushGuard` does not exist yet (compile error).

- [ ] **Step 3: Write the implementation**

```swift
// Sources/QuackKit/MenuBar/MenuBarCrushGuard.swift
import CoreGraphics

/// Pure decision logic for hiding/revealing Quack's OWN menu-bar items when
/// the notch crushes one of them. Unlike the removed hidden-bar feature, this
/// never touches third-party items — every `Item` here is one Quack owns
/// directly, so no AX scan or CGWindowList capture is needed anywhere in this
/// feature; callers read `NSStatusItem.button.window.frame` directly (real
/// AppKit state for a window this process owns) and pass it in here.
public enum MenuBarCrushGuard {

    /// One of Quack's own status items, as of the current tick.
    public struct Item: Equatable, Sendable {
        public let id: String
        /// Lower number = more important = hidden last, revealed first.
        public let priority: Int
        public let isVisible: Bool
        public let frameMinX: CGFloat

        public init(id: String, priority: Int, isVisible: Bool, frameMinX: CGFloat) {
            self.id = id
            self.priority = priority
            self.isVisible = isVisible
            self.frameMinX = frameMinX
        }
    }

    public enum Action: Equatable, Sendable {
        case hide(id: String)
        case reveal(id: String)
    }

    /// `isClear` is true when no visible item is currently crushed — callers
    /// accumulate this across ticks to gate reveal with hysteresis. It stays
    /// true even when there's nothing to reveal (nothing hidden, or notch is
    /// absent) — "clear" describes the absence of a crush, not the presence
    /// of a pending reveal.
    public struct Decision: Equatable, Sendable {
        public let action: Action?
        public let isClear: Bool
    }

    /// One tick's decision.
    ///
    /// - `notch`: nil on a non-notched screen — always inert there.
    /// - `clearStreak`: how many consecutive PRIOR ticks were clear (i.e. the
    ///   value the caller stored after the previous call). This tick's own
    ///   clearness is added on top before comparing to the hysteresis
    ///   threshold, so a `clearStreak` of 1 reveals on this call.
    public static func decide(
        items: [Item],
        notch: NotchGeometry.NotchSpan?,
        clearStreak: Int
    ) -> Decision {
        guard let notch else { return Decision(action: nil, isClear: true) }

        let visible = items.filter(\.isVisible)
        let topPriority = visible.map(\.priority).min()

        let crushedOthers = visible.contains {
            $0.priority != topPriority && NotchGeometry.isHiddenByNotch(itemMinX: $0.frameMinX, notch: notch)
        }

        if crushedOthers, let lowestPriorityVisible = visible.max(by: { $0.priority < $1.priority }) {
            return Decision(action: .hide(id: lowestPriorityVisible.id), isClear: false)
        }

        let hidden = items.filter { !$0.isVisible }
        guard let revealCandidate = hidden.min(by: { $0.priority < $1.priority }) else {
            return Decision(action: nil, isClear: true)
        }

        let hysteresisTicks = 2
        if clearStreak + 1 >= hysteresisTicks {
            return Decision(action: .reveal(id: revealCandidate.id), isClear: true)
        }
        return Decision(action: nil, isClear: true)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MenuBarCrushGuardTests`
Expected: PASS (all 8 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/MenuBar/MenuBarCrushGuard.swift Tests/QuackKitTests/MenuBarCrushGuardTests.swift
git commit -m "feat(menubar): add MenuBarCrushGuard pure decision logic"
```

---

### Task 2: Expose each status item's `NSStatusItem` for the monitor to read/toggle

**Files:**
- Modify: `Sources/Quack/MenuBar/TemperatureStatusItem.swift`
- Modify: `Sources/Quack/TimeAwareness/TimeAwarenessStatusItem.swift`
- Modify: `Sources/Quack/TimeAwareness/TimeAwarenessService.swift`
- Modify: `Sources/Quack/AppEnvironment.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (used by Task 4):
  - `TemperatureStatusItem.menuBarItem: NSStatusItem?`
  - `TimeAwarenessStatusItem.menuBarItem: NSStatusItem?`
  - `TimeAwarenessService.menuBarItem: NSStatusItem?`
  - `AppEnvironment.temperatureMenuBarItem: NSStatusItem?`
  - `AppEnvironment.timeAwarenessMenuBarItem: NSStatusItem?`

Nothing else in these files changes — this task only adds read-only computed accessors around the existing private `statusItem` storage. Temperature and timer are safe to toggle `.isVisible` on directly from outside (unlike duck/countdown, handled in Task 3): neither `TemperatureStatusItem.render()` nor `TimeAwarenessStatusItem.render()` ever touches `.isVisible` — confirmed by reading both files; only `start()`/`show()`/`stop()`/`hide()` do, and those only run on a Feature-toggle change, not on the 3s/1s render timers.

- [ ] **Step 1: Add the accessor to `TemperatureStatusItem`**

In `Sources/Quack/MenuBar/TemperatureStatusItem.swift`, add after the existing `private var lastTempC: Double = -1` line (inside the class body, near the other private state):

```swift
    /// Read-only access to the real status item for `MenuBarCrushMonitor` —
    /// it needs the live frame and toggles `.isVisible` directly (safe here:
    /// nothing else in this file mutates `.isVisible` outside start()/stop()).
    var menuBarItem: NSStatusItem? { statusItem }
```

- [ ] **Step 2: Add the accessor to `TimeAwarenessStatusItem`**

In `Sources/Quack/TimeAwareness/TimeAwarenessStatusItem.swift`, add after `private var statusItem: NSStatusItem?`:

```swift
    /// Read-only access for `MenuBarCrushMonitor` — see the equivalent note
    /// on `TemperatureStatusItem.menuBarItem`.
    var menuBarItem: NSStatusItem? { statusItem }
```

- [ ] **Step 3: Add the accessor to `TimeAwarenessService`**

In `Sources/Quack/TimeAwareness/TimeAwarenessService.swift`, add after `private let statusItem = TimeAwarenessStatusItem()`:

```swift
    var menuBarItem: NSStatusItem? { statusItem.menuBarItem }
```

- [ ] **Step 4: Add accessors to `AppEnvironment`**

In `Sources/Quack/AppEnvironment.swift`, add near the other `let claudeInstaller = ...` / small public-ish declarations (after `private let coordinator: AppCoordinator` is fine, or any point after `temperatureService`/`timeAwarenessService` are declared):

```swift
    /// Exposed for `MenuBarCrushMonitor` only — see Sources/Quack/MenuBar/MenuBarCrushMonitor.swift.
    var temperatureMenuBarItem: NSStatusItem? { temperatureService.menuBarItem }
    var timeAwarenessMenuBarItem: NSStatusItem? { timeAwarenessService.menuBarItem }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build`
Expected: builds cleanly, no errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/Quack/MenuBar/TemperatureStatusItem.swift \
        Sources/Quack/TimeAwareness/TimeAwarenessStatusItem.swift \
        Sources/Quack/TimeAwareness/TimeAwarenessService.swift \
        Sources/Quack/AppEnvironment.swift
git commit -m "feat(menubar): expose temperature/timer NSStatusItem for crush guard"
```

---

### Task 3: Teach `StatusItemController` to respect a crush-hidden override for duck/countdown

**Why this task exists:** `updateCountdown()` already re-asserts `duckItem.isVisible` and `countdownItem.isVisible` from settings every 10s AND on every `env.objectWillChange` (frequent). If `MenuBarCrushMonitor` set `.isVisible = false` on these two directly from outside, `updateCountdown()` would silently flip it back to `true` within seconds. So duck/countdown need the override folded into `updateCountdown()`'s own existing assignment, not fought from outside.

**Files:**
- Modify: `Sources/Quack/MenuBar/StatusItemController.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (used by Task 4):
  - `StatusItemController.duckFrameMinX: CGFloat?`
  - `StatusItemController.duckIsVisible: Bool`
  - `StatusItemController.setDuckCrushHidden(_ hidden: Bool)`
  - `StatusItemController.countdownFrameMinX: CGFloat?`
  - `StatusItemController.countdownIsVisible: Bool`
  - `StatusItemController.setCountdownCrushHidden(_ hidden: Bool)`

- [ ] **Step 1: Add crush-hidden flags and accessors**

In `Sources/Quack/MenuBar/StatusItemController.swift`, add to the class's stored properties (near `private var titleTimer: Timer?`):

```swift
    private var duckCrushHidden = false
    private var countdownCrushHidden = false
```

Then add these computed properties, near `openSettings()`/`togglePopover()` (anywhere in the class body):

```swift
    /// Exposed for `MenuBarCrushMonitor` only.
    var duckFrameMinX: CGFloat? { duckItem.button?.window?.frame.minX }
    var duckIsVisible: Bool { duckItem.isVisible }
    var countdownFrameMinX: CGFloat? { countdownItem.button?.window?.frame.minX }
    var countdownIsVisible: Bool { countdownItem.isVisible }

    /// Called by `MenuBarCrushMonitor`. Folds the override into
    /// `updateCountdown()`'s own visibility logic rather than setting
    /// `.isVisible` directly — that logic re-runs on a timer and on every
    /// settings change, and would otherwise silently undo an external toggle.
    func setDuckCrushHidden(_ hidden: Bool) {
        duckCrushHidden = hidden
        updateCountdown()
    }

    func setCountdownCrushHidden(_ hidden: Bool) {
        countdownCrushHidden = hidden
        updateCountdown()
    }
```

- [ ] **Step 2: Fold the flags into `updateCountdown()`**

In the same file, change:

```swift
    private func updateCountdown() {
        let s = env.settingsStore.settings
        duckItem.isVisible = !s.hideDuckIcon
        let meeting = MeetingSelection.currentOrNext(from: env.meetingStore.upcoming, now: env.now)

        guard s.menuBarCountdownEnabled,
              let title = CountdownFormatter.menuBarTitle(for: meeting, now: env.now,
                                                          horizon: Double(s.countdownLeadHours) * 3600) else {
            countdownItem.isVisible = false
            return
        }
```

to:

```swift
    private func updateCountdown() {
        let s = env.settingsStore.settings
        duckItem.isVisible = !s.hideDuckIcon && !duckCrushHidden
        let meeting = MeetingSelection.currentOrNext(from: env.meetingStore.upcoming, now: env.now)

        guard !countdownCrushHidden,
              s.menuBarCountdownEnabled,
              let title = CountdownFormatter.menuBarTitle(for: meeting, now: env.now,
                                                          horizon: Double(s.countdownLeadHours) * 3600) else {
            countdownItem.isVisible = false
            return
        }
```

(The rest of `updateCountdown()` — `countdownItem.isVisible = true` and below — is unchanged.)

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 4: Commit**

```bash
git add Sources/Quack/MenuBar/StatusItemController.swift
git commit -m "feat(menubar): let StatusItemController accept a crush-hidden override"
```

---

### Task 4: `MenuBarCrushMonitor` — the AppKit driver

**Files:**
- Create: `Sources/Quack/MenuBar/MenuBarCrushMonitor.swift`

**Interfaces:**
- Consumes:
  - `MenuBarCrushGuard.Item` / `.Action` / `.Decision` / `.decide(items:notch:clearStreak:)` (Task 1)
  - `NotchScreenReader` (existing, `Sources/Quack/Notch/NotchScreenReader.swift`) and its `currentLayout() -> NotchLayout?` / `NotchLayout.span`
  - `AppEnvironment.temperatureMenuBarItem`, `.timeAwarenessMenuBarItem` (Task 2)
  - `StatusItemController.duckFrameMinX/.duckIsVisible/.setDuckCrushHidden`, `.countdownFrameMinX/.countdownIsVisible/.setCountdownCrushHidden` (Task 3)
- Produces (used by Task 5):
  - `MenuBarCrushMonitor.init(participants: [MenuBarCrushMonitor.Participant])`
  - `MenuBarCrushMonitor.makeDefault(env: AppEnvironment, statusController: StatusItemController) -> MenuBarCrushMonitor`
  - `MenuBarCrushMonitor.start()`
  - `MenuBarCrushMonitor.stop()`

- [ ] **Step 1: Write the file**

```swift
// Sources/Quack/MenuBar/MenuBarCrushMonitor.swift
import AppKit
import QuackKit

/// Watches Quack's own 4 menu-bar items (duck, countdown, CPU-temp, activity
/// timer) and, when the notch crushes one, hides lower-priority items to free
/// space — then reveals them again once it's stably safe. See
/// docs/superpowers/specs/2026-08-02-menu-bar-crush-guard-design.md.
///
/// Deliberately much simpler than the removed hidden-bar feature: these are
/// items Quack owns directly, so `button.window.frame` is real, readable
/// AppKit state regardless of window-server capture/mapping status. No AX,
/// no CGWindowList, no screen recording.
@MainActor
final class MenuBarCrushMonitor {

    /// One of Quack's own items, described entirely through closures so this
    /// file doesn't need to know how each owner stores/hides its item.
    struct Participant {
        let id: String
        let priority: Int
        let frameMinX: () -> CGFloat?
        let isVisible: () -> Bool
        let setHidden: (Bool) -> Void
    }

    private let participants: [Participant]
    private let screenReader = NotchScreenReader()
    private var crushHidden: Set<String> = []
    private var clearStreak = 0
    private var timer: Timer?

    init(participants: [Participant]) {
        self.participants = participants
    }

    /// Wires up the real 4 items in their approved priority order:
    /// duck > countdown > temperature > timer.
    static func makeDefault(env: AppEnvironment, statusController: StatusItemController) -> MenuBarCrushMonitor {
        MenuBarCrushMonitor(participants: [
            Participant(
                id: "duck", priority: 0,
                frameMinX: { [weak statusController] in statusController?.duckFrameMinX },
                isVisible: { [weak statusController] in statusController?.duckIsVisible ?? false },
                setHidden: { [weak statusController] hidden in statusController?.setDuckCrushHidden(hidden) }
            ),
            Participant(
                id: "countdown", priority: 1,
                frameMinX: { [weak statusController] in statusController?.countdownFrameMinX },
                isVisible: { [weak statusController] in statusController?.countdownIsVisible ?? false },
                setHidden: { [weak statusController] hidden in statusController?.setCountdownCrushHidden(hidden) }
            ),
            Participant(
                id: "temperature", priority: 2,
                frameMinX: { [weak env] in env?.temperatureMenuBarItem?.button?.window?.frame.minX },
                isVisible: { [weak env] in env?.temperatureMenuBarItem?.isVisible ?? false },
                setHidden: { [weak env] hidden in env?.temperatureMenuBarItem?.isVisible = !hidden }
            ),
            Participant(
                id: "timer", priority: 3,
                frameMinX: { [weak env] in env?.timeAwarenessMenuBarItem?.button?.window?.frame.minX },
                isVisible: { [weak env] in env?.timeAwarenessMenuBarItem?.isVisible ?? false },
                setHidden: { [weak env] hidden in env?.timeAwarenessMenuBarItem?.isVisible = !hidden }
            ),
        ])
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let notch = screenReader.currentLayout()?.span

        var items: [MenuBarCrushGuard.Item] = []
        for p in participants {
            guard let minX = p.frameMinX() else { continue }   // item not created yet
            let visible = p.isVisible()
            // Something external (e.g. the user re-enabling a toggle) made a
            // previously crush-hidden item visible again — drop our own
            // bookkeeping so we don't later fight that.
            if visible { crushHidden.remove(p.id) }
            items.append(.init(id: p.id, priority: p.priority, isVisible: visible, frameMinX: minX))
        }

        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: clearStreak)
        switch decision.action {
        case .hide(let id):
            crushHidden.insert(id)
            participants.first { $0.id == id }?.setHidden(true)
        case .reveal(let id):
            crushHidden.remove(id)
            participants.first { $0.id == id }?.setHidden(false)
        case nil:
            break
        }
        clearStreak = decision.isClear ? clearStreak + 1 : 0
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds cleanly. (No test target covers this file — it's a thin AppKit driver with no independently-testable logic of its own; all its decision-making is delegated to the already-tested `MenuBarCrushGuard`, matching this repo's existing convention of leaving AppKit-only glue like `StatusItemController` untested.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Quack/MenuBar/MenuBarCrushMonitor.swift
git commit -m "feat(menubar): add MenuBarCrushMonitor AppKit driver"
```

---

### Task 5: Wire it up in `QuackApp.swift`

**Files:**
- Modify: `Sources/Quack/QuackApp.swift`

**Interfaces:**
- Consumes: `MenuBarCrushMonitor.makeDefault(env:statusController:)`, `.start()` (Task 4)

- [ ] **Step 1: Start the monitor after both `env` and `statusController` exist**

In `Sources/Quack/QuackApp.swift`, change:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var env: AppEnvironment?
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let env = AppEnvironment()
        self.env = env
        statusController = StatusItemController(env: env)
        env.showSettings()   // open Settings on first launch
    }
```

to:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var env: AppEnvironment?
    private var statusController: StatusItemController?
    private var crushMonitor: MenuBarCrushMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let env = AppEnvironment()
        self.env = env
        let statusController = StatusItemController(env: env)
        self.statusController = statusController
        crushMonitor = MenuBarCrushMonitor.makeDefault(env: env, statusController: statusController)
        crushMonitor?.start()
        env.showSettings()   // open Settings on first launch
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 3: Run the full test suite**

Run: `swift test`
Expected: all tests pass, including the new `MenuBarCrushGuardTests` (Task 1) alongside every existing suite.

- [ ] **Step 4: Commit**

```bash
git add Sources/Quack/QuackApp.swift
git commit -m "feat(menubar): start MenuBarCrushMonitor at launch"
```

---

### Task 6: Install and note manual verification limits

**Files:** none (operational step)

- [ ] **Step 1: Install the rebuilt app**

Run: `./Scripts/install.sh`

Per `CLAUDE.md`: `swift build` alone only produces the dev binary — the running app is the installed bundle at `/Applications/Quack.app`. This step is required to actually see the change; skipping it would leave the previous binary running with none of this feature's code in it.

- [ ] **Step 2: Report the manual-verification limit to the user**

This feature only has an observable effect when the menu bar is actually
crowded enough to crush one of Quack's own items — not reliably
reproducible from this session. Per this repo's own documented experience
(`quack-hidden-bar-capture-findings` memory), scripted AX/GUI interaction on
this machine risks stray TCC prompts and unreliable results, so don't
attempt to simulate a crush via synthetic AX calls. Tell the user: the
feature is installed and inert until a real crush occurs; if they want it
confirmed against real hardware, the established pattern is a temporary
`Logger(...).notice(..., privacy: .public)` in `MenuBarCrushMonitor.tick()`
logging the decision each tick, rebuild, reproduce a real crowded-menu-bar
crush, `log show --last 2m --predicate 'category == "..."'`, then remove the
temporary logging once confirmed — do not leave it in permanently.
