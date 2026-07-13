import CoreGraphics

public enum ChevronPlacement {
    /// Safe when there is no notch, or the chevron begins at/right of the notch's
    /// right edge. Otherwise hidden items would land behind the notch (unmapped,
    /// uncapturable).
    public static func isSafe(chevronMinX: CGFloat, notch: NotchGeometry.NotchSpan?) -> Bool {
        guard let notch else { return true }
        return chevronMinX >= notch.maxX
    }
}
