import AppKit
import QuackKit

/// Menu-bar Y bands in AX/Quartz global (top-left origin), one per display —
/// the menu bar (and Quack's status items) can live on ANY display, each at a
/// different global Y. A single main-display band silently dropped every item
/// when the bar was on a secondary display (empty hover panel).
enum MenuBarBand {
    static func all() -> [ClosedRange<CGFloat>] {
        let thickness = NSStatusBar.system.thickness   // ~24pt
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.screens.first)?.frame.height ?? 0
        return NSScreen.screens.map {
            MenuBarGeometry.topLeftBand(
                screenMaxYCocoa: $0.frame.maxY, primaryHeight: primaryHeight, thickness: thickness)
        }
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
