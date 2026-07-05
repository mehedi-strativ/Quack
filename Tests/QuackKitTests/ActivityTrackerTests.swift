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

    @Test func idleBeyondKResets() {
        var a = ActivityTracker()
        _ = a.tick(now: t0, idleSeconds: 0, frontmostBundleID: nil, frontmostName: nil, config: cfg)
        _ = run(&a, from: t0, seconds: 120)
        let events = a.tick(now: t0.addingTimeInterval(121), idleSeconds: 100_000,
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

@Suite struct IdleReportTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    @Test func unlockedPassesRealIdleThrough() {
        #expect(IdleReport.effectiveIdle(realIdle: 12, forcedIdleSince: nil, now: t0) == 12)
    }
    @Test func justLockedSkipsGraceButNotMore() {
        // 10 s after lock: at least the 60 s grace (stops accumulation), but
        // nowhere near a K-minute reset.
        let idle = IdleReport.effectiveIdle(realIdle: 10, forcedIdleSince: t0.addingTimeInterval(-10), now: t0)
        #expect(idle == 60)
    }
    @Test func lockedKMinutesReportsExactlyKMinutes() {
        // 5 real minutes after lock: reports 300 — the K=5 threshold is crossed
        // at exactly K minutes, not K-1.
        let idle = IdleReport.effectiveIdle(realIdle: 290, forcedIdleSince: t0.addingTimeInterval(-300), now: t0)
        #expect(idle == 300)
    }
    @Test func realIdleDominatesWhenLonger() {
        // Idle long before locking: real idle is the ground truth.
        let idle = IdleReport.effectiveIdle(realIdle: 500, forcedIdleSince: t0.addingTimeInterval(-30), now: t0)
        #expect(idle == 500)
    }
}
