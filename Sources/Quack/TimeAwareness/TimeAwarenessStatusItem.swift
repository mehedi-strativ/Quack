import AppKit
import QuackKit

/// The menu-bar face of Time Awareness: an hourglass + elapsed active time,
/// with a click menu showing the per-app breakdown and actions. Mirrors
/// `TemperatureStatusItem`'s create-once / toggle-visibility pattern.
@MainActor
final class TimeAwarenessStatusItem: NSObject, NSMenuDelegate {
    private let overflow: MenuBarOverflowService
    var onReset: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Pulled when the menu opens (and for renders) — the service owns state.
    var snapshot: (() -> (total: TimeInterval, apps: [ActivityTracker.AppSlice]))?

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    init(overflow: MenuBarOverflowService) {
        self.overflow = overflow
        super.init()
    }

    func show() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "quack.timeawareness"
            if let button = item.button {
                let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                let glass = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Activity timer")?
                    .withSymbolConfiguration(cfg)
                glass?.isTemplate = true
                button.image = glass
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
            }
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            statusItem = item
            overflow.register(
                id: "quack.timeawareness", title: "Activity timer", systemImage: "hourglass", priority: 20,
                statusItem: item, activate: { [weak self] in self?.activate() }
            )
        }
        overflow.setSourceVisible(true, id: "quack.timeawareness")
        render(total: snapshot?().total ?? 0)
    }

    func hide() {
        overflow.setSourceVisible(false, id: "quack.timeawareness")
    }

    func render(total: TimeInterval) {
        guard let button = statusItem?.button else { return }
        button.title = " " + ActivityFormat.compact(total)
        overflow.update(id: "quack.timeawareness", title: button.title.trimmingCharacters(in: .whitespaces))
        tightenWidth(button)
    }

    private func activate() {
        statusItem?.button?.performClick(nil)
    }

    /// Rebuilt on every open so times are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let snap = snapshot?() ?? (total: 0 as TimeInterval, apps: [] as [ActivityTracker.AppSlice])

        let header = NSMenuItem(title: "Active \(ActivityFormat.compact(snap.total)) since last break",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !snap.apps.isEmpty {
            menu.addItem(.separator())
            for slice in snap.apps {
                let row = NSMenuItem(title: "\(slice.name) — \(ActivityFormat.compact(slice.seconds))",
                                     action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            }
        }

        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset Timer", action: #selector(resetTapped), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        let settings = NSMenuItem(title: "Open Settings…", action: #selector(settingsTapped), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    @objc private func resetTapped() { onReset?() }
    @objc private func settingsTapped() { onOpenSettings?() }

    /// Pin the item to content width (same trick as TemperatureStatusItem).
    private func tightenWidth(_ button: NSStatusBarButton) {
        let font = button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let textWidth = (button.title as NSString).size(withAttributes: [.font: font]).width
        let imageWidth = button.image?.size.width ?? 0
        statusItem?.length = ceil(imageWidth + textWidth + 4)
    }
}
