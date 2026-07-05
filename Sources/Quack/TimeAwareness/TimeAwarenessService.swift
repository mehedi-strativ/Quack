import AppKit
import CoreGraphics
import QuackKit

/// Drives Time Awareness: a 1 Hz tick reads system idle time and the frontmost
/// app, feeds the pure `ActivityTracker`, updates the status item, and shows
/// break-reminder toasts. Sleep and screen-lock stop accumulation immediately,
/// but the K-minute reset threshold is still only crossed after K real
/// minutes away — see `tickNow()`. Zero permissions — idle comes from
/// `CGEventSource.secondsSinceLastEventType`, no event taps.
@MainActor
final class TimeAwarenessService: ObservableObject, ManagedService {
    /// Set by AppEnvironment after construction (opens the Settings window).
    var onOpenSettings: (() -> Void)?

    private let settings: SettingsStore
    private let toasts: ToastPresenter
    private var tracker = ActivityTracker()
    private let statusItem = TimeAwarenessStatusItem()

    private let historyStore = ActivityHistoryStore()
    /// In-memory day aggregates; today's entry includes the live session.
    private(set) var history = ActivityHistory()
    private var lastSavedAt = Date.distantPast
    private var historyDirty = false
    private var terminateObserver: NSObjectProtocol?

    private var timer: Timer?
    private var forcedIdleSince: Date?
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

        history = historyStore.load()
        history.prune(keepDays: 30, today: Date(), calendar: .current)

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

        // Sleep / screen-lock => forced idle since first observed (see tickNow()
        // for how this is turned into an idle reading; the delta clamp keeps
        // the gap itself from ever counting as active).
        let wnc = NSWorkspace.shared.notificationCenter
        let sleepOn: [Notification.Name] = [NSWorkspace.willSleepNotification,
                                            NSWorkspace.screensDidSleepNotification]
        let sleepOff: [Notification.Name] = [NSWorkspace.didWakeNotification,
                                             NSWorkspace.screensDidWakeNotification]
        for name in sleepOn {
            workspaceObservers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.forcedIdleSince = self.forcedIdleSince ?? Date()
                }
            })
        }
        for name in sleepOff {
            workspaceObservers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { [weak self] in self?.forcedIdleSince = nil }
            })
        }
        let dnc = DistributedNotificationCenter.default()
        distributedObservers.append(dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.forcedIdleSince = self.forcedIdleSince ?? Date()
            }
        })
        distributedObservers.append(dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { [weak self] in self?.forcedIdleSince = nil } })

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickNow() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in self?.saveHistoryNow() }
        }
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
        saveHistoryNow()
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
        statusItem.hide()
        tracker.reset()
        forcedIdleSince = nil
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
        let idle = IdleReport.effectiveIdle(realIdle: Self.systemIdleSeconds(),
                                            forcedIdleSince: forcedIdleSince,
                                            now: Date())
        let front = NSWorkspace.shared.frontmostApplication
        let result = tracker.tick(now: Date(),
                                  idleSeconds: idle,
                                  frontmostBundleID: front?.bundleIdentifier,
                                  frontmostName: front?.localizedName,
                                  config: config)
        let now = Date()
        if result.activeDelta > 0 {
            history.record(date: now, calendar: .current,
                           activeDelta: result.activeDelta,
                           bundleID: front?.bundleIdentifier,
                           name: front?.localizedName)
            historyDirty = true
        }
        for event in result.events {
            switch event {
            case .reminderDue(let activeSeconds):
                showBreakToast(activeSeconds: activeSeconds)
            case .restCompleted:
                history.recordBreak(date: now, calendar: .current)
                saveHistoryNow()   // breaks are rare — persist immediately
            }
        }
        render()
        if historyDirty, Date().timeIntervalSince(lastSavedAt) >= 60 {
            saveHistoryNow()
        }
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
        objectWillChange.send()
    }

    /// Prunes and writes the history file; cheap enough for the 1/min cadence.
    private func saveHistoryNow() {
        history.prune(keepDays: 30, today: Date(), calendar: .current)
        historyStore.save(history)
        lastSavedAt = Date()
        historyDirty = false
    }
}
