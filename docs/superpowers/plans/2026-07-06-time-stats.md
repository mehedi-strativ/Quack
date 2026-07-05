# Time Awareness Statistics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist per-day activity statistics (total, breaks, per-app) with a Dashboard "Time" card and a day-by-day navigator in the Time Awareness tab.

**Architecture:** `ActivityTracker.tick` gains a `TickResult` return (events + activeDelta). A new pure `ActivityHistory` (QuackKit) aggregates deltas into per-day stats keyed "yyyy-MM-dd" (local calendar, injected). App-side `ActivityHistoryStore` does atomic JSON IO under Application Support; `TimeAwarenessService` feeds history per tick with throttled saves and becomes an `ObservableObject` so the Dashboard card and stats section refresh.

**Tech Stack:** Swift 5 / SwiftPM, Foundation Codable + FileManager, SwiftUI (`LabeledContent`, macOS 13+), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-06-time-stats-design.md`

## Global Constraints

- Branch: `Pandan`. Do not switch branches.
- Retention exactly **30 days** (today + 29 before); prune on every save.
- Storage file: `~/Library/Application Support/Quack/activity-history.json`, `version: 1`, atomic writes, directory created on demand; corrupt file → fresh empty + log, never crash.
- Save throttle: at most ~1/min (≥60 s since last save AND dirty), plus immediately on break, on `stop()`, and on `NSApplication.willTerminateNotification`.
- No stats collection while the feature is off (service stopped = no collection). No session-level log, no charts, no export.
- `Calendar` is always injected into QuackKit logic (tests pin fixed calendars).
- QuackKit stays pure: Foundation only. Tests: Swift Testing. Suite baseline on this branch: 174 tests / 26 suites after v1 fixes (22 TA + rest) — every task ends green.
- Environment quirk: `swift build`/`swift test` may exit non-zero with only a `.build/build.db disk I/O error` while actually succeeding — treat as success + retry; `rm -rf .build` if it blocks.
- Commit after every task; messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `ActivityTracker.TickResult`

**Files:**
- Modify: `Sources/QuackKit/TimeAwareness/ActivityTracker.swift`
- Modify: `Sources/Quack/TimeAwareness/TimeAwarenessService.swift` (call site)
- Test: `Tests/QuackKitTests/ActivityTrackerTests.swift`

**Interfaces:**
- Produces: `tick(...) -> TickResult` where

```swift
public struct TickResult: Equatable, Sendable {
    public var events: [Event]
    /// Seconds of activity this tick contributed (0 when idle or first tick).
    public var activeDelta: TimeInterval
    public init(events: [Event] = [], activeDelta: TimeInterval = 0)
}
```

- [ ] **Step 1: Write the failing test**

Append to `Tests/QuackKitTests/ActivityTrackerTests.swift` inside `ActivityTrackerTests`:

```swift
    @Test func tickReportsActiveDelta() {
        var a = ActivityTracker()
        // First tick: no previous tick, delta 0.
        #expect(a.tick(now: t0, idleSeconds: 0, frontmostBundleID: nil,
                       frontmostName: nil, config: cfg).activeDelta == 0)
        // Active tick 1 s later: delta 1.
        let active = a.tick(now: t0.addingTimeInterval(1), idleSeconds: 0,
                            frontmostBundleID: nil, frontmostName: nil, config: cfg)
        #expect(abs(active.activeDelta - 1) < 0.001)
        // Idle tick: delta 0 even though wall clock advanced.
        let idle = a.tick(now: t0.addingTimeInterval(2), idleSeconds: 400,
                          frontmostBundleID: nil, frontmostName: nil, config: cfg)
        #expect(idle.activeDelta == 0)
        // Clamped: 2-hour gap contributes at most 5.
        let clamped = a.tick(now: t0.addingTimeInterval(7202), idleSeconds: 0,
                             frontmostBundleID: nil, frontmostName: nil, config: cfg)
        #expect(clamped.activeDelta <= 5)
    }
