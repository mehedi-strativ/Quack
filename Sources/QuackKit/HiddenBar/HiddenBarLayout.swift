import CoreGraphics

/// Pure geometry for the hidden bar. Works in a Y-up space where
/// `menuBarBottomY` is the menu bar's lower edge and the panel hangs below it.
public enum HiddenBarLayout {

    /// The secondary-bar rect: centered under the chevron, clamped within screen.
    /// `itemWidths` is each item's own display width (see `itemDisplayWidth`) —
    /// a captured menu-bar glyph is rarely square, so a single fixed width per
    /// item would either clip wide glyphs or force narrow ones to stretch.
    public static func panelFrame(
        itemWidths: [CGFloat], spacing: CGFloat, padding: CGFloat,
        height: CGFloat, chevronMidX: CGFloat, menuBarBottomY: CGFloat,
        screenMinX: CGFloat, screenMaxX: CGFloat
    ) -> CGRect {
        let content = itemWidths.reduce(0, +)
            + CGFloat(max(itemWidths.count - 1, 0)) * spacing
        let width = content + padding * 2
        var minX = chevronMidX - width / 2
        minX = min(max(minX, screenMinX), screenMaxX - width)
        minX = max(minX, screenMinX)   // when width > screen, pin left
        return CGRect(x: minX, y: menuBarBottomY - height, width: width, height: height)
    }

    /// The width to render a captured glyph at, given its natural size and a
    /// fixed target height — preserves aspect ratio instead of squeezing a
    /// wide capture (battery %, Wi-Fi bars + text, the clock) into a square
    /// tile, which would shrink it to a tiny sliver. Clamped so a
    /// pathologically wide or narrow capture can't wreck the row's layout.
    public static func itemDisplayWidth(
        imageSize: CGSize, targetHeight: CGFloat, minWidth: CGFloat, maxWidth: CGFloat
    ) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return targetHeight }
        let natural = targetHeight * (imageSize.width / imageSize.height)
        return min(max(natural, minWidth), maxWidth)
    }
}
