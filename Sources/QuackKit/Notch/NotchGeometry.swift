import CoreGraphics

/// Pure notch geometry. The notch's horizontal span is the same number in both
/// Cocoa (Y-up) and CoreGraphics (Y-down) coordinate spaces because only the Y
/// axis flips between them — so all of this is coordinate-system-agnostic and
/// lives here, away from `NSScreen`. Mirrors how `ScreenGeometry` keeps the
/// window-move math testable and separate from `WindowMover`'s `NSScreen` reads.
public enum NotchGeometry {

    /// The horizontal span occupied by the notch, in the same x-space as the
    /// inputs. Nil on a screen without a notch (either auxiliary side absent).
    public struct NotchSpan: Equatable, Sendable {
        public let minX: CGFloat
        public let maxX: CGFloat
        public init(minX: CGFloat, maxX: CGFloat) {
            self.minX = minX
            self.maxX = maxX
        }
        public var width: CGFloat { maxX - minX }
    }

    /// Derives the notch span from a screen's width and the widths of the two
    /// usable auxiliary areas flanking the camera housing. On a notched screen
    /// the notch sits between the right edge of the left area and the left edge
    /// of the right area. Returns nil when either side is absent (no notch) or
    /// the resulting span is degenerate.
    public static func notchSpan(
        screenMinX: CGFloat,
        screenWidth: CGFloat,
        leftAuxWidth: CGFloat,
        rightAuxWidth: CGFloat
    ) -> NotchSpan? {
        guard leftAuxWidth > 0, rightAuxWidth > 0 else { return nil }
        let minX = screenMinX + leftAuxWidth
        let maxX = screenMinX + screenWidth - rightAuxWidth
        guard maxX > minX else { return nil }
        return NotchSpan(minX: minX, maxX: maxX)
    }

    /// Whether a status item laid out at `itemMinX` (in the menu-bar band) is
    /// hidden by the notch. Empirically confirmed on hardware: macOS never
    /// draws a status item left of the notch — visible items are always laid
    /// out entirely to its right — so any item whose frame STARTS left of the
    /// notch's right edge exists only in its app's AX tree, not on screen.
    public static func isHiddenByNotch(itemMinX: CGFloat, notch: NotchSpan) -> Bool {
        itemMinX < notch.maxX
    }
}
