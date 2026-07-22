import AppKit
import SwiftUI
import Combine

/// Owns a real `NSWindow` for settings (instead of SwiftUI's `Settings` scene,
/// whose open behavior is unreliable for an `.accessory` app). Hosts the whole
/// `SettingsRootView` (header + tabs + pane) and always comes to the front.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private weak var env: AppEnvironment?
    private var tabObserver: AnyCancellable?

    func show(env: AppEnvironment) {
        self.env = env
        if window == nil { buildWindow(env: env) }
        // Quack is `.accessory` (menu-bar-only, see Info.plist) the rest of the
        // time, but this is a real, substantial window — promote to `.regular`
        // while it's open so it gets a Dock icon, an app-menu name, and Cmd-Tab
        // like any normal window; the close observer below drops it back.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func buildWindow(env: AppEnvironment) {
        let hosting = NSHostingController(rootView: SettingsRootView().environmentObject(env))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // The title bar shows the active tab name (kept in sync below); the
        // logo/app name live in the sidebar instead, so this stays transparent.
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // Resizable within sane bounds; the SwiftUI root sets its own ideal size.
        window.setContentSize(NSSize(width: 780, height: 640))
        window.contentMinSize = NSSize(width: 720, height: 560)
        window.contentMaxSize = NSSize(width: 1100, height: 1000)
        window.center()
        window.title = env.settingsTab.title
        tabObserver = env.$settingsTab.sink { [weak window] tab in window?.title = tab.title }
        self.window = window
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in NSApp.setActivationPolicy(.accessory) }
    }
}
