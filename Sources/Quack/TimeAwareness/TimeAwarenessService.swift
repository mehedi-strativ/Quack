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
