import AppKit
import QuackKit

/// Menu-bar Y band in AX/Quartz global (top-left origin) for the main display.
enum MenuBarBand {
    static func current() -> ClosedRange<CGFloat> {
        let thickness = NSStatusBar.system.thickness   // ~24pt
        return -5 ... (thickness + 12)                 // generous; main display top
    }
}

/// Synthesizes a real left-click at a screen point — the reliable way to open a
/// third-party status item's menu/popover (AXPress often reports success without
/// opening anything; this is what Ice/Bartender do). Posts events (no event tap,
/// so it can't gate input / freeze). Warps the cursor to the point first so the
/// click lands where the item actually is.
enum SynthClick {
    /// `point` is in global Quartz coordinates (top-left origin), matching AX frames.
    /// Restores the cursor to where it was so the click doesn't leave the pointer
    /// parked in the menu bar.
    static func left(at point: CGPoint) {
        let restore = CGEvent(source: nil)?.location   // current cursor, global top-left
        CGWarpMouseCursorPosition(point)
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        if let restore {
            usleep(60_000)   // let the target app process the click first
            CGWarpMouseCursorPosition(restore)
        }
    }
}

/// Notch span of the main display, or nil if not notched. Uses the auxiliary
/// top areas that flank the camera housing.
enum NotchProbe {
    static func current() -> NotchGeometry.NotchSpan? {
        guard let screen = NSScreen.main else { return nil }
        return span(for: screen)
    }

    static func span(for screen: NSScreen) -> NotchGeometry.NotchSpan? {
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        return NotchGeometry.notchSpan(
            screenMinX: screen.frame.minX, screenWidth: screen.frame.width,
            leftAuxWidth: left, rightAuxWidth: right)
    }
}
