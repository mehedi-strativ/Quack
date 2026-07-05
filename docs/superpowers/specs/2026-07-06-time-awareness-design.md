# Time Awareness — Design Spec

- **Date:** 2026-07-06
- **Status:** Approved (design), not yet implemented
- **Branch:** `Pandan` (synced to main 2599a56)
- **Inspiration:** Pandan (apps.apple.com id1569600264) — continuous-usage
  timer + break reminders

## Problem

Nothing tells the user how long they've been working without a break. Wanted:
a menu-bar timer of continuous Mac activity (with a per-app breakdown) and
configurable reminders to rest, which reset once a real break is taken.

## Goals (v1)

- **Menu-bar activity timer**: own status item — hourglass icon + compact
  elapsed time ("47m", "1h 23m") of continuous activity since the last real
  break.
- **Per-app breakdown**: click the item → menu showing total since last break
  and the top 5 apps by active time ("Safari — 32m").
- **Rest reminders**: toast after N minutes of continuous activity, repeating
  every further M minutes until a break happens. Every duration configurable:
  - N `activityReminderMinutes` — remind after (default 50, range 10–120)
  - M `activityRepeatMinutes` — repeat while ignored (default 10, range 5–60)
  - K `activityIdleResetMinutes` — idle needed to count as a rest and reset
    the timer (default 5, range 1–30)
- **Rest detection**: K consecutive minutes of system idle (no input) resets
  total + per-app times. Sleep/screen-lock counts toward idle immediately.
- Menu actions: **Reset Timer** (manual reset), **Open Settings…** (deep-link
  to the Time Awareness tab).
- Settings tab "Time Awareness" (Menu Bar sidebar group): master toggle,
  rest-reminders toggle, the three duration controls.
- **Zero permissions**: idle time via `CGEventSource.secondsSinceLastEventType`
  (combined session state), frontmost app via `NSWorkspace`. No event taps.

## Non-goals (v1)

- No historical stats/daily totals/persistence across app relaunches (timer
  state is in-memory; relaunch = fresh timer).
- No per-app reminder rules, no schedules (work hours), no pomodoro modes.
- No blocking/enforced breaks (reminder is a toast, nothing locks).
- No website-level tracking (app granularity only).
- No menu-bar countdown-to-break display — elapsed time only.

## Architecture

Poll-based: a 1 Hz tick feeds a pure reducer. No event taps, no Accessibility.

| Unit | Where | Role |
|---|---|---|
| `ActivityTracker` | QuackKit (pure) | all state + transition rules, unit-tested |
| `TimeAwarenessService` | app, `ManagedService` | 1 Hz tick, system signals, toasts, owns status item |
| `TimeAwarenessStatusItem` | app | NSStatusItem + menu rendering |
| Settings fields + `Feature.timeAwareness` | QuackKit | persistence + coordinator gating |

### Settings model (QuackKit)

`QuackSettings` additions (defaults per the four-part pattern):

```swift
public var timeAwarenessEnabled: Bool          // false
public var restRemindersEnabled: Bool          // true
public var activityReminderMinutes: Int        // 50  (N)
public var activityRepeatMinutes: Int          // 10  (M)
public var activityIdleResetMinutes: Int       // 5   (K)
```

`Feature.timeAwareness` — enabled iff `timeAwarenessEnabled`.

### Unit 1 — `ActivityTracker` (pure QuackKit)

```swift
public struct ActivityTracker {
    public struct Config: Equatable {
        public var reminderMinutes: Int     // N
        public var repeatMinutes: Int       // M
        public var idleResetMinutes: Int    // K
        public var remindersEnabled: Bool
    }
    public enum Event: Equatable {
        case reminderDue(activeSeconds: TimeInterval)
        case restCompleted
    }
    public struct AppSlice: Equatable {
        public var bundleID: String
        public var name: String
        public var seconds: TimeInterval
    }

    public private(set) var activeSeconds: TimeInterval
    public mutating func tick(now: Date,
                              idleSeconds: Double,
                              frontmostBundleID: String?,
                              frontmostName: String?,
                              config: Config) -> [Event]
    public mutating func reset()                 // manual "Reset Timer"
    public func topApps(_ n: Int) -> [AppSlice]
}
```

Transition rules (config read per tick, so settings changes apply live):