```

- [ ] **Step 2: Update existing tests to `.events` and run to verify compile failure first**

Mechanical edits in the same file — every existing call that consumes the return
of `tracker.tick(...)` as `[Event]` appends `.events`:
- the `run(...)` helper: `events += tracker.tick(...)` → `events += tracker.tick(... ).events`
- `idleBeyondKResets` (or any test binding `let events = a.tick(...)`): add `.events`
- calls that discard with `_ = a.tick(...)` stay unchanged.

Run: `swift test --filter ActivityTrackerTests`
Expected: compile FAILURE — `[Event]` has no member `events` / `activeDelta` (proves the tests now require the new type).

- [ ] **Step 3: Implement**

In `Sources/QuackKit/TimeAwareness/ActivityTracker.swift`:

1. Add inside `ActivityTracker`, after `AppSlice`:

```swift
    public struct TickResult: Equatable, Sendable {
        public var events: [Event]
        /// Seconds of activity this tick contributed (0 when idle or first tick).
        public var activeDelta: TimeInterval
        public init(events: [Event] = [], activeDelta: TimeInterval = 0) {
            self.events = events
            self.activeDelta = activeDelta
        }
    }
```

2. Change the signature and the returns:

```swift
    public mutating func tick(now: Date, idleSeconds: Double,
                              frontmostBundleID: String?, frontmostName: String?,
                              config: Config) -> TickResult {
```

Body: keep everything; in the active branch record the contribution, and return
the result at the end:

```swift
        var events: [Event] = []
        var activeDelta: TimeInterval = 0
        if idleSeconds < Self.activityGraceSeconds {
            activeSeconds += delta
            activeDelta = delta
            // ... rest of active branch unchanged ...
        } else if ... {  // idle branch unchanged
        }
        return TickResult(events: events, activeDelta: activeDelta)
```

3. Update the one app call site, `Sources/Quack/TimeAwareness/TimeAwarenessService.swift` `tickNow()`:

```swift
        let result = tracker.tick(now: Date(),
                                  idleSeconds: idle,
                                  frontmostBundleID: front?.bundleIdentifier,
                                  frontmostName: front?.localizedName,
                                  config: config)
        for event in result.events {
```

(loop body unchanged; history feeding comes in Task 3).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ActivityTrackerTests && swift build`
Expected: all PASS incl. `tickReportsActiveDelta`; build success.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/TimeAwareness/ActivityTracker.swift Sources/Quack/TimeAwareness/TimeAwarenessService.swift Tests/QuackKitTests/ActivityTrackerTests.swift
git commit -m "feat(time): tick returns TickResult with per-tick activeDelta

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `ActivityHistory` (pure QuackKit)

**Files:**
- Create: `Sources/QuackKit/TimeAwareness/ActivityHistory.swift`
- Test: `Tests/QuackKitTests/ActivityHistoryTests.swift`

**Interfaces:**
- Consumes: `ActivityTracker.AppSlice`.
- Produces:

```swift
public struct ActivityHistory: Codable, Equatable, Sendable {
    public struct AppEntry: Codable, Equatable, Sendable { public var name: String; public var seconds: TimeInterval }
    public struct DayStats: Codable, Equatable, Sendable {
        public var activeSeconds: TimeInterval
        public var breaks: Int
        public var apps: [String: AppEntry]
    }
    public var version: Int                              // 1
    public private(set) var days: [String: DayStats]     // "yyyy-MM-dd"
    public init()
    public mutating func record(date: Date, calendar: Calendar, activeDelta: TimeInterval, bundleID: String?, name: String?)
    public mutating func recordBreak(date: Date, calendar: Calendar)
    public mutating func prune(keepDays: Int, today: Date, calendar: Calendar)
    public func stats(for date: Date, calendar: Calendar) -> DayStats?
    public func topApps(for date: Date, calendar: Calendar, _ n: Int) -> [ActivityTracker.AppSlice]
    public func oldestDay(calendar: Calendar) -> Date?
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/QuackKitTests/ActivityHistoryTests.swift
import Foundation
import Testing
@testable import QuackKit

@Suite struct ActivityHistoryTests {
    /// Fixed calendar so day boundaries are deterministic regardless of the
    /// machine's locale/timezone.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return c
    }
    /// 2026-07-06 12:00:00 in Stockholm.
    private var noon: Date {
        DateComponents(calendar: cal, year: 2026, month: 7, day: 6, hour: 12).date!
    }

    @Test func recordAccumulatesIntoDay() {
        var h = ActivityHistory()
        h.record(date: noon, calendar: cal, activeDelta: 30, bundleID: "com.apple.Safari", name: "Safari")
        h.record(date: noon.addingTimeInterval(60), calendar: cal, activeDelta: 30, bundleID: "com.apple.Safari", name: "Safari")
        let day = h.stats(for: noon, calendar: cal)
        #expect(day?.activeSeconds == 60)
        #expect(day?.apps["com.apple.Safari"]?.seconds == 60)
        #expect(day?.apps["com.apple.Safari"]?.name == "Safari")
        #expect(day?.breaks == 0)
    }

    @Test func midnightSplitsIntoTwoDays() {
        var h = ActivityHistory()
        let lateNight = DateComponents(calendar: cal, year: 2026, month: 7, day: 6, hour: 23, minute: 59, second: 59).date!
        let justAfter = DateComponents(calendar: cal, year: 2026, month: 7, day: 7, hour: 0, minute: 0, second: 1).date!
        h.record(date: lateNight, calendar: cal, activeDelta: 1, bundleID: nil, name: nil)
        h.record(date: justAfter, calendar: cal, activeDelta: 1, bundleID: nil, name: nil)
        #expect(h.stats(for: lateNight, calendar: cal)?.activeSeconds == 1)
        #expect(h.stats(for: justAfter, calendar: cal)?.activeSeconds == 1)
        #expect(h.days.count == 2)
    }

    @Test func zeroDeltaIsNoOp() {
        var h = ActivityHistory()
        h.record(date: noon, calendar: cal, activeDelta: 0, bundleID: "x", name: "X")
        #expect(h.days.isEmpty)
    }

    @Test func recordBreakCounts() {
        var h = ActivityHistory()
        h.recordBreak(date: noon, calendar: cal)
        h.recordBreak(date: noon, calendar: cal)
        #expect(h.stats(for: noon, calendar: cal)?.breaks == 2)
    }

    @Test func pruneKeeps30DaysIncludingToday() {
        var h = ActivityHistory()
        let today = noon
        for back in [0, 15, 29, 30, 45] {
            let d = cal.date(byAdding: .day, value: -back, to: today)!
            h.record(date: d, calendar: cal, activeDelta: 10, bundleID: nil, name: nil)
        }
        h.prune(keepDays: 30, today: today, calendar: cal)
        #expect(h.days.count == 3)   // 0, 15, 29 kept; 30, 45 dropped
        let boundary = cal.date(byAdding: .day, value: -29, to: today)!
        #expect(h.stats(for: boundary, calendar: cal) != nil)
        let dropped = cal.date(byAdding: .day, value: -30, to: today)!
        #expect(h.stats(for: dropped, calendar: cal) == nil)
    }

    @Test func topAppsSortedAndLimited() {
        var h = ActivityHistory()
        h.record(date: noon, calendar: cal, activeDelta: 30, bundleID: "b.safari", name: "Safari")
        h.record(date: noon, calendar: cal, activeDelta: 50, bundleID: "a.figma", name: "Figma")
        h.record(date: noon, calendar: cal, activeDelta: 10, bundleID: "c.mail", name: "Mail")
        let top = h.topApps(for: noon, calendar: cal, 2)
        #expect(top.count == 2)
        #expect(top[0].name == "Figma" && top[0].seconds == 50)
        #expect(top[1].name == "Safari" && top[1].seconds == 30)
    }

    @Test func statsNilForUnrecordedDay() {
        let h = ActivityHistory()
        #expect(h.stats(for: noon, calendar: cal) == nil)
        #expect(h.topApps(for: noon, calendar: cal, 5).isEmpty)
        #expect(h.oldestDay(calendar: cal) == nil)
    }

    @Test func oldestDayFindsEarliest() {
        var h = ActivityHistory()
        h.record(date: noon, calendar: cal, activeDelta: 1, bundleID: nil, name: nil)
        let earlier = cal.date(byAdding: .day, value: -10, to: noon)!
        h.record(date: earlier, calendar: cal, activeDelta: 1, bundleID: nil, name: nil)
        let oldest = h.oldestDay(calendar: cal)
        #expect(oldest != nil)
        #expect(cal.isDate(oldest!, inSameDayAs: earlier))
    }

    @Test func codableRoundTrip() throws {
        var h = ActivityHistory()
        h.record(date: noon, calendar: cal, activeDelta: 42, bundleID: "b", name: "B")
        h.recordBreak(date: noon, calendar: cal)
        let back = try JSONDecoder().decode(ActivityHistory.self, from: JSONEncoder().encode(h))
        #expect(back == h)
    }

    @Test func decodeToleratesMinimalAndUnknownFields() throws {
        let minimal = #"{"version":1,"days":{}}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(ActivityHistory.self, from: minimal).days.isEmpty)
        let extra = #"{"version":1,"days":{},"futureField":true}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(ActivityHistory.self, from: extra).days.isEmpty)
        let missingVersion = #"{"days":{}}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(ActivityHistory.self, from: missingVersion).version == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ActivityHistoryTests`
Expected: compile FAILURE — `ActivityHistory` not defined.

- [ ] **Step 3: Implement**

```swift
// Sources/QuackKit/TimeAwareness/ActivityHistory.swift
import Foundation

/// Per-day activity aggregates for the statistics view: daily active seconds,
/// break count, and per-app durations. Pure value type — the caller owns IO
/// and the clock; `Calendar` is injected so day boundaries are testable.
/// Day keys are "yyyy-MM-dd" in the injected calendar's timezone, so a
/// session crossing midnight splits into two days with no special-casing.
public struct ActivityHistory: Codable, Equatable, Sendable {
    public struct AppEntry: Codable, Equatable, Sendable {
        public var name: String
        public var seconds: TimeInterval
        public init(name: String, seconds: TimeInterval) {
            self.name = name
            self.seconds = seconds
        }
    }

    public struct DayStats: Codable, Equatable, Sendable {
        public var activeSeconds: TimeInterval
        public var breaks: Int
        public var apps: [String: AppEntry]     // bundleID → entry
        public init(activeSeconds: TimeInterval = 0, breaks: Int = 0, apps: [String: AppEntry] = [:]) {
            self.activeSeconds = activeSeconds
            self.breaks = breaks
            self.apps = apps
        }
    }

    public var version: Int
    public private(set) var days: [String: DayStats]

    public init() {
        version = 1
        days = [:]
    }

    // Tolerant decode: missing keys fall back to defaults so future fields /
    // older files never brick the history (same philosophy as QuackSettings).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        days = (try? c.decodeIfPresent([String: DayStats].self, forKey: .days)) ?? [:]
    }

    /// "2026-07-06" for the date's day in `calendar`'s timezone. Zero-padded,
    /// so lexicographic order == chronological order (prune relies on this).
    static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public mutating func record(date: Date, calendar: Calendar,
                                activeDelta: TimeInterval,
                                bundleID: String?, name: String?) {
        guard activeDelta > 0 else { return }
        let key = Self.dayKey(date, calendar)
        var day = days[key] ?? DayStats()
        day.activeSeconds += activeDelta
        if let id = bundleID {
            var entry = day.apps[id] ?? AppEntry(name: name ?? id, seconds: 0)
            entry.seconds += activeDelta
            if let name { entry.name = name }
            day.apps[id] = entry
        }
        days[key] = day
    }

    public mutating func recordBreak(date: Date, calendar: Calendar) {
        let key = Self.dayKey(date, calendar)
        var day = days[key] ?? DayStats()
        day.breaks += 1
        days[key] = day
    }

    /// Keeps today and the `keepDays - 1` days before it; drops everything older.
    public mutating func prune(keepDays: Int, today: Date, calendar: Calendar) {
        guard keepDays > 0,
              let cutoff = calendar.date(byAdding: .day, value: -(keepDays - 1),
                                         to: calendar.startOfDay(for: today)) else { return }
        let cutoffKey = Self.dayKey(cutoff, calendar)
        days = days.filter { $0.key >= cutoffKey }
    }

    public func stats(for date: Date, calendar: Calendar) -> DayStats? {
        days[Self.dayKey(date, calendar)]
    }

    /// Top `n` apps for the date's day; seconds desc, ties by name then bundleID.
    public func topApps(for date: Date, calendar: Calendar, _ n: Int) -> [ActivityTracker.AppSlice] {
        guard let day = stats(for: date, calendar: calendar) else { return [] }
        let slices = day.apps.map { (id: String, entry: AppEntry) -> ActivityTracker.AppSlice in
            ActivityTracker.AppSlice(bundleID: id, name: entry.name, seconds: entry.seconds)
        }
        let sorted = slices.sorted { (a: ActivityTracker.AppSlice, b: ActivityTracker.AppSlice) -> Bool in
            if a.seconds != b.seconds { return a.seconds > b.seconds }
            if a.name != b.name { return a.name < b.name }
            return a.bundleID < b.bundleID
        }
        return Array(sorted.prefix(n))
    }

    /// Date (start of day) of the earliest stored entry, nil when empty.
    public func oldestDay(calendar: Calendar) -> Date? {
        guard let minKey = days.keys.min() else { return nil }
        let parts = minKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return calendar.date(from: comps)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ActivityHistoryTests && swift test`
Expected: new suite PASS; full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuackKit/TimeAwareness/ActivityHistory.swift Tests/QuackKitTests/ActivityHistoryTests.swift
git commit -m "feat(time): ActivityHistory — per-day stats aggregation, 30-day prune

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Store + service feed + AppEnvironment accessors

**Files:**
- Create: `Sources/Quack/TimeAwareness/ActivityHistoryStore.swift`
- Modify: `Sources/Quack/Log.swift`
- Modify: `Sources/Quack/TimeAwareness/TimeAwarenessService.swift`
- Modify: `Sources/Quack/AppEnvironment.swift`

**Interfaces:**
- Consumes: `ActivityHistory` (Task 2), `TickResult` (Task 1).
- Produces: `TimeAwarenessService: ObservableObject` with `private(set) var history`; AppEnvironment accessors `activityStats(for:) -> ActivityHistory.DayStats?`, `activityTopApps(for:_:) -> [ActivityTracker.AppSlice]`, `activityOldestDay() -> Date?` (all `Calendar.current`).

No unit tests (file IO + wiring). Verification = build + suite green.

- [ ] **Step 1: Logger**

In `Sources/Quack/Log.swift` after the `mouse` line (or last line if absent on this branch):

```swift
    static let time = Logger(subsystem: "com.quack.menubar", category: "time")
```

- [ ] **Step 2: Store**

```swift
// Sources/Quack/TimeAwareness/ActivityHistoryStore.swift
import Foundation
import QuackKit

/// Loads/saves the activity history JSON under Application Support. All
/// failures degrade to "no history" — never crash, one log line.
@MainActor
final class ActivityHistoryStore {
    private var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Quack", isDirectory: true)
            .appendingPathComponent("activity-history.json")
    }

    func load() -> ActivityHistory {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else {
            return ActivityHistory()   // first run / missing file
        }
        do {
            return try JSONDecoder().decode(ActivityHistory.self, from: data)
        } catch {
            Log.time.error("history decode failed — starting fresh: \(error.localizedDescription)")
            return ActivityHistory()
        }
    }

    func save(_ history: ActivityHistory) {
        guard let url = fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(history)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.time.error("history save failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 3: Service feed**

In `Sources/Quack/TimeAwareness/TimeAwarenessService.swift`:

1. Class declaration → `final class TimeAwarenessService: ObservableObject, ManagedService`.
2. New properties, after `private let statusItem = TimeAwarenessStatusItem()`:

```swift
    private let historyStore = ActivityHistoryStore()
    /// In-memory day aggregates; today's entry includes the live session.
    private(set) var history = ActivityHistory()
    private var lastSavedAt = Date.distantPast
    private var historyDirty = false
    private var terminateObserver: NSObjectProtocol?
```

3. In `start()`, right after `started = true`:

```swift
        history = historyStore.load()
        history.prune(keepDays: 30, today: Date(), calendar: .current)
```

and at the end of `start()` (after the timer setup):

```swift
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in self?.saveHistoryNow() }
        }
