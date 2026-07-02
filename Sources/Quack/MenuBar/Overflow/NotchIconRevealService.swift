import AppKit
import SwiftUI
import QuackKit

/// Wires the notch reveal feature together: owns the always-present panel at the
/// notch, positions it on the built-in screen, and on hover runs an on-demand
/// scan → mirror → render, forwarding taps to the real hidden items.
///
/// Lifecycle follows `TemperatureStatusItem`: the panel is created once and
/// shown/hidden via `orderFront`/`orderOut` rather than recreated. No event tap
/// is installed (hover is SwiftUI `.onHover`), so the CLAUDE.md freeze rules do
/// not apply; the only Accessibility dependency is the click-forward, which
/// simply no-ops when AX is not granted.
@MainActor
final class NotchIconRevealService: NSObject, ManagedService {
    private let settings: SettingsStore
    private let permissions: PermissionsManager

    private let reader = NotchScreenReader()
    private let model = NotchViewModel()
    private var panel: NotchPanel?

    /// Collapsed panel height (bare hover sliver at the notch height ~ menu bar).
    private let collapsedHeight: CGFloat = 24
    /// Expanded panel height (room for a row of mirrored icons below the notch).
    private let expandedHeight: CGFloat = 40

    /// Guards `requestScreenRecording()` (a TCC prompt) so it fires at most
    /// once per service lifetime, not on every hover-in while ungranted.
    private var hasRequestedScreenRecording = false

    init(settings: SettingsStore, permissions: PermissionsManager) {
        self.settings = settings
        self.permissions = permissions
        super.init()
    }

    func start() {
        guard reader.currentLayout() != nil else {
            // No built-in notch → feature inert; still observe in case a notched
            // screen is (re)connected while enabled.
            reader.onChange = { [weak self] in self?.repositionOrTeardown() }
            reader.startObserving()
            return
        }
        buildPanelIfNeeded()
        model.onHoverChange = { [weak self] hovering in self?.handleHover(hovering) }
        model.onTap = { [weak self] item in self?.handleTap(item) }
        reader.onChange = { [weak self] in self?.repositionOrTeardown() }
        reader.startObserving()
        reposition()
    }

    func stop() {
        reader.stopObserving()
        reader.onChange = nil
        panel?.orderOut(nil)
        panel = nil
        model.isOpen = false
        model.items = []
    }

    // MARK: - Panel lifecycle

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        // Placeholder frame; reposition() immediately sets the real notch-derived frame.
        let p = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: collapsedHeight))
        let host = NSHostingView(rootView: NotchRevealView(model: model))
        host.frame = p.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(host)
        panel = p
    }

    /// Re-place the panel at the current notch, or tear down if the built-in
    /// notch went away (e.g. clamshell / display change).
    private func repositionOrTeardown() {
        guard reader.currentLayout() != nil else {
            panel?.orderOut(nil)
            model.isOpen = false
            return
        }
        buildPanelIfNeeded()
        reposition()
    }

    /// Positions the panel centered on the notch, its top flush with the screen
    /// top. Width grows when open so a row of icons has room; stays notch-width
    /// when collapsed. Cocoa (Y-up) coordinates.
    private func reposition() {
        guard let layout = reader.currentLayout(), let panel else { return }
        let width = model.isOpen ? max(layout.span.width, contentWidth()) : layout.span.width
        let height = model.isOpen ? expandedHeight : collapsedHeight
        let centerX = layout.cocoaNotchRect.midX
        let originX = centerX - width / 2
        let originY = layout.screen.frame.maxY - height   // top-anchored
        panel.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    private func contentWidth() -> CGFloat {
        // ~28pt per icon (18pt image + spacing) plus horizontal padding.
        CGFloat(model.items.count) * 28 + 32
    }

    // MARK: - Interaction

    private func handleHover(_ hovering: Bool) {
        guard hovering else {
            model.isOpen = false
            model.items = []
            reposition()
            return
        }

        // Refresh permissions non-invasively; prompt for Screen Recording
        // once if missing (the pixel mirror needs it). The prompt itself
        // (`requestScreenRecording`, a TCC call) is gated to fire at most
        // once per service lifetime — repeat hovers only refresh status.
        permissions.refreshScreenRecording()
        if permissions.status(for: .screenRecording) != .granted, !hasRequestedScreenRecording {
            hasRequestedScreenRecording = true
            _ = permissions.requestScreenRecording()
        }

        // Expand immediately so the panel animates open without waiting on the
        // scan. The notch layout is read here on the main actor (an `NSScreen`
        // read); the window-list enumeration and per-item pixel captures then run
        // on a background queue — they are thread-safe system reads that touch no
        // main-actor state, and doing them synchronously here hitched the expand
        // animation. Results flow back onto `model.items` on the main actor via
        // `@Published` (mirrors `TemperatureStatusItem.refresh`). No event tap or
        // run-loop source is involved, so the CLAUDE.md freeze rules do not apply.
        model.isOpen = true
        reposition()

        guard let layout = reader.currentLayout() else {
            model.items = []
            return
        }
        let notch = layout.span
        let screenXRange = layout.screen.frame.minX...layout.screen.frame.maxX
        DispatchQueue.global(qos: .userInitiated).async {
            let items = Self.scanAndMirror(notch: notch, screenXRange: screenXRange)
            DispatchQueue.main.async { [weak self] in
                // Drop late results if the pointer already left the notch.
                guard let self, self.model.isOpen else { return }
                self.model.items = items
                self.reposition()
            }
        }
    }

    /// Scans for crushed status items and captures a live pixel snapshot of each.
    /// Runs off the main actor: `CGWindowListCopyWindowInfo` /
    /// `CGWindowListCreateImage` are thread-safe and touch no main-actor state, so
    /// the caller runs this on a background queue to keep the hover-in expand
    /// animation smooth. `notch` / `screenXRange` are captured from
    /// `NotchScreenReader.currentLayout()` on the main actor before dispatch.
    private nonisolated static func scanAndMirror(
        notch: NotchGeometry.NotchSpan,
        screenXRange: ClosedRange<CGFloat>
    ) -> [NotchItem] {
        let crushed = StatusItemScanner.scan(notch: notch, screenXRange: screenXRange)
        return crushed.compactMap { item in
            guard let image = StatusItemMirror.snapshot(of: item) else { return nil }
            return NotchItem(id: item.windowID, image: image, source: item)
        }
    }

    private func handleTap(_ item: StatusItemFrame) {
        guard permissions.status(for: .accessibility) == .granted else {
            permissions.requestAccessibilityAccess()
            return
        }
        StatusItemForwarder.forward(to: item)
    }
}