- **Active tick** (`idleSeconds < 60`): add the elapsed wall-clock delta since
  the previous tick (clamped to 0…5 s so sleeps/pauses can't teleport time)
  to `activeSeconds` and to the frontmost app's slice. Unknown frontmost
  (nil) accumulates total only.
- **Idle tick** (`idleSeconds >= 60`): accumulate nothing. If continuous idle
  reaches K minutes (tracked via `idleSeconds` itself — the system counter is
  already continuous) and the timer was nonzero → emit `.restCompleted` once
  and reset total, per-app, and reminder bookkeeping.
- **Forced idle** (sleep/lock): the service reports idle as at-least
  (time since lock/sleep began + the 60 s activity grace), never infinity —
  so accumulation stops on the very first locked tick (past the grace
  immediately), but the K-minute reset threshold is still only crossed after
  K real minutes away. Stepping away briefly and unlocking before K minutes
  no longer erases the session (the 0…5 s delta clamp still guarantees the
  gap itself never counts as activity).
- **Reminders** (`config.remindersEnabled`): when `activeSeconds` crosses
  N minutes → emit `.reminderDue` once; while activity continues without a
  rest, re-emit each further M minutes (N, N+M, N+2M…). Reset clears the
  schedule.
- **The 60 s activity grace**: `idleSeconds < 60` counts as "still active" so
  reading/watching without input isn't chopped into micro-sessions; only
  sustained idle (60 s+) pauses accumulation, and only K min of it resets.
  (K=1 therefore means: reset as soon as the 60 s grace is exhausted —
  i.e. effectively resets after 1 min of true idle.)

### Unit 2 — `TimeAwarenessService` (app, ManagedService)

- `start()`: create status item; start 1 Hz `Timer` on the main run loop in
  `.common` mode (same pattern as `AppEnvironment`'s countdown clock);
  subscribe to `NSWorkspace.willSleepNotification`,
  `NSWorkspace.screensDidSleepNotification` and the
  `"com.apple.screenIsLocked"` distributed notification (record
  `forcedIdleSince = forcedIdleSince ?? Date()` on lock/sleep — don't restart
  the clock if already set; cleared to `nil` on the wake/unlock counterparts).
- Each tick: `idle = IdleReport.effectiveIdle(realIdle: systemIdleSeconds(),
  forcedIdleSince: forcedIdleSince, now: Date())`, where
  `systemIdleSeconds()` reads
  `CGEventSource.secondsSinceLastEventType(.combinedSessionState,
  eventType: kCGAnyInputEventType-equivalent)`, frontmost from
  `NSWorkspace.shared.frontmostApplication` (bundleID + localizedName), call
  `tracker.tick`, then:
  - `.reminderDue(s)` → toast via `ToastPresenter` ("You've been active for
    1h 40m — time for a break 🦆", auto-dismiss ~8 s), respecting
    `restRemindersEnabled` (also enforced inside the reducer via config).
  - `.restCompleted` → nothing user-visible (menu bar simply shows 0m).
  - Refresh status item title when the displayed minute changed.
- `stop()`: timer invalidated, observers removed, status item removed,
  tracker reset.

### Unit 3 — `TimeAwarenessStatusItem` (app)

Mirrors `TemperatureStatusItem`'s shape:

- `NSStatusItem` with hourglass SF symbol + "47m" / "1h 23m" text (minutes
  under an hour; `Xh Ym` from an hour up).
- Menu built on demand (menu delegate / rebuilt on click):
  1. Disabled header row: "Active 1h 23m since last break"
  2. Top 5 `topApps(5)` rows, disabled: "Safari — 32m"
  3. Separator
  4. "Reset Timer" → `tracker.reset()` + immediate title refresh
  5. "Open Settings…" → `onOpenSettings` closure (deep-link
     `.timeAwareness` tab, same wiring as `TemperatureStatusItem`)

### Settings UI

`SettingsTab.timeAwareness` — title "Time Awareness", icon `hourglass`, Menu
Bar sidebar group → `[.calendar, .temperature, .timeAwareness]`. Grouped Form:

1. **Time awareness** — master toggle ("Show an activity timer in the menu
   bar") + caption explaining the timer and the reset rule.
2. **Rest reminders** (visible when enabled) — reminders toggle; steppers:
   "Remind after: N min" (10–120, step 5), "Repeat every: M min" (5–60,
   step 5), "Reset after idle: K min" (1–30, step 1).

## Error handling

- `CGEventSource.secondsSinceLastEventType` never fails (returns a Double);
  frontmost app may be nil → total-only accumulation.
- Wall-clock jumps (manual clock change, long debugger pause): the 0…5 s
  per-tick delta clamp bounds damage to one tick.
- Feature off → coordinator stops service → status item removed; no timers
  left running.
- Toast presentation is fire-and-forget; a failed toast never affects the
  tracker.

## Testing

- `ActivityTrackerTests` (pure, fake clock): accumulation math + delta clamp;
  60 s grace behavior; idle pause; K-reset emits `.restCompleted` exactly
  once; N then N+M, N+2M reminder cadence; cadence with live config change
  mid-run; `remindersEnabled=false` emits nothing; per-app attribution +
  `topApps` ordering/limit; manual `reset()`; forced-idle (∞) path; sleep
  gap doesn't count as activity.
- Settings decode-with-defaults + round-trip for the 5 new fields.
- `Feature.timeAwareness` enablement test.
- Status item, menu, toasts, real idle detection: manual on-hardware.

## File plan

| File | Change |
|---|---|
| `Sources/QuackKit/Models/QuackSettings.swift` | 5 new fields |
| `Sources/QuackKit/TimeAwareness/ActivityTracker.swift` | new, pure |
| `Sources/QuackKit/Coordinator/ManagedService.swift` | `Feature.timeAwareness` |
| `Sources/Quack/TimeAwareness/TimeAwarenessService.swift` | new |
| `Sources/Quack/TimeAwareness/TimeAwarenessStatusItem.swift` | new |
| `Sources/Quack/AppEnvironment.swift` | construct + register + deep-link |
| `Sources/Quack/Settings/SettingsView.swift` | tab + sections |
| `Tests/QuackKitTests/ActivityTrackerTests.swift` | new |
| `Tests/QuackKitTests/SettingsStoreTests.swift` | append |
| `Tests/QuackKitTests/ActivityTrackerTests.swift` | also holds the `Feature.timeAwareness` enablement suite |
