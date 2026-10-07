import AppKit
import ApplicationServices
import CoreGraphics
import Combine
import QuackKit

/// Detects a **two-finger trackpad swipe** that starts with the cursor over a
/// window's title bar and flings the window to the adjacent monitor in the
/// swipe direction. Works in both directions (primary→secondary and back).
///
/// A passive `CGEventTap` watches `scrollWheel` events (two-finger trackpad
/// swipes arrive as precise scroll gestures). During a gesture it accumulates
/// the physical finger displacement; when the gesture ends, if the cursor began
/// over a title bar and the displacement toward an adjacent display exceeds a
/// sensitivity-scaled threshold, the window is moved there.
///
/// Requires Accessibility permission (to read window frames and reposition).
@MainActor
final class GestureMonitor: ManagedService {
    private let settings: SettingsStore
    private let permissions: PermissionsManager
    private let diagnostics: DiagnosticsStatus

    private var tap: EventTapThread?
    private var started = false
    private var axObserver: NSObjectProtocol?

    // Per-gesture state.
    private var tracking = false
    private var eligible = false
    private var trackedWindow: AXUIElement?
    private var accumulated = CGVector(dx: 0, dy: 0)

    init(settings: SettingsStore, permissions: PermissionsManager, diagnostics: DiagnosticsStatus) {
        self.settings = settings
        self.permissions = permissions
        self.diagnostics = diagnostics
    }

