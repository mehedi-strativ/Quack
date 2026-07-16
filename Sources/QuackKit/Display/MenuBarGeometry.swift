import CoreGraphics

/// Pure geometry for locating the menu bar in AX/Quartz global coordinates
/// (top-left origin, primary-display top = 0).
public enum MenuBarGeometry {
    /// Y band covering one display's menu bar. The menu bar sits at the top
    /// edge of every display; in AX/Quartz top-left coords that edge is
    /// `primaryHeight - screenMaxYCocoa` (Cocoa is bottom-left origin, so a
    /// display above the primary lands at a NEGATIVE Y). The band is generous
    /// to tolerate item-height variation but narrow enough not to swallow a
    /// neighbouring display's bar.
    ///
    /// - Parameters:
    ///   - screenMaxYCocoa: the display's Cocoa `frame.maxY` (top edge).
    ///   - primaryHeight: height of the primary display (Cocoa origin (0,0)).
    ///   - thickness: `NSStatusBar.system.thickness`.
    public static func topLeftBand(screenMaxYCocoa: CGFloat,
                                   primaryHeight: CGFloat,
                                   thickness: CGFloat) -> ClosedRange<CGFloat> {
        let topY = primaryHeight - screenMaxYCocoa
        return (topY - 5) ... (topY + thickness + 12)
    }
}
