import AppKit
import QuackKit

/// Menu-bar Y band in AX/Quartz global (top-left origin) for the main display.
enum MenuBarBand {
    static func current() -> ClosedRange<CGFloat> {
        let thickness = NSStatusBar.system.thickness   // ~24pt
        return -5 ... (thickness + 12)                 // generous; main display top
    }
}

/// Notch span of the main display, or nil if not notched. Uses the auxiliary
/// top areas that flank the camera housing.
enum NotchProbe {
    static func current() -> NotchGeometry.NotchSpan? {
        guard let screen = NSScreen.main else { return nil }
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        return NotchGeometry.notchSpan(
            screenMinX: screen.frame.minX, screenWidth: screen.frame.width,
            leftAuxWidth: left, rightAuxWidth: right)
    }
}
