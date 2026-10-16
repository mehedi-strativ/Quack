import AppKit
import Combine
import QuackKit

/// Owns the **duck** menu-bar item (icon only); clicking it opens Settings. The
/// CPU-temperature and activity-timer items are separate controllers; this
/// keeps each piece as its own menu-bar element.
@MainActor
final class StatusItemController {
    private let env: AppEnvironment
    private let duckItem: NSStatusItem
    private var cancellable: AnyCancellable?

    init(env: AppEnvironment) {
        self.env = env
        duckItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Stable name so the user's ⌘-drag arrangement persists. (macOS controls
        // the actual order; an app can't force absolute position.)
        duckItem.autosaveName = "quack.duck"

        if let button = duckItem.button {
            button.image = DuckImage.template(height: 11)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(openSettings)
            button.setAccessibilityLabel("Quack settings")
        }

        cancellable = env.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateVisibility() } }
        updateVisibility()
    }

    private func updateVisibility() {
        duckItem.isVisible = !env.settingsStore.settings.hideDuckIcon
    }

    @objc private func openSettings() {
        env.showSettings()
    }
}
