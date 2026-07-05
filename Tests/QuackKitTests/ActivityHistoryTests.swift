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
