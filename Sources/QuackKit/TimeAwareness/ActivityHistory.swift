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
