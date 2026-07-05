# Time Awareness Statistics — Design Spec

- **Date:** 2026-07-06
- **Status:** Approved (design), not yet implemented
- **Branch:** `Pandan` (on top of Time Awareness v1, commit ad3070c)
- **Supersedes:** the "no persistence / no historical stats" non-goal of
  `2026-07-06-time-awareness-design.md` — this is v2 adding exactly that.

## Problem

Time Awareness v1 shows only the current session. Wanted: daily statistics —
a Dashboard card with today's numbers and a day-by-day view for the last 30
days (total active time, breaks taken, per-app breakdown).

## Goals (v2)

- **Persist per-day stats**: daily active seconds, break count, and per-app
  daily durations. Survives app relaunches (unlike the session timer, which
  stays in-memory by design).
- **Dashboard "Time" card** (visible when `timeAwarenessEnabled`): today's
  active total, breaks taken, top app. Click → Time Awareness tab.
- **Day-by-day view** at the top of the Time Awareness settings tab:
  `‹ Saturday, Jul 5 ›` navigator; per day show active total, breaks, top-5
  apps with durations. "Today" includes the live current session.
- **30-day retention**, pruned automatically on save.
- Storage: single JSON file `~/Library/Application Support/Quack/activity-history.json`
  with a `version` field; atomic writes; throttled saving (at most ~1/min,
  plus on break and on stop/quit).

## Non-goals (v2)

- No session-level log (no start/end timeline; per-day aggregates only).
- No charts/graphs — text rows only.
- No export, no iCloud sync.
- No stats collection while the feature is toggled off (no background
  collection; off = off).
- No editing/clearing UI beyond what retention does automatically (deleting
  the JSON file is the manual escape hatch).

## Architecture

| Unit | Where | Role |
|---|---|---|
| `ActivityHistory` | QuackKit (pure) | per-day aggregates: record/prune/query, Codable |
| `ActivityTracker.TickResult` | QuackKit | tick now also reports `activeDelta` |
| `ActivityHistoryStore` | app | load/save the JSON file (atomic, dir on demand) |
| `TimeAwarenessService` (extended) | app | feeds history per tick, throttled saves |
| `TimeAwarenessStatsSection` + Dashboard card | app UI | day navigator + today card |

### Unit 1 — `ActivityHistory` (pure QuackKit)

```swift
public struct ActivityHistory: Codable, Equatable, Sendable {
    public struct AppEntry: Codable, Equatable, Sendable {
        public var name: String
        public var seconds: TimeInterval
    }
    public struct DayStats: Codable, Equatable, Sendable {
        public var activeSeconds: TimeInterval
        public var breaks: Int
        public var apps: [String: AppEntry]      // bundleID → entry
    }

    public var version: Int                       // 1
    public private(set) var days: [String: DayStats]   // "yyyy-MM-dd" local

    public init()
    public mutating func record(date: Date, calendar: Calendar,
                                activeDelta: TimeInterval,
                                bundleID: String?, name: String?)
    public mutating func recordBreak(date: Date, calendar: Calendar)
    public mutating func prune(keepDays: Int, today: Date, calendar: Calendar)
    public func stats(for date: Date, calendar: Calendar) -> DayStats?
    public func topApps(for date: Date, calendar: Calendar, _ n: Int) -> [ActivityTracker.AppSlice]
    /// Oldest stored day key's date (for disabling the ‹ chevron), nil if empty.
    public func oldestDay(calendar: Calendar) -> Date?
}
```

- Day keys derive from the **tick's** local calendar date, so a session
  crossing midnight splits correctly with zero special-casing.
- `record` with `activeDelta == 0` is a no-op (no empty day entries).
- `prune(keepDays: 30, …)` keeps today and the 29 days before it.
- `Calendar` injected everywhere — tests pin a fixed calendar/timezone.
- Decoding tolerates unknown fields / missing keys (defaults), same
  philosophy as `QuackSettings`.

### Unit 2 — `ActivityTracker.TickResult`

`tick(...)` return type changes from `[Event]` to:

```swift
public struct TickResult: Equatable, Sendable {
    public var events: [Event]
    /// Seconds of activity this tick contributed (0 when idle / first tick).
    public var activeDelta: TimeInterval
}
```

Reducer logic unchanged; v1 tests updated mechanically (`.events`), plus new
assertions that `activeDelta` is the clamped delta on active ticks and 0 on
idle/first ticks.

### Unit 3 — `ActivityHistoryStore` (app)

