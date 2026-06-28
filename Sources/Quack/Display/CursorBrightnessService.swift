import AppKit
import ApplicationServices
import CoreGraphics
import Combine
import QuackKit

/// Routes the Mac brightness keys (F1/F2) to whichever external display the
/// cursor is on, over DDC — and tracks the active display for the optional
/// "dim inactive display" behavior.
///
/// When the cursor is on an external DDC display, a brightness-key press is
/// applied to that monitor and the event is **consumed** so the built-in
/// display doesn't also change. When the cursor is on the built-in display (or
/// a non-DDC external), keys pass through untouched.
///
/// Consuming key events requires an active event tap, which needs Accessibility
/// permission. Without it, the slider and dim behavior still work; only the
/// F1/F2 routing is unavailable.
@MainActor
final class CursorBrightnessService: ManagedService {
    private let controller: BrightnessController
    private let settings: SettingsStore
    private let permissions: PermissionsManager
    private let diagnostics: DiagnosticsStatus

    private var cursorMonitor: Any?
    private var pollTimer: Timer?
    private var keyTap: BrightnessKeyTap?
    private var lastDisplayID: String?
    private var started = false
    private var permissionCancellable: AnyCancellable?
    private var axObserver: NSObjectProtocol?
    private let hud = BrightnessHUD()

    // Thread-safe snapshot of displays (frame + DDC support) read by the key tap
    // on its background thread; rebuilt on the main actor.
    private let snapshotLock = NSLock()
    nonisolated(unsafe) private var displaySnapshot: [(frame: CGRect, supportsDDC: Bool, id: String, name: String, number: CGDirectDisplayID)] = []

    init(controller: BrightnessController, settings: SettingsStore, permissions: PermissionsManager, diagnostics: DiagnosticsStatus) {
        self.controller = controller
        self.settings = settings
        self.permissions = permissions
        self.diagnostics = diagnostics
    }

    func start() {
        started = true
        controller.refreshDisplays()
        rebuildSnapshot()
        diagnostics.externalDisplayCount = controller.displays.count
        diagnostics.ddcServiceCount = DDCControl.isAppleSilicon ? DDCControl.externalDisplayCount() : 0
        lastDisplayID = nil

        cursorMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.evaluateCursor() }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateCursor() }
        }
        timer.tolerance = 0.1
        pollTimer = timer
        evaluateCursor()

        if permissions.status(for: .accessibility) == .granted {
            reinstallKeyTap()
        } else {
            permissions.requestAccessibilityAccess()
        }

        // On ANY Accessibility change, fully stop and recreate the tap (after a
        // short delay so the TCC transition settles). This is exactly what
        // MonitorControl does — it's the only reliable pattern: never leave a
        // stale active tap alive (a lingering tap reactivated on re-grant freezes
        // input), and don't gate on AXIsProcessTrusted (it returns stale values
        // right after a toggle). `tapCreate` itself returns nil when not trusted.
        axObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Task { @MainActor in self?.reinstallKeyTap() }
            }
        }
    }

    /// Fully tears down any existing tap and creates a fresh one. Ungated:
    /// `BrightnessKeyTap.start()` attempts `tapCreate`, which succeeds only when
    /// Accessibility is actually trusted (and fails gracefully otherwise).
    private func reinstallKeyTap() {
        guard InputTaps.brightness, started else { return }
        keyTap?.stop()
        let tap = BrightnessKeyTap()
        tap.ddcDisplayAt = { [weak self] point in self?.ddcDisplay(at: point) }
        tap.onKey = { [weak self] increase, hit in
            DispatchQueue.main.async { self?.applyKey(increase: increase, hit: hit) }
        }
        keyTap = tap
        tap.start()
        diagnostics.brightnessKeyTapInstalled = AXIsProcessTrusted()
    }

    func stop() {
        started = false
        permissionCancellable = nil
        if let axObserver { DistributedNotificationCenter.default().removeObserver(axObserver) }
        axObserver = nil
        if let cursorMonitor { NSEvent.removeMonitor(cursorMonitor) }
        cursorMonitor = nil
        pollTimer?.invalidate()
        pollTimer = nil
        keyTap?.stop()
        keyTap = nil
        lastDisplayID = nil
        diagnostics.brightnessKeyTapInstalled = false
        // Intentionally makes no DDC writes on stop.
    }

    // MARK: Cursor tracking (dim inactive display)

    private func evaluateCursor() {
        rebuildSnapshot()   // keep the key tap's snapshot current as displays move/change
        let point = NSEvent.mouseLocation   // Cocoa Y-up global coords
        guard let active = controller.display(containing: point) else {
            lastDisplayID = nil
            return
        }
        guard active.id != lastDisplayID else { return }
        let previousID = lastDisplayID
        lastDisplayID = active.id

        guard settings.settings.dimInactiveDisplay else { return }
        // Restore the now-active display to its stored brightness…
        if let target = settings.settings.displayBrightness[active.id] {
            controller.apply(fraction: target, to: active)
        }
        // …and dim the one we just left.
        if let previousID, let previous = controller.displays.first(where: { $0.id == previousID }) {
            controller.apply(fraction: 0.2, to: previous)
        }
    }

    // MARK: Brightness-key routing

    /// Rebuilds the thread-safe display snapshot the key tap reads.
    private func rebuildSnapshot() {
        let snap = controller.displays.compactMap {
            d -> (frame: CGRect, supportsDDC: Bool, id: String, name: String, number: CGDirectDisplayID)? in
            guard let screen = NSScreen.screens.first(where: { $0.displayID == d.screenNumber }) else { return nil }
            return (screen.frame, d.supportsDDC, d.id, d.name, d.screenNumber)
        }
        snapshotLock.lock(); displaySnapshot = snap; snapshotLock.unlock()
    }

    /// The DDC display under `point`, from the snapshot. Called on the tap thread.
    private nonisolated func ddcDisplay(at point: CGPoint) -> BrightnessKeyTap.Hit? {
        snapshotLock.lock(); let snap = displaySnapshot; snapshotLock.unlock()
        guard let d = snap.first(where: { $0.supportsDDC && $0.frame.contains(point) }) else { return nil }
        return BrightnessKeyTap.Hit(id: d.id, name: d.name, number: d.number)
    }

    /// Applies a brightness-key press to the external display (on the main actor;
    /// the tap thread dispatched here, so a slow DDC write can't stall input).
    private func applyKey(increase: Bool, hit: BrightnessKeyTap.Hit) {
        guard let display = controller.displays.first(where: { $0.id == hit.id }) else { return }
        let current = settings.settings.displayBrightness[display.id]
            ?? controller.currentFraction(of: display)
            ?? 0.8
        let next = BrightnessMath.stepped(
            current: current,
            stepPercent: settings.settings.brightnessStepPercent,
            increase: increase
        )
        settings.update { $0.displayBrightness[display.id] = next }
        controller.apply(fraction: next, to: display)
        let screen = NSScreen.screens.first { $0.displayID == display.screenNumber }
        hud.show(displayName: display.name, level: next, on: screen)
    }
}
