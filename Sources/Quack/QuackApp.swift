import SwiftUI
import AppKit
import QuackKit

@main
struct QuackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Quack has no SwiftUI windows; it lives in a manually-managed
        // NSStatusItem (see AppDelegate) and opens its own settings window.
        // A never-inserted MenuBarExtra just satisfies `App` — unlike an empty
        // `Settings` scene, SwiftUI can't open it as a blank "Quack Settings"
        // window on launch/activation.
        MenuBarExtra("Quack", isInserted: .constant(false)) { EmptyView() }
            .commands {
                // App menu "Settings…" / ⌘, → Quack's real settings window.
                CommandGroup(after: .appInfo) {   // no Settings scene → no .appSettings group to replace
                    Button("Settings…") { appDelegate.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

/// Owns the app environment and the menu-bar status item. We manage a real
/// `NSStatusItem` here rather than a SwiftUI `MenuBarExtra` (which intermittently
/// fails to show its menu-bar icon).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var env: AppEnvironment?
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let env = AppEnvironment()
        self.env = env
        statusController = StatusItemController(env: env)
        env.showSettings()   // open Settings on first launch
    }

    func showSettings() {
        env?.showSettings()
    }

    /// Fires when the app is opened again while already running (Finder/Dock/
    /// `open`). LSUIElement apps get this instead of a fresh launch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        env?.showSettings()
        // Handled. `true` lets AppKit's default reopen run too, which makes
        // SwiftUI open its only scene — the empty placeholder `Settings` window.
        return false
    }
}
