import AppKit
import CoreGraphics
import Combine
import QuackKit

/// Remaps mouse buttons 4 and 5 (`buttonNumber` 3 / 4 — zero-based) to custom
/// actions. The tap runs on a dedicated thread; on a match both the down and
/// up events are consumed and the action fires on the main actor from the
/// down event. Buttons left on "default" pass through untouched, so browser
/// back/forward keeps working. Requires Accessibility permission.
@MainActor
final class MouseButtonService {
    private let settings: SettingsStore
    private let permissions: PermissionsManager

    private var tap: EventTapThread?
    private var started = false
    private var settingsCancellable: AnyCancellable?
    private var axObserver: NSObjectProtocol?

    /// Snapshot of the configured actions, read on the tap thread.
    private struct Config {
        var action4 = MouseButtonAction.default_
        var action5 = MouseButtonAction.default_
        var shortcut4: MouseShortcut?
        var shortcut5: MouseShortcut?
    }
    private let configLock = NSLock()
    nonisolated(unsafe) private var config = Config()

    init(settings: SettingsStore, permissions: PermissionsManager) {
        self.settings = settings
        self.permissions = permissions
    }

    func start() {
        guard !started else { return }
        started = true
        refreshConfigSnapshot()
        settingsCancellable = settings.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.refreshConfigSnapshot() } }

        if permissions.status(for: .accessibility) == .granted {
            reinstallTap()
        } else {
            permissions.requestAccessibilityAccess()
        }

        // Stop + recreate on any Accessibility change (MonitorControl's proven
        // pattern — see CursorBrightnessService / CLAUDE.md).
        axObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Task { @MainActor in self?.reinstallTap() }
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        settingsCancellable = nil
        if let axObserver { DistributedNotificationCenter.default().removeObserver(axObserver) }
        axObserver = nil
        tap?.stop()
        tap = nil
    }

    private func refreshConfigSnapshot() {
        let s = settings.settings
        let c = Config(
            action4: MouseButtonAction.from(s.mouseButton4Action),
            action5: MouseButtonAction.from(s.mouseButton5Action),
            shortcut4: s.mouseButton4Shortcut,
            shortcut5: s.mouseButton5Shortcut
        )
        configLock.lock(); config = c; configLock.unlock()
    }

    /// Fully tears down any existing tap and creates a fresh one. Ungated:
    /// `tapCreate` succeeds only when Accessibility is actually trusted.
    private func reinstallTap() {
        guard InputTaps.mouseButtons, started else { return }
        tap?.stop()
        let mask: CGEventMask =
            (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        let t = EventTapThread(
            mask: mask,
            options: .defaultTap,
            label: "com.quack.mouseButtonTap"
        ) { [weak self] type, event in
            self?.handle(type: type, event: event) ?? Unmanaged.passUnretained(event)
        }
        tap = t
        t.start()
    }

    /// Runs on the tap thread. Decides synchronously whether to consume; the
    /// action itself is dispatched to the main actor.
    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)
        guard type == .otherMouseDown || type == .otherMouseUp else { return passthrough }

        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        configLock.lock(); let c = config; configLock.unlock()

        let action: MouseButtonAction
        let shortcut: MouseShortcut?
        switch button {
        case 3: action = c.action4; shortcut = c.shortcut4
        case 4: action = c.action5; shortcut = c.shortcut5
        default: return passthrough
        }
        guard action != .default_ else { return passthrough }

        if type == .otherMouseDown {
            DispatchQueue.main.async {
                MouseActionPerformer.perform(action, shortcut: shortcut)
            }
        }
        return nil   // consume both down and up
    }
}
