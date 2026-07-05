# Time Awareness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Pandan-style menu-bar activity timer (continuous usage since last break, per-app breakdown) with configurable rest reminders.

**Architecture:** A 1 Hz poll feeds a pure QuackKit `ActivityTracker` reducer (all accumulation/reset/reminder rules; fully unit-tested with a fake clock). The app side is `TimeAwarenessService` (ManagedService: timer, system idle reads, sleep/lock signals, toasts) plus `TimeAwarenessStatusItem` (NSStatusItem + menu, mirroring `TemperatureStatusItem`). Zero permissions — no event taps.

**Tech Stack:** Swift 5 / SwiftPM, AppKit NSStatusItem/NSMenu, `CGEventSource.secondsSinceLastEventType` (idle), `NSWorkspace` (frontmost app + sleep), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-06-time-awareness-design.md`

## Global Constraints

- Branch: `Pandan`. Do not switch branches.
- Zero permissions: no CGEvent taps anywhere in this feature; idle time only via `CGEventSource.secondsSinceLastEventType(.combinedSessionState, ...)`.
- All new `QuackSettings` fields follow the file's four-part pattern (property, init param + default, init assignment, `init(from decoder:)` fallback) so old JSON decodes.
- Defaults/ranges verbatim from spec: `timeAwarenessEnabled` false; `restRemindersEnabled` true; `activityReminderMinutes` 50 (10–120); `activityRepeatMinutes` 10 (5–60); `activityIdleResetMinutes` 5 (1–30).
- Reducer constants: 60 s activity grace; per-tick wall-clock delta clamped to 0…5 s.
- QuackKit stays pure: no AppKit/CoreGraphics imports in QuackKit files.
- Tests: Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`); run `swift test`.
- Status items: create once, toggle `isVisible` — never remove/re-add (repeatedly recreating corrupts menu-bar layout; see `TemperatureStatusItem` comment).
- Environment quirk: `swift build`/`swift test` may exit non-zero with only a `.build/build.db disk I/O error` while actually succeeding — treat as success + retry; `rm -rf .build` if it blocks.
- Commit after every task; messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Settings fields + `Feature.timeAwareness`

**Files:**
- Modify: `Sources/QuackKit/Models/QuackSettings.swift`
- Modify: `Sources/QuackKit/Coordinator/ManagedService.swift`
- Test: `Tests/QuackKitTests/SettingsStoreTests.swift` (append)