```

4. In `stop()`, before `statusItem.hide()`:

```swift
        saveHistoryNow()
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
```

5. In `tickNow()` (post-Task-1 shape), after the `let result = tracker.tick(...)` call:

```swift
        let now = Date()
        if result.activeDelta > 0 {
            history.record(date: now, calendar: .current,
                           activeDelta: result.activeDelta,
                           bundleID: front?.bundleIdentifier,
                           name: front?.localizedName)
            historyDirty = true
        }
```

In the event loop, the `.restCompleted` arm changes from `break` to:

```swift
            case .restCompleted:
                history.recordBreak(date: now, calendar: .current)
                saveHistoryNow()   // breaks are rare — persist immediately
```

After `render()` at the end of `tickNow()`:

```swift
        if historyDirty, Date().timeIntervalSince(lastSavedAt) >= 60 {
            saveHistoryNow()
        }
```

6. New method:

```swift
    /// Prunes and writes the history file; cheap enough for the 1/min cadence.
    private func saveHistoryNow() {
        history.prune(keepDays: 30, today: Date(), calendar: .current)
        historyStore.save(history)
        lastSavedAt = Date()
        historyDirty = false
    }
```

7. UI refresh ping — in `render(force:)`, inside the minute-changed path (after `lastRenderedMinute = minute`):

```swift
        objectWillChange.send()
