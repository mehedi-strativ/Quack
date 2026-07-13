import Testing
@testable import QuackKit

@Suite struct ChevronPlacementTests {

    @Test func chevronRightOfNotchIsSafe() {
        let notch = NotchGeometry.NotchSpan(minX: 663, maxX: 848)
        #expect(ChevronPlacement.isSafe(chevronMinX: 900, notch: notch) == true)
    }

    @Test func chevronOverlappingNotchIsUnsafe() {
        let notch = NotchGeometry.NotchSpan(minX: 663, maxX: 848)
        #expect(ChevronPlacement.isSafe(chevronMinX: 800, notch: notch) == false)
    }

    @Test func noNotchIsAlwaysSafe() {
        #expect(ChevronPlacement.isSafe(chevronMinX: 100, notch: nil) == true)
    }
}
