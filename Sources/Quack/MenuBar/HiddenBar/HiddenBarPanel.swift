import AppKit
import SwiftUI

/// Borderless, non-activating panel that overlays the menu-bar strip and renders
/// the hidden items. Level above the menu bar, transparent so the strip aligns
/// with the primary bar behind it. No CGEvent tap; it receives mouse events
/// natively for its own hover lifecycle.
@MainActor
final class HiddenBarPanel {
    private let panel: NSPanel
    private var host: NSHostingView<HiddenBarView>?
    var onPanelHover: () -> Void = {}
    var onPanelExit: () -> Void = {}

    init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false   // no floating-card shadow; blend into the bar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    var isVisible: Bool { panel.isVisible }

    func show(view: HiddenBarView, frame: CGRect) {
        let host = NSHostingView(rootView: view)
        self.host = host

        // Behind-window blur (menu-bar vibrancy) rendered under the transparent
        // SwiftUI host, so the strip frosts the desktop/menu bar behind it.
        let blur = NSVisualEffectView()
        blur.material = .menu
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 8
        blur.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
        ])

        panel.contentView = TrackingContainer(content: blur, enter: onPanelHover, exit: onPanelExit)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

/// Hosts the SwiftUI view and reports hover for the whole panel area.
private final class TrackingContainer: NSView {
    private let enter: () -> Void
    private let exit: () -> Void
    init(content: NSView, enter: @escaping () -> Void, exit: @escaping () -> Void) {
        self.enter = enter; self.exit = exit
        super.init(frame: .zero)
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }
    override func mouseEntered(with event: NSEvent) { enter() }
    override func mouseExited(with event: NSEvent) { exit() }
}