```

(The manual-reset closure and `.restCompleted` both funnel through `render(force: true)` or the next tick, so one ping-site suffices.)

- [ ] **Step 4: AppEnvironment accessors + forwarding**

In `Sources/Quack/AppEnvironment.swift`:

1. Next to the other nested-object forwarders (`diagnostics.objectWillChange...` block):

```swift
        timeAwarenessService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
```

2. Accessor methods near `currentCPUTemperatureC`:

```swift
    /// Day statistics for the Dashboard card and the day-by-day view. Today
    /// includes the live session (history is fed every tick in memory).
    func activityStats(for date: Date) -> ActivityHistory.DayStats? {
        timeAwarenessService.history.stats(for: date, calendar: .current)
    }

    func activityTopApps(for date: Date, _ n: Int) -> [ActivityTracker.AppSlice] {
        timeAwarenessService.history.topApps(for: date, calendar: .current, n)
    }

    /// Oldest day with recorded stats (bounds the ‹ chevron), nil if none.
    func activityOldestDay() -> Date? {
        timeAwarenessService.history.oldestDay(calendar: .current)
    }
```

- [ ] **Step 5: Build + suite**

Run: `swift build && swift test`
Expected: success; full suite green.

- [ ] **Step 6: Commit**

```bash
git add Sources/Quack/TimeAwareness/ActivityHistoryStore.swift Sources/Quack/Log.swift Sources/Quack/TimeAwareness/TimeAwarenessService.swift Sources/Quack/AppEnvironment.swift
git commit -m "feat(time): persist daily stats — history store, throttled saves, env accessors

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: UI — Dashboard "Time" card + day-by-day stats section

