import Testing
@testable import QuackKit

@Suite struct BrightnessMathTests {
    @Test func stepsUp() {
        #expect(abs(BrightnessMath.stepped(current: 0.5, stepPercent: 10, increase: true) - 0.6) < 1e-9)
    }
    @Test func stepsDown() {
        #expect(abs(BrightnessMath.stepped(current: 0.5, stepPercent: 10, increase: false) - 0.4) < 1e-9)
    }
    @Test func clampsAtBounds() {
        #expect(BrightnessMath.stepped(current: 0.95, stepPercent: 10, increase: true) == 1.0)
        #expect(BrightnessMath.stepped(current: 0.05, stepPercent: 10, increase: false) == 0.0)
    }
}
