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

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
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
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        diagnostics.swipeTapInstalled = false
    }

    private func installTap() {
        let mask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,   // observe only; title-bar scrolls are otherwise inert
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<GestureMonitor>.fromOpaque(refcon).takeUnretainedValue()
                        .handleScroll(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Log.swipe.error("Failed to create scroll event tap (Accessibility not effective?)")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        diagnostics.swipeTapInstalled = true
        Log.swipe.log("Scroll gesture tap installed")
    }

    fileprivate func handleScroll(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }   // callback too slow; safe
            return
        }
        if type == .tapDisabledByUserInput {
            return   // Accessibility revoked — re-enabling here loops and freezes input
        }
        guard let ns = NSEvent(cgEvent: event), ns.hasPreciseScrollingDeltas else { return }

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
    /// that will actually do something (up = fill, down = minimize always;
    /// left/right only when snapping is enabled).
    private func updateCursor() {
        guard eligible else { return }
        let threshold = TrackpadSwipe.requiredDisplacement(sensitivity: settings.settings.swipeSensitivity) * 0.4
        guard let direction = ScreenGeometry.direction(forDelta: accumulated, minMagnitude: threshold) else {
            indicator.hide()
            return
        }
        let snapOff = !settings.settings.windowSnapEnabled
        if (direction == .left || direction == .right), snapOff {
            indicator.hide()
        } else {
            indicator.show(direction: direction, at: NSEvent.mouseLocation)
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
