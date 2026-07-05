import Testing
import CoreGraphics
@testable import QuackKit

@Suite struct NotchGeometryTests {

    // A 1512-wide built-in screen (14" MBP logical width) with 180pt of notch
    // flanked by two auxiliary areas.
    private let screenMinX: CGFloat = 0
    private let screenWidth: CGFloat = 1512

    @Test func notchSpanSitsBetweenTheAuxiliaryAreas() {
        let span = NotchGeometry.notchSpan(
            screenMinX: screenMinX, screenWidth: screenWidth,
            leftAuxWidth: 666, rightAuxWidth: 666
        )
        #expect(span?.minX == 666)
        #expect(span?.maxX == 846)          // 1512 - 666
        #expect(span?.width == 180)
    }

    @Test func notchSpanRespectsScreenOrigin() {
        // A built-in screen positioned to the right of an external display.
        let span = NotchGeometry.notchSpan(
            screenMinX: 1920, screenWidth: 1512,
            leftAuxWidth: 666, rightAuxWidth: 666
        )
        #expect(span?.minX == 2586)         // 1920 + 666
        #expect(span?.maxX == 2766)         // 1920 + 1512 - 666
    }

    @Test func noNotchWhenAuxiliaryWidthsAreZero() {
        #expect(NotchGeometry.notchSpan(
            screenMinX: 0, screenWidth: 1920,
            leftAuxWidth: 0, rightAuxWidth: 0
        ) == nil)
    }

    @Test func noNotchWhenOnlyOneAuxiliarySideIsPresent() {
        #expect(NotchGeometry.notchSpan(
            screenMinX: 0, screenWidth: 1512,
            leftAuxWidth: 666, rightAuxWidth: 0
        ) == nil)
    }

    // Empirical hardware layout (14" MBP, notch 663–848): every VISIBLE status
    // item starts right of the notch's right edge; items macOS hid reported AX
    // frames starting under or left of it.

    @Test func itemStartingRightOfTheNotchIsVisible() {
        let span = NotchGeometry.NotchSpan(minX: 663, maxX: 848)
        #expect(!NotchGeometry.isHiddenByNotch(itemMinX: 868, notch: span))   // RescueTime
    }

    @Test func itemUnderTheNotchIsHidden() {
        let span = NotchGeometry.NotchSpan(minX: 663, maxX: 848)
        #expect(NotchGeometry.isHiddenByNotch(itemMinX: 758, notch: span))    // Typeless
    }

    @Test func itemEntirelyLeftOfTheNotchIsHidden() {
        let span = NotchGeometry.NotchSpan(minX: 663, maxX: 848)
        #expect(NotchGeometry.isHiddenByNotch(itemMinX: 582, notch: span))    // Quack temp
    }

    @Test func itemStraddlingTheNotchRightEdgeIsHidden() {
        let span = NotchGeometry.NotchSpan(minX: 663, maxX: 848)
        #expect(NotchGeometry.isHiddenByNotch(itemMinX: 830, notch: span))    // Malwarebytes
    }

    @Test func itemExactlyAtTheNotchRightEdgeIsVisible() {
        let span = NotchGeometry.NotchSpan(minX: 663, maxX: 848)
        #expect(!NotchGeometry.isHiddenByNotch(itemMinX: 848, notch: span))
    }
}