**Files:**
- Modify: `Sources/Quack/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: `env.activityStats(for:)`, `env.activityTopApps(for:_:)`, `env.activityOldestDay()`, `ActivityFormat.compact`, `DashCard`, the `gist(_:_:tint:)` helper inside `DashboardView`.

- [ ] **Step 1: Dashboard card**

In `DashboardView.body`'s `LazyVGrid`, after the `DashCard(tab: .windows)` line:

```swift
                    if env.settingsStore.settings.timeAwarenessEnabled {
                        DashCard(tab: .timeAwareness, title: "Time", icon: "hourglass") { timeSummary }
                    }
```

Add the summary builder near `cpuSummary` (match the `gist` usage style found
there — read the existing `gist` helper's signature in the file and call it
the same way):

```swift
    // MARK: Time awareness (today's stats)

    @ViewBuilder private var timeSummary: some View {
        if let stats = env.activityStats(for: Date()), stats.activeSeconds >= 60 {
            let top = env.activityTopApps(for: Date(), 1).first
            gist("\(ActivityFormat.compact(stats.activeSeconds)) active today · \(stats.breaks) break\(stats.breaks == 1 ? "" : "s")",
                 top.map { "Top: \($0.name) (\(ActivityFormat.compact($0.seconds)))" } ?? "No app breakdown yet")
        } else {
            gist("No activity yet today", "The timer records while you work")
        }
    }
