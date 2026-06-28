import AppKit
import CoreGraphics
import Combine
import QuackKit

/// Global keyboard shortcuts for window management: the configured modifier
/// (default ⌘⌥) + arrow keys. The key tap runs on a dedicated thread (so it can
/// never freeze input); on a match the window action is dispatched to the main
/// actor and the key is consumed. Requires Accessibility permission.
@MainActor
final class HotkeyMonitor: ManagedService {
    private let settings: SettingsStore
    private let permissions: PermissionsManager

    private var tap: EventTapThread?
    private var started = false
    private var settingsCancellable: AnyCancellable?
    private var axObserver: NSObjectProtocol?

    // Modifier bitmask snapshot, read on the tap thread.
    private let modLock = NSLock()
    nonisolated(unsafe) private var modifierMask = 0

    // Arrow key codes.
    private static let keyLeft: Int64 = 123, keyRight: Int64 = 124, keyDown: Int64 = 125, keyUp: Int64 = 126

    init(settings: SettingsStore, permissions: PermissionsManager) {
        self.settings = settings
        self.permissions = permissions
    }

    func start() {
        started = true
        refreshModifierSnapshot()
        settingsCancellable = settings.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.refreshModifierSnapshot() } }

        if permissions.status(for: .accessibility) == .granted {
            reinstallTap()
        } else {
            permissions.requestAccessibilityAccess()
        }

        // Stop + recreate the tap on any Accessibility change (MonitorControl's
        // proven pattern — see CursorBrightnessService). Prevents the
        // toggle-Accessibility freeze.
        axObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Task { @MainActor in self?.reinstallTap() }
            }
        }
    }

    func stop() {
        started = false
        settingsCancellable = nil
        if let axObserver { DistributedNotificationCenter.default().removeObserver(axObserver) }
        axObserver = nil
        tap?.stop()
        tap = nil
    }

    private func refreshModifierSnapshot() {
        let m = settings.settings.windowShortcutModifiers
        modLock.lock(); modifierMask = m; modLock.unlock()
    }

    /// Fully tears down any existing tap and creates a fresh one. Ungated:
    /// `tapCreate` succeeds only when Accessibility is actually trusted.
    private func reinstallTap() {
        guard InputTaps.hotkey, started else { return }
        tap?.stop()
        let t = EventTapThread(
            mask: 1 << CGEventType.keyDown.rawValue,
            options: .defaultTap,
            label: "com.quack.hotkeyTap"
        ) { [weak self] type, event in
            self?.handle(type: type, event: event) ?? Unmanaged.passUnretained(event)
        }
        tap = t
        t.start()
    }

    /// Runs on the tap thread. Decides synchronously whether to consume; the
    /// actual window move is dispatched to the main actor.
    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)
        guard type == .keyDown else { return passthrough }

        modLock.lock(); let mask = modifierMask; modLock.unlock()
        let required = Self.flags(from: mask)
        guard !required.isEmpty else { return passthrough }   // never hijack plain arrows
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard event.flags.intersection(relevant) == required else { return passthrough }

        let arrow: ScreenGeometry.ArrowKey
        switch event.getIntegerValueField(.keyboardEventKeycode) {
        case Self.keyUp: arrow = .up
        case Self.keyDown: arrow = .down
        case Self.keyLeft: arrow = .left
        case Self.keyRight: arrow = .right
        default: return passthrough
        }

        DispatchQueue.main.async {
            if let window = AXHelpers.focusedWindow() {
                WindowMover.applyArrow(arrow, window: window)
            }
        }
        return nil   // consume — we handled it
    }

    private nonisolated static func flags(from mask: Int) -> CGEventFlags {
        var flags = CGEventFlags()
        if mask & 0b0001 != 0 { flags.insert(.maskCommand) }
        if mask & 0b0010 != 0 { flags.insert(.maskAlternate) }
        if mask & 0b0100 != 0 { flags.insert(.maskControl) }
        if mask & 0b1000 != 0 { flags.insert(.maskShift) }
        return flags
    }
}
