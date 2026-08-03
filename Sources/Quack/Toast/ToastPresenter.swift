import AppKit
import SwiftUI
import QuackKit

/// One toast's content.
struct ToastItem: Identifiable {
    let id = UUID()
    let title: String
    let relativeText: String   // "in 10 min" / "now"
    let timeRange: String      // "4:22 – 5:07 PM"
    let colorHex: String?
    let joinURL: URL?
    let provider: MeetingProvider
    let joinable: Bool         // show the Join button (1-min + on-time reminders)
    let isStart: Bool          // a "join now" toast vs. an advance reminder
}

/// Shows stacked, top-right toast notifications (Notion-Calendar style) as
/// borderless floating panels, independent of the system notification center.
@MainActor
final class ToastPresenter {
    private final class ActiveToast {
        let item: ToastItem
        let panel: NSPanel
        var dismiss: DispatchWorkItem?
        init(item: ToastItem, panel: NSPanel) { self.item = item; self.panel = panel }
    }

    private var toasts: [ActiveToast] = []
    private let width: CGFloat = 380
    private let gap: CGFloat = 10

    /// Shows a toast. When `dismissAfter` is nil the toast persists until the
    /// user joins or closes it (used for the "join now" toast).
    func show(_ item: ToastItem, dismissAfter seconds: TimeInterval?) {
        let panel = makePanel(for: item, autoDismiss: seconds)
        let active = ActiveToast(item: item, panel: panel)
        toasts.insert(active, at: 0)
        reflow()
        // Panel frames are never animated — overlapping in-flight frame
        // animations used to leave two toasts stacked on the same slot. The
        // entrance itself (scale + fade) happens inside `ToastView`.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }

        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.dismiss(active) }
            active.dismiss = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    private func dismiss(_ toast: ActiveToast) {
        toast.dismiss?.cancel()
        guard let idx = toasts.firstIndex(where: { $0 === toast }) else { return }
        toasts.remove(at: idx)
        NSAnimationContext.runAnimationGroup({
            $0.duration = 0.18
            toast.panel.animator().alphaValue = 0
        }, completionHandler: {
            toast.panel.orderOut(nil)
        })
        reflow()
    }

    private func makePanel(for item: ToastItem, autoDismiss: TimeInterval?) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 84),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // Follow the system theme: leaving `appearance` nil inherits the app's
        // effective appearance, so the material, window-background color, and
        // SwiftUI colorScheme all track light/dark mode automatically.
        let view = ToastView(
            item: item,
            autoDismiss: autoDismiss,
            onJoin: { [weak self, weak panel] in
                if let url = item.joinURL { NSWorkspace.shared.open(url) }
                if let panel { self?.dismissPanel(panel) }
            },
            onClose: { [weak self, weak panel] in
                if let panel { self?.dismissPanel(panel) }
            }
        )
        let host = NSHostingView(rootView: view)
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(host)
        // Size to fit the content (including the outer margin that lets the
        // corner ✕ overhang without being clipped).
        let fitting = host.fittingSize
        panel.setContentSize(NSSize(width: max(width, fitting.width), height: max(60, fitting.height)))
        return panel
    }

    private func dismissPanel(_ panel: NSPanel) {
        if let active = toasts.first(where: { $0.panel === panel }) { dismiss(active) }
    }

    /// Re-positions all toasts stacked down from the top-right of the main screen.
    private func reflow() {
        // NSScreen.main can be nil/ambiguous for a background agent app with no
        // key window — fall back to the menu-bar screen so toasts never end up
        // positioned off-screen.
        guard let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        var y = screen.maxY - 16
        for toast in toasts {
            let size = toast.panel.frame.size
            toast.panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: y - size.height))
            y -= size.height + gap
        }
    }
}

private struct ToastView: View {
    let item: ToastItem
    let autoDismiss: TimeInterval?
    let onJoin: () -> Void
    let onClose: () -> Void

    @State private var hovering = false
    @State private var pulsing = false
    @State private var drain: CGFloat = 1
    @State private var appeared = false

    private let radius: CGFloat = 18
    /// Calendar colour when known, otherwise the system accent. One accent for
    /// the whole card — rail, badge, pill and Join button all share it.
    private var accent: Color { Color(hex: item.colorHex) ?? .accentColor }

    var body: some View {
        HStack(spacing: 12) {
            ProviderBadge(provider: item.provider, accent: accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    relativePill
                    Text(item.timeRange)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .fixedSize()   // time line is always shown in full
            }
            Spacer(minLength: 12)
            if item.joinable, item.joinURL != nil {
                JoinButton(provider: item.provider, accent: accent, onJoin: onJoin)
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 13)
        .padding(.vertical, 12)
        // Size to content (up to a cap) so the name and time aren't truncated.
        .frame(minWidth: 300, maxWidth: 480, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        // Calendar-colour rail, like a calendar event chip.
        .overlay(alignment: .leading) {
            Capsule().fill(accent).frame(width: 3).padding(.vertical, 11).padding(.leading, 4)
        }
        .overlay(alignment: .bottom) { drainBar }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) { closeButton }
        // Entrance: springs up to full size from slightly small, so nothing can
        // overflow (and be clipped by) the panel bounds.
        .scaleEffect(appeared ? 1 : 0.93, anchor: .topTrailing)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { appeared = true }
        }
        // Outer margin so the corner-straddling ✕ isn't clipped by the panel.
        .padding(8)
        .onContinuousHover { phase in
            switch phase {
            case .active: hovering = true
            case .ended: hovering = false
            }
        }
    }

    /// "now" / "in 10 min" — a tinted pill, with a pulsing dot once the meeting
    /// is live.
    private var relativePill: some View {
        HStack(spacing: 4.5) {
            if item.isStart {
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
                    .opacity(pulsing ? 0.25 : 1)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                            pulsing = true
                        }
                    }
            }
            Text(item.relativeText)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(accent.opacity(0.16)))
    }

    /// Time-left indicator for auto-dismissing toasts.
    @ViewBuilder private var drainBar: some View {
        if let autoDismiss {
            GeometryReader { geo in
                Capsule()
                    .fill(accent.opacity(0.55))
                    .frame(width: geo.size.width * drain)
            }
            .frame(height: 2.5)
            .onAppear { withAnimation(.linear(duration: autoDismiss)) { drain = 0 } }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Straddle the top-left corner like the native notification ✕.
        .offset(x: -7, y: -7)
        .opacity(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Rounded provider glyph tile.
private struct ProviderBadge: View {
    let provider: MeetingProvider
    let accent: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(accent.opacity(0.14))
            .frame(width: 32, height: 32)
            .overlay(
                Image(systemName: provider.glyph)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
            )
    }
}

/// A filled "Join <provider>" button that opens the meeting.
private struct JoinButton: View {
    let provider: MeetingProvider
    let accent: Color
    let onJoin: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onJoin) {
            HStack(spacing: 6) {
                Image(systemName: "video.fill").font(.system(size: 11, weight: .bold))
                Text(provider.joinLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Capsule().fill(accent.opacity(hovering ? 1 : 0.9)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

private extension MeetingProvider {
    var glyph: String { self == .generic ? "calendar" : "video.fill" }
}

