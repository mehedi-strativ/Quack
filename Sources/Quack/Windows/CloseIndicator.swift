import AppKit
import SwiftUI

/// A floating "close" badge briefly shown over a Dock icon when a pinch-to-quit
/// gesture fires — the Dock counterpart to `SwipeIndicator`. A white ✕ on a dark
/// circle, centered on the icon.
@MainActor
final class CloseIndicator {
    private var panel: NSPanel?
    private let size: CGFloat = 30
    private var hideWork: DispatchWorkItem?

    /// Flashes the badge centered on `center` (Cocoa global, Y-up), then fades it
    /// out automatically.
    func flash(at center: CGPoint) {
        let panel = ensurePanel()
        panel.setFrameOrigin(NSPoint(x: center.x - size / 2, y: center.y - size / 2))
        hideWork?.cancel()

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.1; panel.animator().alphaValue = 1 }

        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: CloseIndicatorView())
        host.frame = p.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(host)
        panel = p
        return p
    }
}

private struct CloseIndicatorView: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.8))
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: 30, height: 30)
    }
}
