import AppKit
import SwiftUI

/// Borderless, non-activating panel that hangs under the menu bar and renders
/// the hidden items. Level above the menu bar. No CGEvent tap; it receives
/// mouse events natively for its own hover lifecycle.
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
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    var isVisible: Bool { panel.isVisible }

    func show(view: HiddenBarView, frame: CGRect) {
        let host = NSHostingView(rootView: view)
        self.host = host
        panel.contentView = TrackingContainer(content: host, enter: onPanelHover, exit: onPanelExit)
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
