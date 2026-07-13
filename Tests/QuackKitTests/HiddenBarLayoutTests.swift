import Testing
import CoreGraphics
@testable import QuackKit

@Suite struct HiddenBarLayoutTests {

    @Test func panelFrameCenteredUnderChevronAndClamped() {
        // 3 items * 24 + 2*8 spacing + 2*6 padding = 100 wide, 26 tall.
        let f = HiddenBarLayout.panelFrame(
            itemCount: 3, itemWidth: 24, spacing: 8, padding: 6, height: 26,
            chevronMidX: 850, menuBarBottomY: 1030, screenMinX: 0, screenMaxX: 1000)
        #expect(abs(f.height - 26) < 0.5)
        #expect(abs(f.width - 100) < 0.5)
        #expect(abs(f.maxX - 900) < 0.5)   // centered under chevron (850 + 50)
        #expect(f.maxX <= 1000)
        #expect(f.minX >= 0)
        #expect(abs(f.minY - (1030 - 26)) < 0.5)   // hangs below the menu bar
    }

    @Test func panelFrameClampsToScreenLeftEdge() {
        let f = HiddenBarLayout.panelFrame(
            itemCount: 10, itemWidth: 24, spacing: 8, padding: 6, height: 26,
            chevronMidX: 60, menuBarBottomY: 1030, screenMinX: 0, screenMaxX: 1000)
        #expect(abs(f.minX - 0) < 0.5)
    }
}