```swift
@MainActor final class ActivityHistoryStore {
    func load() -> ActivityHistory          // missing/corrupt file → fresh empty
    func save(_ history: ActivityHistory)   // atomic write, creates directory
}
```

File: `FileManager.default.urls(for: .applicationSupportDirectory, ...)/Quack/activity-history.json`.
Corrupt/undecodable file → log via `Log.mouse`-style category (`Log.time`,
added) and start fresh; never crash.

### Unit 4 — `TimeAwarenessService` extensions

- `start()`: `history = store.load()`; prune immediately.
- Per tick: `let result = tracker.tick(...)`; if `result.activeDelta > 0` →
  `history.record(...)` with the tick's frontmost app.
- `.restCompleted` event → `history.recordBreak(...)` + save now.
- Save throttle: save when ≥60 s since last save and history changed;
  also in `stop()` and on `NSApplication.willTerminateNotification`.
- Prune runs inside every save.
- The service becomes an `ObservableObject`; it sends `objectWillChange`
  from the existing minute-render throttle (so at most ~1 ping/min) and on
  break/reset. `AppEnvironment` forwards it like the other nested objects
  (`settings`, `permissions`, `brightness`, `diagnostics`), which refreshes
  the Dashboard card and the stats section.

### Unit 5 — UI

**Dashboard card** (`SettingsView.swift`, `DashboardView`): alongside the
CPU/Display/Windows cards, gated on `timeAwarenessEnabled`:

```
DashCard(tab: .timeAwareness, title: "Time", icon: "hourglass") { timeSummary }
```

`timeSummary`: "2h 41m active today · 4 breaks" + "Top: Safari (1h 12m)"
(top line bold like siblings; "No activity yet today" when empty).

**Day-by-day** (`TimeAwarenessStatsSection`, rendered above the existing
sections in the `.timeAwareness` pane):

- Header: `‹` button — date label ("Today", "Yesterday", else "Saturday,
  Jul 5") — `›` button. Right chevron disabled at today; left chevron
  disabled at `max(oldest stored day, today − 29 days)`.
- Rows: "Active — 2h 41m", "Breaks — 4", then top-5 app rows
  ("Safari — 1h 12m"). Empty day: single secondary-text row
  "No activity recorded."
- Selected day state is view-local (`@State var dayOffset: Int = 0`); resets
  to today whenever the tab reopens.

**Data path:** `AppEnvironment` accessors backed by the service's in-memory
history: `activityStats(for: Date) -> ActivityHistory.DayStats?`,
`activityTopApps(for: Date, _ n: Int)`, `activityOldestDay() -> Date?`.
Today's stats include the live session because ticks record into history
continuously (the file lags by up to the save throttle; memory does not).

## Error handling

- Corrupt history file → fresh empty history + one log line.
- Application Support directory creation failure → in-memory only for the
  session (log, don't crash); next launch retries.
- Day navigation clamps to [oldest, today]; no crash on empty history.
- Feature toggled off mid-day: history keeps what was recorded; collection
  stops (service stopped); card hidden with the feature toggle.

## Testing

- `ActivityHistoryTests` (pure, fixed `Calendar` with explicit timezone):
  record accumulates into the correct day key; two ticks across local
  midnight land in two day entries; zero-delta record is a no-op;
  recordBreak increments; prune keeps exactly `keepDays` incl. today and
  drops older; boundary day (today−29) survives, today−30 dropped;
  topApps per-day ordering + limit; stats(for:) nil for unrecorded day;
  oldestDay; Codable round-trip; decode of `{"version":1,"days":{}}` and of
  a payload with an unknown extra field.
- `ActivityTrackerTests`: updated for `TickResult`; new `activeDelta`
  assertions (active tick = clamped delta, idle tick = 0, first tick = 0).
- Store IO, Dashboard card, navigator: manual on hardware.

## File plan

| File | Change |
|---|---|
| `Sources/QuackKit/TimeAwareness/ActivityHistory.swift` | new, pure |
| `Sources/QuackKit/TimeAwareness/ActivityTracker.swift` | `TickResult` |
| `Sources/Quack/TimeAwareness/ActivityHistoryStore.swift` | new |
| `Sources/Quack/TimeAwareness/TimeAwarenessService.swift` | history feed + saves |
| `Sources/Quack/AppEnvironment.swift` | stats accessors + change forwarding |
| `Sources/Quack/Settings/SettingsView.swift` | Dashboard card + stats section |
| `Sources/Quack/Log.swift` | `Log.time` |
| `Tests/QuackKitTests/ActivityHistoryTests.swift` | new |
| `Tests/QuackKitTests/ActivityTrackerTests.swift` | TickResult updates |
