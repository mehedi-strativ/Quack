import AppKit
import Combine
import QuackKit

/// Keeps Quack's own status items usable when the physical notch compresses
/// the menu bar. Hidden entries are rendered by the existing notch panel, so
/// this never scans, screenshots, or forwards events to another app.
@MainActor
final class MenuBarOverflowService: ObservableObject {
    struct Item: Identifiable {
        let id: String
        var title: String
        var systemImage: String?
        var image: NSImage?
        let priority: Int
        let statusItem: NSStatusItem
        let activate: () -> Void
        var isAvailable = true
        var isManagedHidden = false

        var identifier: String { id }
    }

    @Published private(set) var hiddenItems: [Item] = []

    private var entries: [String: Item] = [:]
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var started = false
    private var revealCandidate: String?
    private var clearTicks = 0

    func start() {
        guard !started else { return }
        started = true
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }

        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        reconcile()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        for id in entries.keys {
            entries[id]?.isManagedHidden = false
            entries[id]?.statusItem.isVisible = entries[id]?.isAvailable ?? false
        }
        started = false
        revealCandidate = nil
        clearTicks = 0
        publishHiddenItems()
    }

    func register(id: String, title: String, systemImage: String? = nil,
                  image: NSImage? = nil, priority: Int, statusItem: NSStatusItem,
                  activate: @escaping () -> Void) {
        entries[id] = Item(id: id, title: title, systemImage: systemImage,
                           image: image, priority: priority, statusItem: statusItem,
                           activate: activate)
        statusItem.isVisible = true
        if started { reconcile() }
    }

    func update(id: String, title: String? = nil, image: NSImage? = nil) {
        guard var item = entries[id] else { return }
        if let title { item.title = title }
        if let image { item.image = image }
        entries[id] = item
        publishHiddenItems()
    }

    /// Updates visibility owned by the source feature. A manager-hidden item
    /// stays hidden in AppKit until the overflow policy explicitly reveals it.
    func setSourceVisible(_ visible: Bool, id: String) {
        guard var item = entries[id] else { return }
        item.isAvailable = visible
        if !visible {
            item.isManagedHidden = false
        }
        entries[id] = item
        item.statusItem.isVisible = visible && !item.isManagedHidden
        publishHiddenItems()
        if started { reconcile() }
    }

    private func reconcile() {
        guard started else { return }
        guard let notch = currentNotchSpan() else {
            revealCandidate = nil
            clearTicks = 0
            showAllManagedItems()
            return
        }

        let policyItems = entries.values.map {
            MenuBarOverflowPolicy.Item(
                id: $0.id, priority: $0.priority, isAvailable: $0.isAvailable,
                isManagedHidden: $0.isManagedHidden,
                frameMinX: settledFrameMinX(for: $0.statusItem)
            )
        }

        switch MenuBarOverflowPolicy.nextAction(items: policyItems, notch: notch) {
        case .hide(let id):
            revealCandidate = nil
            clearTicks = 0
            guard var item = entries[id], item.isAvailable else { return }
            item.isManagedHidden = true
            item.statusItem.isVisible = false
            entries[id] = item
            publishHiddenItems()

        case .reveal(let id):
            guard let item = entries[id], item.isManagedHidden else { return }
            if revealCandidate == id {
                clearTicks += 1
            } else {
                revealCandidate = id
                clearTicks = 1
            }
            guard clearTicks >= 2 else { return }
            var updated = item
            updated.isManagedHidden = false
            updated.statusItem.isVisible = true
            entries[id] = updated
            revealCandidate = nil
            clearTicks = 0
            publishHiddenItems()

        case .none:
            revealCandidate = nil
            clearTicks = 0
        }
    }

    private func showAllManagedItems() {
        var changed = false
        for id in entries.keys {
            guard var item = entries[id], item.isManagedHidden else { continue }
            item.isManagedHidden = false
            item.statusItem.isVisible = item.isAvailable
            entries[id] = item
            changed = true
        }
        if changed { publishHiddenItems() }
    }

    private func publishHiddenItems() {
        hiddenItems = entries.values
            .filter { $0.isAvailable && $0.isManagedHidden }
            .sorted { $0.priority > $1.priority }
    }

    private func currentNotchSpan() -> NotchGeometry.NotchSpan? {
        // Quack's notch panel and menu-bar items are scoped to the built-in
        // display. External screens do not affect this overflow decision.
        let screen = NSScreen.screens.first(where: { $0.isBuiltIn })
        guard let screen,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        return NotchGeometry.notchSpan(
            screenMinX: screen.frame.minX,
            screenWidth: screen.frame.width,
            leftAuxWidth: left.width,
            rightAuxWidth: right.width
        )
    }

    private func settledFrameMinX(for item: NSStatusItem) -> CGFloat? {
        guard let frame = item.button?.window?.frame,
              frame.width > 1, frame.height > 1,
              frame.maxY > 0 else { return nil }
        return frame.minX
    }
}