**Interfaces:**
- Produces (on `QuackSettings`): `timeAwarenessEnabled: Bool` (false), `restRemindersEnabled: Bool` (true), `activityReminderMinutes: Int` (50), `activityRepeatMinutes: Int` (10), `activityIdleResetMinutes: Int` (5).
- Produces: `Feature.timeAwareness`, enabled iff `settings.timeAwarenessEnabled`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/QuackKitTests/SettingsStoreTests.swift`:

```swift
@Suite struct TimeAwarenessSettingsTests {
    @Test func fieldsDefaultWhenMissing() throws {
        let old = #"{"calendarEnabled": true}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(QuackSettings.self, from: old)
        #expect(s.timeAwarenessEnabled == false)
        #expect(s.restRemindersEnabled == true)
        #expect(s.activityReminderMinutes == 50)
        #expect(s.activityRepeatMinutes == 10)
        #expect(s.activityIdleResetMinutes == 5)
    }
    @Test func fieldsRoundTrip() throws {
        var s = QuackSettings()
        s.timeAwarenessEnabled = true
        s.restRemindersEnabled = false
        s.activityReminderMinutes = 25
        s.activityRepeatMinutes = 15
        s.activityIdleResetMinutes = 3
        let back = try JSONDecoder().decode(QuackSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
    @Test func featureGatedOnMasterToggle() {
        var s = QuackSettings()
        #expect(Feature.timeAwareness.isEnabled(in: s) == false)
        s.timeAwarenessEnabled = true
        #expect(Feature.timeAwareness.isEnabled(in: s))
        s.restRemindersEnabled = false   // reminders toggle must NOT gate the feature
        #expect(Feature.timeAwareness.isEnabled(in: s))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TimeAwarenessSettingsTests`
Expected: compile FAILURE — `timeAwarenessEnabled` not a member.

- [ ] **Step 3: Implement**

`Sources/QuackKit/Models/QuackSettings.swift` — the four-part pattern:

1. Properties (after the `// MARK: Appearance` block, before `public init(`):

```swift
    // MARK: Time awareness
    /// Show the continuous-activity timer in the menu bar.
    public var timeAwarenessEnabled: Bool
    /// Toast reminders to take a break.
    public var restRemindersEnabled: Bool
    /// Remind after this many minutes of continuous activity (N).
    public var activityReminderMinutes: Int
    /// Repeat the reminder every further M minutes while activity continues.
    public var activityRepeatMinutes: Int
    /// Consecutive idle minutes that count as a rest and reset the timer (K).
    public var activityIdleResetMinutes: Int
```

2. `init` parameters (append after the last existing parameter):

```swift
        timeAwarenessEnabled: Bool = false,
        restRemindersEnabled: Bool = true,
        activityReminderMinutes: Int = 50,
        activityRepeatMinutes: Int = 10,
        activityIdleResetMinutes: Int = 5
```

3. `init` body assignments (append at the end):

```swift
        self.timeAwarenessEnabled = timeAwarenessEnabled
        self.restRemindersEnabled = restRemindersEnabled
        self.activityReminderMinutes = activityReminderMinutes
        self.activityRepeatMinutes = activityRepeatMinutes
        self.activityIdleResetMinutes = activityIdleResetMinutes
```

4. `init(from decoder:)` (append at the end, using the file's `v` helper):

```swift
        timeAwarenessEnabled = v(.timeAwarenessEnabled, d.timeAwarenessEnabled)
        restRemindersEnabled = v(.restRemindersEnabled, d.restRemindersEnabled)
        activityReminderMinutes = v(.activityReminderMinutes, d.activityReminderMinutes)
        activityRepeatMinutes = v(.activityRepeatMinutes, d.activityRepeatMinutes)
        activityIdleResetMinutes = v(.activityIdleResetMinutes, d.activityIdleResetMinutes)
```

`Sources/QuackKit/Coordinator/ManagedService.swift` — add `case timeAwareness` after the last case, and in `isEnabled(in:)`:

```swift
        case .timeAwareness: return settings.timeAwarenessEnabled
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TimeAwarenessSettingsTests && swift build`
Expected: all PASS; build success.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/Models/QuackSettings.swift Sources/QuackKit/Coordinator/ManagedService.swift Tests/QuackKitTests/SettingsStoreTests.swift
git commit -m "feat(time): settings fields + Feature.timeAwareness

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `ActivityTracker` + `ActivityFormat` (pure QuackKit)

**Files:**
- Create: `Sources/QuackKit/TimeAwareness/ActivityTracker.swift`
- Test: `Tests/QuackKitTests/ActivityTrackerTests.swift`

**Interfaces:**
- Produces:

```swift
public struct ActivityTracker: Sendable {
    public struct Config: Equatable, Sendable {
        public var reminderMinutes: Int
        public var repeatMinutes: Int
        public var idleResetMinutes: Int
        public var remindersEnabled: Bool
        public init(reminderMinutes: Int = 50, repeatMinutes: Int = 10,
                    idleResetMinutes: Int = 5, remindersEnabled: Bool = true)
    }
    public enum Event: Equatable, Sendable {
        case reminderDue(activeSeconds: TimeInterval)
        case restCompleted
    }
    public struct AppSlice: Equatable, Sendable {
        public var bundleID: String
        public var name: String
        public var seconds: TimeInterval
    }
    public init()
    public private(set) var activeSeconds: TimeInterval
    public mutating func tick(now: Date, idleSeconds: Double,
                              frontmostBundleID: String?, frontmostName: String?,
                              config: Config) -> [Event]
    public mutating func reset()
    public func topApps(_ n: Int) -> [AppSlice]
}

public enum ActivityFormat {
    /// "0m", "47m", "1h 23m"
    public static func compact(_ seconds: TimeInterval) -> String
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/QuackKitTests/ActivityTrackerTests.swift
import Foundation
import Testing
@testable import QuackKit

@Suite struct ActivityTrackerTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let cfg = ActivityTracker.Config()   // 50 / 10 / 5, reminders on

    /// Advances the tracker one tick per second for `seconds`, active (idle 0),
    /// in the given app. Returns all emitted events.
    private func run(_ tracker: inout ActivityTracker, from start: Date,
                     seconds: Int, idle: Double = 0,
                     app: (id: String, name: String)? = ("com.apple.Safari", "Safari"),
                     config: ActivityTracker.Config? = nil) -> [ActivityTracker.Event] {
        var events: [ActivityTracker.Event] = []
        for i in 1...seconds {
            events += tracker.tick(now: start.addingTimeInterval(Double(i)),
                                   idleSeconds: idle,
                                   frontmostBundleID: app?.id, frontmostName: app?.name,
                                   config: config ?? cfg)
        }
        return events
    }

    @Test func accumulatesOneSecondPerActiveTick() {
        var a = ActivityTracker()
        _ = a.tick(now: t0, idleSeconds: 0, frontmostBundleID: nil, frontmostName: nil, config: cfg)
        _ = run(&a, from: t0, seconds: 90)
        #expect(abs(a.activeSeconds - 90) < 0.001)
    }

    @Test func firstTickAccumulatesNothing() {
        var a = ActivityTracker()
        _ = a.tick(now: t0, idleSeconds: 0, frontmostBundleID: nil, frontmostName: nil, config: cfg)
        #expect(a.activeSeconds == 0)   // no previous tick — no delta
    }

    @Test func deltaClampBoundsWallClockJumps() {
        var a = ActivityTracker()
        _ = a.tick(now: t0, idleSeconds: 0, frontmostBundleID: nil, frontmostName: nil, config: cfg)
        // 2-hour gap (sleep, debugger pause): counts at most 5 s.
        _ = a.tick(now: t0.addingTimeInterval(7200), idleSeconds: 0,
                   frontmostBundleID: nil, frontmostName: nil, config: cfg)
        #expect(a.activeSeconds <= 5)
    }

    @Test func idleWithinGraceStillAccumulates() {
        var a = ActivityTracker()
        _ = a.tick(now: t0, idleSeconds: 0, frontmostBundleID: nil, frontmostName: nil, config: cfg)
        _ = run(&a, from: t0, seconds: 30, idle: 45)   // reading, no input: idle 45 s < 60 s grace
        #expect(abs(a.activeSeconds - 30) < 0.001)
    }

    @Test func sustainedIdlePausesAccumulation() {
        var a = ActivityTracker()
        _ = a.tick(now: t0, idleSeconds: 0, frontmostBundleID: nil, frontmostName: nil, config: cfg)
        _ = run(&a, from: t0, seconds: 60)
        _ = run(&a, from: t0.addingTimeInterval(60), seconds: 120, idle: 90)   // 90 s idle < K(5 min): paused, no reset
        #expect(abs(a.activeSeconds - 60) < 0.001)
    }

    @Test func idleReachingKResetsOnceAndEmitsRestCompleted() {
        var a = ActivityTracker()
        _ = a.tick(now: t0, idleSeconds: 0, frontmostBundleID: nil, frontmostName: nil, config: cfg)
        _ = run(&a, from: t0, seconds: 600)
        let events = run(&a, from: t0.addingTimeInterval(600), seconds: 10, idle: 300)  // idle = K exactly
        #expect(events.filter { $0 == .restCompleted }.count == 1)   // once, not per tick
        #expect(a.activeSeconds == 0)
        #expect(a.topApps(5).isEmpty)
    }

    @Test func forcedIdleInfinityResets() {
        var a = ActivityTracker()
        _ = a.tick(now: t0, idleSeconds: 0, frontmostBundleID: nil, frontmostName: nil, config: cfg)
        _ = run(&a, from: t0, seconds: 120)
        let events = a.tick(now: t0.addingTimeInterval(121), idleSeconds: .infinity,
                            frontmostBundleID: nil, frontmostName: nil, config: cfg)
        #expect(events == [.restCompleted])
        #expect(a.activeSeconds == 0)
    }

    @Test func reminderCadenceNThenPlusM() {
        var a = ActivityTracker()
        let short = ActivityTracker.Config(reminderMinutes: 2, repeatMinutes: 1,
                                           idleResetMinutes: 5, remindersEnabled: true)
        _ = a.tick(now: t0, idleSeconds: 0, frontmostBundleID: nil, frontmostName: nil, config: short)
        let events = run(&a, from: t0, seconds: 60 * 4 + 5, config: short)   // 4m05s active
        let reminders = events.compactMap { e -> TimeInterval? in
            if case .reminderDue(let s) = e { return s } else { return nil }
        }
        // Due at 2m (N), 3m (N+M), 4m (N+2M).
        #expect(reminders.count == 3)
        #expect(abs(reminders[0] - 120) < 2)
        #expect(abs(reminders[1] - 180) < 2)
        #expect(abs(reminders[2] - 240) < 2)
    }

    @Test func remindersDisabledEmitsNothing() {
        var a = ActivityTracker()
        let off = ActivityTracker.Config(reminderMinutes: 1, repeatMinutes: 1,
                                         idleResetMinutes: 5, remindersEnabled: false)
        _ = a.tick(now: t0, idleSeconds: 0, frontmostBundleID: nil, frontmostName: nil, config: off)
        let events = run(&a, from: t0, seconds: 300, config: off)
        #expect(events.isEmpty)
    }

    @Test func liveConfigChangeAppliesNextTick() {
        var a = ActivityTracker()
        let long = ActivityTracker.Config(reminderMinutes: 60, repeatMinutes: 10,
                                          idleResetMinutes: 5, remindersEnabled: true)
        _ = a.tick(now: t0, idleSeconds: 0, frontmostBundleID: nil, frontmostName: nil, config: long)
        _ = run(&a, from: t0, seconds: 180, config: long)          // 3 min, no reminder (N=60m)
        let short = ActivityTracker.Config(reminderMinutes: 2, repeatMinutes: 10,
                                           idleResetMinutes: 5, remindersEnabled: true)
        let events = run(&a, from: t0.addingTimeInterval(180), seconds: 1, config: short)
        #expect(events.count == 1)   // N lowered below current total → due immediately
    }

    @Test func resetAfterReminderRestartsCadence() {
        var a = ActivityTracker()
        let short = ActivityTracker.Config(reminderMinutes: 1, repeatMinutes: 1,
                                           idleResetMinutes: 1, remindersEnabled: true)
        _ = a.tick(now: t0, idleSeconds: 0, frontmostBundleID: nil, frontmostName: nil, config: short)
        _ = run(&a, from: t0, seconds: 70, config: short)                       // fires at 1m
        _ = run(&a, from: t0.addingTimeInterval(70), seconds: 5, idle: 60, config: short)  // K=1 → reset
        #expect(a.activeSeconds == 0)
        let events = run(&a, from: t0.addingTimeInterval(75), seconds: 65, config: short)
        #expect(events.contains { if case .reminderDue = $0 { return true } else { return false } })  // fires again at N, not N+M
    }

    @Test func perAppAttributionAndTopApps() {
        var a = ActivityTracker()
        _ = a.tick(now: t0, idleSeconds: 0, frontmostBundleID: nil, frontmostName: nil, config: cfg)
        _ = run(&a, from: t0, seconds: 30, app: ("com.apple.Safari", "Safari"))
        _ = run(&a, from: t0.addingTimeInterval(30), seconds: 10, app: ("com.figma.Desktop", "Figma"))
        _ = run(&a, from: t0.addingTimeInterval(40), seconds: 20, app: nil)   // unknown frontmost: total only
        #expect(abs(a.activeSeconds - 60) < 0.001)
        let top = a.topApps(5)
        #expect(top.count == 2)
        #expect(top[0].name == "Safari" && abs(top[0].seconds - 30) < 0.001)
        #expect(top[1].name == "Figma" && abs(top[1].seconds - 10) < 0.001)
        #expect(a.topApps(1).count == 1)
    }

    @Test func manualResetClearsEverything() {
        var a = ActivityTracker()
        _ = a.tick(now: t0, idleSeconds: 0, frontmostBundleID: nil, frontmostName: nil, config: cfg)
        _ = run(&a, from: t0, seconds: 100)
        a.reset()
        #expect(a.activeSeconds == 0)
        #expect(a.topApps(5).isEmpty)
    }

    @Test func idleTickWithZeroTotalEmitsNothing() {
        var a = ActivityTracker()
        _ = a.tick(now: t0, idleSeconds: 0, frontmostBundleID: nil, frontmostName: nil, config: cfg)
        let events = run(&a, from: t0, seconds: 400, idle: 400)   // idle > K with nothing accumulated
        #expect(events.isEmpty)
    }
}

@Suite struct ActivityFormatTests {
    @Test func formats() {
        #expect(ActivityFormat.compact(0) == "0m")
        #expect(ActivityFormat.compact(59) == "0m")
        #expect(ActivityFormat.compact(60) == "1m")
        #expect(ActivityFormat.compact(47 * 60) == "47m")
        #expect(ActivityFormat.compact(3600) == "1h 0m")
        #expect(ActivityFormat.compact(3600 + 23 * 60) == "1h 23m")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ActivityTrackerTests`
Expected: compile FAILURE — `ActivityTracker` not defined.

- [ ] **Step 3: Implement**

```swift
// Sources/QuackKit/TimeAwareness/ActivityTracker.swift
import Foundation

/// Pure reducer for the Time Awareness feature: accumulates continuous-activity
/// time (total + per frontmost app), detects rests (sustained idle) and decides
/// when break reminders are due. The caller owns the clock, the idle reading,
/// and the frontmost-app lookup — everything here is deterministic and
/// unit-testable.
///
/// Rules (config is read per tick, so settings changes apply live):
/// - A tick with `idleSeconds` under the 60 s grace counts as active: the
///   wall-clock delta since the previous tick (clamped to 0…5 s so sleeps and
///   clock jumps can't teleport time) is added to the total and to the
///   frontmost app's slice.
/// - Sustained idle (>= grace) accumulates nothing. Once `idleSeconds`
///   reaches K minutes and there is anything to reset, `.restCompleted` is
///   emitted exactly once and all counters reset.
/// - Reminders: first due at N minutes of activity, then every further M
///   minutes while no rest happens.
public struct ActivityTracker: Sendable {
    public struct Config: Equatable, Sendable {
        public var reminderMinutes: Int
        public var repeatMinutes: Int
        public var idleResetMinutes: Int
        public var remindersEnabled: Bool
        public init(reminderMinutes: Int = 50, repeatMinutes: Int = 10,
                    idleResetMinutes: Int = 5, remindersEnabled: Bool = true) {
            self.reminderMinutes = reminderMinutes
            self.repeatMinutes = repeatMinutes
            self.idleResetMinutes = idleResetMinutes
            self.remindersEnabled = remindersEnabled
        }
    }

    public enum Event: Equatable, Sendable {
        case reminderDue(activeSeconds: TimeInterval)
        case restCompleted
    }

    public struct AppSlice: Equatable, Sendable {
        public var bundleID: String
        public var name: String
        public var seconds: TimeInterval
        public init(bundleID: String, name: String, seconds: TimeInterval) {
            self.bundleID = bundleID
            self.name = name
            self.seconds = seconds
        }
    }

    /// Idle below this still counts as active (reading/watching without input).
    private static let activityGraceSeconds = 60.0
    /// Upper bound on one tick's wall-clock contribution.
    private static let maxTickDelta = 5.0

    public private(set) var activeSeconds: TimeInterval = 0
    private var perAppSeconds: [String: TimeInterval] = [:]
    private var appNames: [String: String] = [:]
    private var lastTickAt: Date?
    /// `activeSeconds` at the moment the last reminder fired (nil = none yet).
    private var lastReminderAt: TimeInterval?

    public init() {}

    public mutating func tick(now: Date, idleSeconds: Double,
                              frontmostBundleID: String?, frontmostName: String?,
                              config: Config) -> [Event] {
        let delta: TimeInterval
        if let last = lastTickAt {
            delta = min(max(now.timeIntervalSince(last), 0), Self.maxTickDelta)
        } else {
            delta = 0
        }
        lastTickAt = now

        var events: [Event] = []
        if idleSeconds < Self.activityGraceSeconds {
            activeSeconds += delta
            if let id = frontmostBundleID {
                perAppSeconds[id, default: 0] += delta
                if let name = frontmostName { appNames[id] = name }
            }
            if config.remindersEnabled {
                let threshold: TimeInterval
                if let last = lastReminderAt {
                    threshold = last + TimeInterval(config.repeatMinutes * 60)
                } else {
                    threshold = TimeInterval(config.reminderMinutes * 60)
                }
                if activeSeconds >= threshold {
                    events.append(.reminderDue(activeSeconds: activeSeconds))
                    lastReminderAt = activeSeconds
                }
            }
        } else if idleSeconds >= TimeInterval(config.idleResetMinutes * 60),
                  activeSeconds > 0 || !perAppSeconds.isEmpty {
            events.append(.restCompleted)
            reset()
        }
        return events
    }

    /// Clears all counters and the reminder schedule. Keeps `lastTickAt` so the
    /// next tick's delta stays continuous.
    public mutating func reset() {
        activeSeconds = 0
        perAppSeconds = [:]
        appNames = [:]
        lastReminderAt = nil
    }

    /// Top `n` apps by active time, ties broken by name.
    public func topApps(_ n: Int) -> [AppSlice] {
        perAppSeconds
            .map { AppSlice(bundleID: $0.key, name: appNames[$0.key] ?? $0.key, seconds: $0.value) }
            .sorted { $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds }
            .prefix(n)
            .map { $0 }
    }
}

/// Compact durations for the menu bar: "0m", "47m", "1h 23m".
public enum ActivityFormat {
    public static func compact(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h \(mins % 60)m"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ActivityTrackerTests && swift test --filter ActivityFormatTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/TimeAwareness/ActivityTracker.swift Tests/QuackKitTests/ActivityTrackerTests.swift
git commit -m "feat(time): ActivityTracker reducer + ActivityFormat

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `TimeAwarenessStatusItem`

**Files:**
- Create: `Sources/Quack/TimeAwareness/TimeAwarenessStatusItem.swift`

**Interfaces:**
- Consumes: `ActivityTracker.AppSlice`, `ActivityFormat` (QuackKit).
- Produces: `@MainActor final class TimeAwarenessStatusItem: NSObject, NSMenuDelegate` with `var onReset: (() -> Void)?`, `var onOpenSettings: (() -> Void)?`, `var snapshot: (() -> (total: TimeInterval, apps: [ActivityTracker.AppSlice]))?`, `func show()`, `func hide()`, `func render(total: TimeInterval)`.

No unit tests (AppKit). Verification = `swift build` + suite green.

- [ ] **Step 1: Implement**

```swift
// Sources/Quack/TimeAwareness/TimeAwarenessStatusItem.swift
import AppKit
import QuackKit

/// The menu-bar face of Time Awareness: an hourglass + elapsed active time,
/// with a click menu showing the per-app breakdown and actions. Mirrors
/// `TemperatureStatusItem`'s create-once / toggle-visibility pattern.
@MainActor
final class TimeAwarenessStatusItem: NSObject, NSMenuDelegate {
    var onReset: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Pulled when the menu opens (and for renders) — the service owns state.
    var snapshot: (() -> (total: TimeInterval, apps: [ActivityTracker.AppSlice]))?

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    func show() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "quack.timeawareness"
            if let button = item.button {
                let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                let glass = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Activity timer")?
                    .withSymbolConfiguration(cfg)
                glass?.isTemplate = true
                button.image = glass
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
            }
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }
        statusItem?.isVisible = true
        render(total: snapshot?().total ?? 0)
    }

    func hide() {
        statusItem?.isVisible = false   // hide, don't remove (keeps menu-bar layout stable)
    }

    func render(total: TimeInterval) {
        guard let button = statusItem?.button else { return }
        button.title = " " + ActivityFormat.compact(total)
        tightenWidth(button)
    }

    /// Rebuilt on every open so times are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let snap = snapshot?() ?? (0, [])

        let header = NSMenuItem(title: "Active \(ActivityFormat.compact(snap.total)) since last break",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !snap.apps.isEmpty {
            menu.addItem(.separator())
            for slice in snap.apps {
                let row = NSMenuItem(title: "\(slice.name) — \(ActivityFormat.compact(slice.seconds))",
                                     action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            }
        }

        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset Timer", action: #selector(resetTapped), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        let settings = NSMenuItem(title: "Open Settings…", action: #selector(settingsTapped), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    @objc private func resetTapped() { onReset?() }
    @objc private func settingsTapped() { onOpenSettings?() }

    /// Pin the item to content width (same trick as TemperatureStatusItem).
    private func tightenWidth(_ button: NSStatusBarButton) {
        let font = button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let textWidth = (button.title as NSString).size(withAttributes: [.font: font]).width
        let imageWidth = button.image?.size.width ?? 0
        statusItem?.length = ceil(imageWidth + textWidth + 4)
    }
}
```

Note: `NSMenu` auto-enables items with a target/action and leaves `isEnabled = false` rows inert only when `autoenablesItems` is off — set `menu.autoenablesItems = false` right after `menu.delegate = self` so the disabled info rows stay grey and the action rows stay clickable.

Add that line:

```swift
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
```

- [ ] **Step 2: Build + suite**

Run: `swift build && swift test`
Expected: success; suite green (class not yet referenced — that's Task 4).

- [ ] **Step 3: Commit**

```bash
git add Sources/Quack/TimeAwareness/TimeAwarenessStatusItem.swift
git commit -m "feat(time): menu-bar status item with per-app breakdown menu

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `TimeAwarenessService` + AppEnvironment wiring

**Files:**
- Create: `Sources/Quack/TimeAwareness/TimeAwarenessService.swift`
- Modify: `Sources/Quack/AppEnvironment.swift`

**Interfaces:**
- Consumes: `ActivityTracker`/`Config`/`Event`, `ActivityFormat`, `TimeAwarenessStatusItem` (Task 3), `SettingsStore`, `ToastPresenter` (`func show(_ item: ToastItem, dismissAfter: TimeInterval?)`), `ToastItem` (fields: title, relativeText, timeRange, colorHex, joinURL, provider: MeetingProvider, joinable, isStart), `Feature.timeAwareness`.
- Produces: `@MainActor final class TimeAwarenessService: ManagedService` with `var onOpenSettings: (() -> Void)?`.

No unit tests (system APIs). Verification = `swift build` + suite green.

- [ ] **Step 1: Implement the service**

```swift
// Sources/Quack/TimeAwareness/TimeAwarenessService.swift
import AppKit
import CoreGraphics
import QuackKit

/// Drives Time Awareness: a 1 Hz tick reads system idle time and the frontmost
/// app, feeds the pure `ActivityTracker`, updates the status item, and shows
/// break-reminder toasts. Sleep and screen-lock force the idle signal so time
/// away from an open lid still counts as rest. Zero permissions — idle comes
/// from `CGEventSource.secondsSinceLastEventType`, no event taps.
@MainActor
final class TimeAwarenessService: ManagedService {
    /// Set by AppEnvironment after construction (opens the Settings window).
    var onOpenSettings: (() -> Void)?

    private let settings: SettingsStore
    private let toasts: ToastPresenter
    private var tracker = ActivityTracker()
    private let statusItem = TimeAwarenessStatusItem()

    private var timer: Timer?
    private var forcedIdle = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var lastRenderedMinute = -1
    private var started = false

    init(settings: SettingsStore, toasts: ToastPresenter) {
        self.settings = settings
        self.toasts = toasts
    }

    func start() {
        guard !started else { return }
        started = true

        statusItem.onReset = { [weak self] in
            self?.tracker.reset()
            self?.render(force: true)
        }
        statusItem.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        statusItem.snapshot = { [weak self] in
            guard let self else { return (0, []) }
            return (self.tracker.activeSeconds, self.tracker.topApps(5))
        }
        statusItem.show()
        render(force: true)

        // Sleep / screen-lock => forced idle (counts toward the rest threshold
        // immediately; the delta clamp keeps the gap from counting as active).
        let wnc = NSWorkspace.shared.notificationCenter
        let sleepOn: [Notification.Name] = [NSWorkspace.willSleepNotification,
                                            NSWorkspace.screensDidSleepNotification]
        let sleepOff: [Notification.Name] = [NSWorkspace.didWakeNotification,
                                             NSWorkspace.screensDidWakeNotification]
        for name in sleepOn {
            workspaceObservers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { [weak self] in self?.forcedIdle = true }
            })
        }
        for name in sleepOff {
            workspaceObservers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { [weak self] in self?.forcedIdle = false }
            })
        }
        let dnc = DistributedNotificationCenter.default()
        distributedObservers.append(dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { [weak self] in self?.forcedIdle = true } })
        distributedObservers.append(dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { [weak self] in self?.forcedIdle = false } })

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard started else { return }
        started = false
        timer?.invalidate(); timer = nil
        let wnc = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { wnc.removeObserver($0) }
        workspaceObservers = []
        let dnc = DistributedNotificationCenter.default()
        distributedObservers.forEach { dnc.removeObserver($0) }
        distributedObservers = []
        statusItem.hide()
        tracker.reset()
        forcedIdle = false
        lastRenderedMinute = -1
    }

    private func tickNow() {
        let s = settings.settings
        let config = ActivityTracker.Config(
            reminderMinutes: s.activityReminderMinutes,
            repeatMinutes: s.activityRepeatMinutes,
            idleResetMinutes: s.activityIdleResetMinutes,
            remindersEnabled: s.restRemindersEnabled
        )
        let idle = forcedIdle ? Double.infinity : Self.systemIdleSeconds()
        let front = NSWorkspace.shared.frontmostApplication
        let events = tracker.tick(now: Date(),
                                  idleSeconds: idle,
                                  frontmostBundleID: front?.bundleIdentifier,
                                  frontmostName: front?.localizedName,
                                  config: config)
        for event in events {
            switch event {
            case .reminderDue(let activeSeconds):
                showBreakToast(activeSeconds: activeSeconds)
            case .restCompleted:
                break   // menu bar simply shows 0m again
            }
        }
        render()
    }

    /// Seconds since the last user input, session-wide. No single "any input"
    /// event type is exposed with a non-failable initializer, so take the min
    /// across the input types we care about.
    private static func systemIdleSeconds() -> Double {
        let types: [CGEventType] = [.keyDown, .flagsChanged,
                                    .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .mouseMoved, .scrollWheel, .leftMouseDragged]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }

    private func showBreakToast(activeSeconds: TimeInterval) {
        let k = settings.settings.activityIdleResetMinutes
        toasts.show(ToastItem(
            title: "Time for a break 🦆",
            relativeText: "active \(ActivityFormat.compact(activeSeconds))",
            timeRange: "Step away for \(k) min to reset the timer",
            colorHex: nil,
            joinURL: nil,
            provider: .generic,
            joinable: false,
            isStart: false
        ), dismissAfter: 8)
    }

    /// Update the button only when the displayed minute changes.
    private func render(force: Bool = false) {
        let minute = Int(tracker.activeSeconds) / 60
        guard force || minute != lastRenderedMinute else { return }
        lastRenderedMinute = minute
        statusItem.render(total: tracker.activeSeconds)
    }
}
```

- [ ] **Step 2: Wire into AppEnvironment**

In `Sources/Quack/AppEnvironment.swift`, following the `temperatureService` pattern exactly:

1. Property, after `private let notchService: NotchService`:

```swift
    private let timeAwarenessService: TimeAwarenessService
```

2. Construction, after `self.notchService = NotchService(...)`:

```swift
        self.timeAwarenessService = TimeAwarenessService(settings: settings, toasts: toasts)
```

Note: `toasts` is a `private let` property initialized at declaration (`private let toasts = ToastPresenter()`), and this line runs inside `init` after `self.settings...` assignments — property initializers have already run, so `toasts` is available. If the compiler complains about using `self.toasts` before full initialization, move this assignment after the other `self.` service assignments (it is last anyway).

3. Service map — add to the `services` dictionary:

```swift
            .timeAwareness: timeAwarenessService,
```

4. Deep-link, next to `temperatureService.onOpenSettings = ...`:

```swift
        timeAwarenessService.onOpenSettings = { [weak self] in self?.showSettings(selecting: .timeAwareness) }
```

(`SettingsTab.timeAwareness` doesn't exist until Task 5 — to keep this task buildable, add the enum case NOW as part of this task: in `Sources/Quack/Settings/SettingsView.swift` add `timeAwareness` to the `SettingsTab` case list, `case .timeAwareness: return "Time Awareness"` to `title`, `case .timeAwareness: return "hourglass"` to `icon`, and add it to the Menu Bar sidebar group: `case .menuBar: return [.calendar, .temperature, .timeAwareness]`. The pane switch arm comes in Task 5; until then the tab shows an empty Form via the existing `default:` Form wrapper — add `case .timeAwareness: EmptyView()` alongside `case .general, .calendar:` in the inner switch to keep it exhaustive.)

- [ ] **Step 3: Build + suite**

Run: `swift build && swift test`
Expected: success; suite green.

- [ ] **Step 4: Commit**

```bash
git add Sources/Quack/TimeAwareness/TimeAwarenessService.swift Sources/Quack/AppEnvironment.swift Sources/Quack/Settings/SettingsView.swift
git commit -m "feat(time): TimeAwarenessService — 1 Hz tick, idle detection, break toasts

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Settings UI — Time Awareness tab

**Files:**
- Modify: `Sources/Quack/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: `SettingsTab.timeAwareness` (case added in Task 4), `env.settingsStore.binding(_:)`, the 5 settings fields from Task 1.
- Produces: `TimeAwarenessSection` view rendered by the `.timeAwareness` pane arm.

- [ ] **Step 1: Implement**

In `SettingsPane.body`'s inner switch, replace the temporary `case .timeAwareness: EmptyView()` from Task 4: remove `.timeAwareness` from the `case .general, .calendar:` vicinity if it was put there, and add a real arm after `case .temperature:`:

```swift
                case .timeAwareness:
                    TimeAwarenessSection()
```

Append the section view near `TemperatureSection`:

```swift
// MARK: - Time awareness

private struct TimeAwarenessSection: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        let s = env.settingsStore
        Section("Time awareness") {
            Toggle("Show an activity timer in the menu bar", isOn: s.binding(\.timeAwarenessEnabled))
            Text("Counts how long you've been using the Mac without a real break, with a per-app breakdown in its menu. The timer resets after you've been away long enough.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        if s.settings.timeAwarenessEnabled {
            Section("Rest reminders") {
                Toggle("Remind me to take breaks", isOn: s.binding(\.restRemindersEnabled))
                if s.settings.restRemindersEnabled {
                    Stepper("Remind after: \(s.settings.activityReminderMinutes) min of activity",
                            value: s.binding(\.activityReminderMinutes), in: 10...120, step: 5)
                    Stepper("Repeat every: \(s.settings.activityRepeatMinutes) min while I keep going",
                            value: s.binding(\.activityRepeatMinutes), in: 5...60, step: 5)
                }
                Stepper("Count a break after: \(s.settings.activityIdleResetMinutes) min away",
                        value: s.binding(\.activityIdleResetMinutes), in: 1...30, step: 1)
                Text("\"Away\" means no keyboard or mouse input — the screen being locked or the Mac asleep counts immediately.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}
```

Note the idle-reset stepper lives OUTSIDE the `restRemindersEnabled` check but INSIDE the feature check — the reset rule matters even with reminders off (it drives the timer reset).

- [ ] **Step 2: Build + suite**

Run: `swift build && swift test`
Expected: success; suite green.

- [ ] **Step 3: Commit**

```bash
git add Sources/Quack/Settings/SettingsView.swift
git commit -m "feat(time): Time Awareness settings tab

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Install + manual verification

**Files:** `README.md` (after verification passes).

- [ ] **Step 1: Full build + tests**

Run: `swift build && swift test`
Expected: success, all suites PASS.

- [ ] **Step 2: Install**

Run: `./Scripts/install.sh`
(Known quirks: benign `.build/build.db disk I/O error` may abort the script even after "Build complete!" — retry; `rm -rf .build` if persistent.)

- [ ] **Step 3: Manual checklist** (report each result; stop and debug on failure)

1. Settings shows **Time Awareness** tab (Menu Bar group, hourglass icon); enable it → hourglass + "0m" appears in the menu bar.
2. Use the Mac ~2 min → timer shows "2m". Switch between two apps, open the item's menu → header "Active Xm since last break" + both apps listed with plausible splits.
3. Reminders (10 min is the range floor, so this check takes ~15 min of activity — run it in the background of other verification): set Remind after 10 / Repeat every 5, keep the Mac active 10 min → toast "Time for a break 🦆"; keep going 5 more min → second toast.
4. "Count a break after" = 1 min: hands off keyboard/mouse for ~2 min → menu bar resets to "0m" (60 s grace + 1 min idle threshold).
5. Menu → "Reset Timer" → immediate "0m". Menu → "Open Settings…" → Settings opens on the Time Awareness tab.
6. Lock the screen (⌃⌘Q) for >1 min (with K=1) → unlock → timer reset.
7. Toggle the feature off → hourglass disappears; on → returns at "0m".

- [ ] **Step 4: README** (after checklist passes)

Add a feature-table row after the CPU temperature row, matching the table's tone:

```markdown
| ⏳ | **Time awareness** | Menu-bar timer of continuous activity with a per-app breakdown; configurable break reminders that reset once you actually step away | — |
```

And a Usage bullet after the Temperature bullet:

```markdown
- **Time awareness** — toggle under **Time Awareness**; the hourglass shows time
  since your last real break, its menu lists your top apps, and toasts nudge you
  to rest at the interval you choose.
```

- [ ] **Step 5: Final commit + push**

```bash
git add README.md
git commit -m "docs: README entry for Time Awareness

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push origin Pandan
```
