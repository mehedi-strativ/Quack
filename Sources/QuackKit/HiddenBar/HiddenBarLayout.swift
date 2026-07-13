import CoreGraphics

/// Pure geometry for the hidden bar. Works in a Y-up space where
/// `menuBarBottomY` is the menu bar's lower edge and the panel hangs below it.
public enum HiddenBarLayout {

    /// The secondary-bar rect: centered under the chevron, clamped within screen.
    public static func panelFrame(
        itemCount: Int, itemWidth: CGFloat, spacing: CGFloat, padding: CGFloat,
        height: CGFloat, chevronMidX: CGFloat, menuBarBottomY: CGFloat,
        screenMinX: CGFloat, screenMaxX: CGFloat
    ) -> CGRect {
        let content = CGFloat(max(itemCount, 0)) * itemWidth
            + CGFloat(max(itemCount - 1, 0)) * spacing
        let width = content + padding * 2
        var minX = chevronMidX - width / 2
        minX = min(max(minX, screenMinX), screenMaxX - width)
        minX = max(minX, screenMinX)   // when width > screen, pin left
        return CGRect(x: minX, y: menuBarBottomY - height, width: width, height: height)
    }
}
