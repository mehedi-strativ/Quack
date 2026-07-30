import AppKit
import Combine

/// Rolling log of recent mouse-button presses, shown live in Settings → Mouse.
///
/// `NSEvent` monitors still see buttons 4/5 even when `MouseButtonService`'s
/// tap consumes them, so this is the only source — logging from that tap too
/// double-counted every remapped press.
@MainActor
final class MouseClickLog: ObservableObject {
    static let shared = MouseClickLog()

    struct Entry: Identifiable {
        let id = UUID()
        let name: String
        let time: String
    }

    @Published private(set) var entries: [Entry] = []

    private var monitors: [Any] = []
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private static let limit = 8

    func startMonitoring() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let button = event.buttonNumber
            Task { @MainActor in self?.record(button: button) }
        })
        let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let button = event.buttonNumber
            Task { @MainActor in self?.record(button: button) }
            return event
        })
        monitors = [global, local].compactMap { $0 }
    }

    func stopMonitoring() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        entries = []
    }

    func clear() { entries = [] }

    private func record(button: Int) {
        entries.insert(Entry(name: Self.name(for: button), time: Self.clock.string(from: Date())), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    private static func name(for button: Int) -> String {
        switch button {
        case 0: return "Mouse Left"
        case 1: return "Mouse Right"
        case 2: return "Mouse Middle"
        default: return "Button \(button + 1)"
        }
    }
}