```

- [ ] **Step 2: Stats section with day navigator**

In `SettingsPane.body`'s inner switch, the `.timeAwareness` arm becomes:

```swift
                case .timeAwareness:
                    TimeAwarenessStatsSection()
                    TimeAwarenessSection()
```

Append the section view next to `TimeAwarenessSection`:

```swift
// MARK: - Time awareness statistics (day-by-day)

private struct TimeAwarenessStatsSection: View {
    @EnvironmentObject var env: AppEnvironment
    /// 0 = today, -1 = yesterday, … Resets whenever the tab is recreated.
    @State private var dayOffset = 0

    var body: some View {
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: env.now)) ?? env.now
        let stats = env.activityStats(for: date)
        Section("Statistics") {
            HStack {
                Button { dayOffset -= 1 } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .disabled(!canGoBack(cal))
                Spacer()
                Text(label(for: date, cal)).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { dayOffset += 1 } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .disabled(dayOffset >= 0)
            }
            if let stats {
                LabeledContent("Active", value: ActivityFormat.compact(stats.activeSeconds))
                LabeledContent("Breaks", value: "\(stats.breaks)")
                ForEach(env.activityTopApps(for: date, 5), id: \.bundleID) { app in
                    LabeledContent(app.name, value: ActivityFormat.compact(app.seconds))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No activity recorded.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    /// Back stops at the older of: 29 days before today, or the oldest stored
    /// day (no point paging through guaranteed-empty days).
    private func canGoBack(_ cal: Calendar) -> Bool {
        let todayStart = cal.startOfDay(for: env.now)
        guard let floor29 = cal.date(byAdding: .day, value: -29, to: todayStart),
              let target = cal.date(byAdding: .day, value: dayOffset - 1, to: todayStart) else { return false }
        let oldest = env.activityOldestDay() ?? todayStart
        return target >= max(floor29, oldest)
    }

    private func label(for date: Date, _ cal: Calendar) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }
}
```

- [ ] **Step 3: Build + suite**

Run: `swift build && swift test`
Expected: success; suite green.

- [ ] **Step 4: Commit**

```bash
git add Sources/Quack/Settings/SettingsView.swift
git commit -m "feat(time): Dashboard Time card + day-by-day statistics section

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Install + manual verification

**Files:** `README.md` (after verification).

- [ ] **Step 1: Full build + tests**

Run: `swift build && swift test`
Expected: success, all suites PASS.

- [ ] **Step 2: Install**

Run: `./Scripts/install.sh` (retry / `rm -rf .build` on the benign build.db abort).

- [ ] **Step 3: Manual checklist** (feature enabled; report each result)

1. Use the Mac ~3 min → Dashboard shows the **Time** card: "3m active today · 0 breaks" + top app. Card hidden when the feature is toggled off.
2. Click the card → lands on the Time Awareness tab; **Statistics** section on top shows "Today", Active/Breaks rows, top apps.
3. `‹` goes to "Yesterday" (likely "No activity recorded."); `›` disabled at Today; `‹` disabled once past the oldest recorded day.
4. Take a break (idle past K with K=1) → Breaks increments for today; `~/Library/Application Support/Quack/activity-history.json` exists and contains today's key (`cat` it).
5. Quit Quack, relaunch → today's stats survive (file reloaded); session timer itself back at 0m (by design).
6. Wait 2+ min active → file's `activeSeconds` for today grows on the ~1/min save cadence.

- [ ] **Step 4: README** (after pass) — extend the Time awareness feature-table row and Usage bullet to mention daily statistics:

Table row becomes:

```markdown
| ⏳ | **Time awareness** | Menu-bar timer of continuous activity with a per-app breakdown; break reminders; daily statistics with a 30-day day-by-day view | — |
```

Usage bullet gains a sentence: "The Dashboard's Time card and the tab's
Statistics section keep 30 days of daily totals, breaks, and top apps."

- [ ] **Step 5: Final commit + push**

```bash
git add README.md
git commit -m "docs: README — Time Awareness daily statistics

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push origin Pandan
```
