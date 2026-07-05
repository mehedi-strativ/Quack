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

    public struct TickResult: Equatable, Sendable {
        public var events: [Event]
        /// Seconds of activity this tick contributed (0 when idle or first tick).
        public var activeDelta: TimeInterval
        public init(events: [Event] = [], activeDelta: TimeInterval = 0) {
            self.events = events
            self.activeDelta = activeDelta
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
                              config: Config) -> TickResult {
        let delta: TimeInterval
        if let last = lastTickAt {
            delta = min(max(now.timeIntervalSince(last), 0), Self.maxTickDelta)
        } else {
            delta = 0
        }
        lastTickAt = now

        var events: [Event] = []
        var activeDelta: TimeInterval = 0
        if idleSeconds < Self.activityGraceSeconds {
            activeSeconds += delta
            activeDelta = delta
            if delta > 0, let id = frontmostBundleID {
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
                  activeSeconds > 0 {
            events.append(.restCompleted)
            reset()
        }
        return TickResult(events: events, activeDelta: activeDelta)
    }

    /// Clears all counters and the reminder schedule. Keeps `lastTickAt` so the
    /// next tick's delta stays continuous.
    public mutating func reset() {
        activeSeconds = 0
        perAppSeconds = [:]
        appNames = [:]
        lastReminderAt = nil
    }

    /// Top `n` apps by active time, ties broken by name then bundleID.
    public func topApps(_ n: Int) -> [AppSlice] {
        let slices = perAppSeconds.map { (id: String, seconds: TimeInterval) -> AppSlice in
            AppSlice(bundleID: id, name: appNames[id] ?? id, seconds: seconds)
        }
        let sorted = slices.sorted { (a: AppSlice, b: AppSlice) -> Bool in
            if a.seconds != b.seconds { return a.seconds > b.seconds }
            if a.name != b.name { return a.name < b.name }
            return a.bundleID < b.bundleID
        }
        return Array(sorted.prefix(n))
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

/// Maps the service's raw idle signals to the value fed into
/// `ActivityTracker.tick`. While the screen is locked / the Mac is asleep,
/// idle is at least the 60 s activity grace (accumulation stops immediately)
/// and at least the real time since the lock began — so the K-minute reset
/// threshold is crossed after K real minutes away, never earlier.
public enum IdleReport {
    public static func effectiveIdle(realIdle: Double,
                                     forcedIdleSince: Date?,
                                     now: Date) -> Double {
        guard let since = forcedIdleSince else { return realIdle }
        return max(realIdle, 60, now.timeIntervalSince(since))
    }
}
