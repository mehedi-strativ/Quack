import Testing
import CoreGraphics
@testable import QuackKit

@Suite struct HiddenBarLayoutTests {

    @Test func panelFrameCenteredUnderChevronAndClamped() {
        // 3 square items * 24 + 2*8 spacing + 2*6 padding = 100 wide, 26 tall.
        let f = HiddenBarLayout.panelFrame(
            itemWidths: [24, 24, 24], spacing: 8, padding: 6, height: 26,
            chevronMidX: 850, panelTopY: 1030, screenMinX: 0, screenMaxX: 1000)
        #expect(abs(f.height - 26) < 0.5)
        #expect(abs(f.width - 100) < 0.5)
        #expect(abs(f.maxX - 900) < 0.5)   // centered under chevron (850 + 50)
        #expect(f.maxX <= 1000)
        #expect(f.minX >= 0)
        #expect(abs(f.minY - (1030 - 26)) < 0.5)   // top edge at panelTopY, extends down
    }

    @Test func panelFrameClampsToScreenLeftEdge() {
        let f = HiddenBarLayout.panelFrame(
            itemWidths: Array(repeating: 24, count: 10), spacing: 8, padding: 6, height: 26,
            chevronMidX: 60, panelTopY: 1030, screenMinX: 0, screenMaxX: 1000)
        #expect(abs(f.minX - 0) < 0.5)
    }

    @Test func panelFrameSumsVariablePerItemWidths() {
        // Mixed square + wide items: 20 + 40 + 22, 2*8 spacing, 2*6 padding.
        let f = HiddenBarLayout.panelFrame(
            itemWidths: [20, 40, 22], spacing: 8, padding: 6, height: 26,
            chevronMidX: 500, panelTopY: 1030, screenMinX: 0, screenMaxX: 1000)
        #expect(abs(f.width - (20 + 40 + 22 + 16 + 12)) < 0.5)
    }

    @Test func panelFrameWithNoItemsIsJustPadding() {
        let f = HiddenBarLayout.panelFrame(
            itemWidths: [], spacing: 8, padding: 6, height: 26,
            chevronMidX: 500, panelTopY: 1030, screenMinX: 0, screenMaxX: 1000)
        #expect(abs(f.width - 12) < 0.5)
    }

    // A captured menu-bar glyph is rarely square (battery %, Wi-Fi bars + text,
    // the clock) — forcing it into a square tile via scaledToFit shrinks it to
    // a tiny sliver. itemDisplayWidth preserves the source aspect ratio instead,
    // clamped so a pathologically wide/narrow capture can't wreck the layout.

    @Test func itemDisplayWidthPreservesSquareAspect() {
        let w = HiddenBarLayout.itemDisplayWidth(
            imageSize: CGSize(width: 32, height: 32), targetHeight: 22, minWidth: 16, maxWidth: 36)
        #expect(abs(w - 22) < 0.01)
    }

    @Test func itemDisplayWidthScalesWideGlyphUp() {
        // 71x33 (e.g. a Wi-Fi/battery capture) at height 22 -> width ~47.3, clamped to 36.
        let w = HiddenBarLayout.itemDisplayWidth(
            imageSize: CGSize(width: 71, height: 33), targetHeight: 22, minWidth: 16, maxWidth: 36)
        #expect(abs(w - 36) < 0.01)
    }

    @Test func itemDisplayWidthRendersWideCompositeItemAtNaturalWidth() {
        // A composite item like the Screen-Recording "0m" timer (~2:1). With the
        // production maxWidth of 48 it renders at its natural ~44pt width instead
        // of being clamped — the panel widens to fit rather than squeezing it.
        let w = HiddenBarLayout.itemDisplayWidth(
            imageSize: CGSize(width: 48, height: 24), targetHeight: 22, minWidth: 16, maxWidth: 48)
        #expect(abs(w - 44) < 0.01)
    }

    @Test func itemDisplayWidthClampsNarrowGlyphToMinimum() {
        let w = HiddenBarLayout.itemDisplayWidth(
            imageSize: CGSize(width: 6, height: 33), targetHeight: 22, minWidth: 16, maxWidth: 36)
        #expect(abs(w - 16) < 0.01)
    }

    @Test func itemDisplayWidthFallsBackToTargetHeightForDegenerateSize() {
        let w = HiddenBarLayout.itemDisplayWidth(
            imageSize: .zero, targetHeight: 22, minWidth: 16, maxWidth: 36)
        #expect(abs(w - 22) < 0.01)
    }
}
