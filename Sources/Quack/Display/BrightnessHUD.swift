import AppKit
import SwiftUI

/// A floating on-screen brightness overlay that mimics the native macOS
/// brightness HUD, shown on the external display being adjusted. Auto-hides
/// after a short delay.
@MainActor
final class BrightnessHUD {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private let model = BrightnessHUDModel()

    func show(displayName: String, level: Double, on screen: NSScreen?) {
        model.displayName = displayName
        model.level = max(0, min(1, level))

        let panel = ensurePanel()
        position(panel, on: screen)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        scheduleHide(panel)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: BrightnessHUDView(model: model))
        host.frame = p.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(host)
        panel = p
        return p
    }

    private func position(_ panel: NSPanel, on screen: NSScreen?) {
        // Top-right of the target screen, just inside the menu-bar area.
        guard let frame = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = panel.frame.size
        let margin: CGFloat = 16
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - size.width - margin,
            y: frame.maxY - size.height - margin
        ))
    }

    private func scheduleHide(_ panel: NSPanel) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                panel.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }
}

final class BrightnessHUDModel: ObservableObject {
    @Published var displayName: String = ""
    @Published var level: Double = 0
}

private struct BrightnessHUDView: View {
    @ObservedObject var model: BrightnessHUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            HStack(spacing: 10) {
                Image(systemName: "sun.min.fill").font(.system(size: 13)).foregroundStyle(.primary)
                BrightnessSlider(level: model.level)
                Image(systemName: "sun.max.fill").font(.system(size: 18)).foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 300, alignment: .leading)
        .background(HUDBackground())
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

/// The tall, pill-shaped brightness track with tick marks and a white fill,
/// matching the macOS Control Center "Display" slider.
private struct BrightnessSlider: View {
    let level: Double
    private let ticks = 16

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let fill = max(h, geo.size.width * CGFloat(min(max(level, 0), 1)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.20))           // track
                Capsule().fill(Color.white).frame(width: fill)      // filled portion
                // Evenly spaced tick marks across the whole track.
                HStack(spacing: 0) {
                    ForEach(1..<ticks, id: \.self) { _ in
                        Spacer(minLength: 0)
                        Rectangle().fill(Color.black.opacity(0.14)).frame(width: 1.5)
                    }
                    Spacer(minLength: 0)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 26)
    }
}

/// HUD-material blur background.
private struct HUDBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
