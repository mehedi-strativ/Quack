import AppKit

/// Software "sub-zero" dimming: a translucent black overlay per external display
/// that goes darker than the monitor's DDC minimum allows. One borderless,
/// click-through panel per screen; its opacity is the dim amount.
@MainActor
final class DisplayDimmer {
    private var panels: [CGDirectDisplayID: NSPanel] = [:]

    /// Sets the dim overlay for a display. `alpha` 0 = no overlay (fully removed),
    /// up to ~0.7 = quite dark.
    func setOverlay(alpha: Double, for screenNumber: CGDirectDisplayID) {
        let a = max(0, min(0.7, alpha))
        guard let screen = NSScreen.screens.first(where: { $0.displayID == screenNumber }) else { return }

        if a <= 0.001 {
            panels[screenNumber]?.orderOut(nil)
            return
        }
        let panel = panels[screenNumber] ?? makePanel()
        panels[screenNumber] = panel
        panel.setFrame(screen.frame, display: false)
        panel.alphaValue = CGFloat(a)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .black
        p.hasShadow = false
        p.ignoresMouseEvents = true          // click-through; never blocks input
        // Above app windows and the menu bar so the whole screen dims, but below
        // Quack's brightness HUD (which sits one level higher).
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return p
    }
}