    func start() {
        started = true
        if permissions.status(for: .accessibility) == .granted {
            reinstall()
        } else {
            permissions.requestAccessibilityAccess()
        }

        // Stop + recreate the tap on any Accessibility change (MonitorControl's
        // proven pattern — see CursorBrightnessService). Prevents the
        // toggle-Accessibility freeze.
        axObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Task { @MainActor in self?.reinstall() }
            }
        }
    }

    func stop() {
        started = false
        if let axObserver { DistributedNotificationCenter.default().removeObserver(axObserver) }
        axObserver = nil
        teardownTap()
        resetGesture()
    }

    /// Fully tears down any existing tap and creates a fresh one. Ungated:
    /// `tapCreate` succeeds only when Accessibility is actually trusted.
    private func reinstall() {
        guard InputTaps.swipe, started else { return }
        teardownTap()
        installTap()
    }

    private func teardownTap() {
        tap?.stop()
        tap = nil
        diagnostics.swipeTapInstalled = false
    }

    private func installTap() {
        // Dedicated thread (CLAUDE.md rule 1). The tap thread only filters for
        // trackpad gesture phases — ordinary wheel scrolling never reaches the
        // main thread; gesture state and AX work stay on main.
        let t = EventTapThread(
            mask: 1 << CGEventType.scrollWheel.rawValue,
            options: .listenOnly,   // observe only; title-bar scrolls are otherwise inert
            label: "com.quack.swipeTap"
        ) { [weak self] type, event in
            if type == .scrollWheel, Self.isGesturePhase(event), let copy = event.copy() {
                DispatchQueue.main.async { self?.handleScroll(copy) }
            }
            return Unmanaged.passUnretained(event)
        }
        tap = t
        t.start()
        diagnostics.swipeTapInstalled = AXIsProcessTrusted()
    }

    /// Precise (trackpad) scroll carrying a began/changed/ended/cancelled phase.
    /// Momentum and mouse-wheel events have no gesture phase.
    private nonisolated static func isGesturePhase(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 else { return false }
        // CGScrollPhase raw values (not NSEvent.Phase's): began 1, changed 2,
        // ended 4, cancelled 8; mayBegin (128) and none (0) are ignored.
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        return phase & 0b1111 != 0
    }

    private func handleScroll(_ event: CGEvent) {
        guard started, let ns = NSEvent(cgEvent: event), ns.hasPreciseScrollingDeltas else { return }

        switch ns.phase {
        case .began:
            beginGesture(at: event.location)
        case .changed:
            guard tracking else { return }
            let delta = TrackpadSwipe.fingerDelta(
                scrollDeltaX: ns.scrollingDeltaX,
                scrollDeltaY: ns.scrollingDeltaY,
                invertedFromDevice: ns.isDirectionInvertedFromDevice
            )
            accumulated.dx += delta.dx
            accumulated.dy += delta.dy
            updateCursor()
        case .ended, .cancelled:
            endGesture()
        default:
            break   // ignore momentum and .mayBegin
        }
    }

    /// Height of the top-of-window region that counts as the "top bar". Covers
    /// both plain title bars (~28pt) and unified toolbars (~52pt).
    private let titleBarHeight: CGFloat = 56

    private var sourceScreen: ScreenInfo?
    private let indicator = SwipeIndicator()

    private func beginGesture(at point: CGPoint) {
        resetGesture()
        tracking = true
        guard let window = AXHelpers.window(at: point),
              let frame = AXHelpers.frame(of: window) else {
            Log.swipe.debug("gesture began but no window under cursor at \(Int(point.x)),\(Int(point.y))")
            return
        }
        if ScreenGeometry.titleBarBand(of: frame, height: titleBarHeight).contains(point) {
            trackedWindow = window
            eligible = true
            let screens = WindowMover.screenInfos()
            sourceScreen = ScreenGeometry.screen(containing: CGPoint(x: frame.midX, y: frame.midY), in: screens)
            Log.swipe.debug("gesture began on title bar of window frame \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
        } else {
            Log.swipe.debug("gesture began but cursor not in top \(Int(self.titleBarHeight))pt of window")
        }
    }

    /// Shows a floating directional-arrow badge while swiping, for any direction
    /// that will actually act — ⌘ must be held; up = fill, down = minimize;
    /// left/right only when snapping is enabled.
    private func updateCursor() {
        guard eligible else { return }
        let threshold = TrackpadSwipe.requiredDisplacement(sensitivity: settings.settings.swipeSensitivity) * 0.4
        guard let direction = ScreenGeometry.direction(forDelta: accumulated, minMagnitude: threshold) else {
            indicator.hide()
            return
        }
        // Show the arrow only when the swipe will actually act (⌘ held, and snap
        // enabled for left/right). Keeps the badge honest — it appears exactly
        // when releasing would perform the action.
        if TrackpadSwipe.shouldPerformAction(direction: direction,
                                             commandHeld: NSEvent.modifierFlags.contains(.command),
                                             snapEnabled: settings.settings.windowSnapEnabled) {
            indicator.show(direction: direction, at: NSEvent.mouseLocation)
        } else {
            indicator.hide()
        }
    }

    private func endGesture() {
        defer { resetGesture() }
        guard eligible, let window = trackedWindow,
              let frame = AXHelpers.frame(of: window) else { return }

        let threshold = TrackpadSwipe.requiredDisplacement(sensitivity: settings.settings.swipeSensitivity)
        let magnitude = (accumulated.dx * accumulated.dx + accumulated.dy * accumulated.dy).squareRoot()
        guard magnitude >= threshold else {
            Log.swipe.debug("gesture below threshold: mag=\(Int(magnitude)) need=\(Int(threshold))")
            return
        }
        // Require ⌘ held so a plain space-switch / horizontal scroll over a title
        // bar never snaps the window. Same predicate the indicator uses.
        let direction = ScreenGeometry.direction(forDelta: accumulated, minMagnitude: threshold)
        guard TrackpadSwipe.shouldPerformAction(direction: direction,
                                                commandHeld: NSEvent.modifierFlags.contains(.command),
                                                snapEnabled: settings.settings.windowSnapEnabled) else {
            Log.swipe.debug("swipe ignored: no ⌘ / no clear direction / snap off")
            return
        }
        let moved = WindowMover.move(window: window, currentFrame: frame, swipe: accumulated,
                                     snapEnabled: settings.settings.windowSnapEnabled)
        Log.swipe.log("swipe dx=\(Int(self.accumulated.dx)) dy=\(Int(self.accumulated.dy)) -> \(moved ? "moved/snapped" : "no-op")")
    }

    private func resetGesture() {
        tracking = false
        eligible = false
        trackedWindow = nil
        sourceScreen = nil
        accumulated = CGVector(dx: 0, dy: 0)
        indicator.hide()
    }
}
