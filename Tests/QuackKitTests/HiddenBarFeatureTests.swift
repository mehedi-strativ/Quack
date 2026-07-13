import Testing
@testable import QuackKit

@Suite struct HiddenBarFeatureTests {

    @Test func hiddenBarDisabledByDefault() {
        #expect(QuackSettings().hiddenBarEnabled == false)
        #expect(Feature.hiddenBar.isEnabled(in: QuackSettings()) == false)
    }

    @Test func hiddenBarEnabledWhenFlagSet() {
        var s = QuackSettings()
        s.hiddenBarEnabled = true
        #expect(Feature.hiddenBar.isEnabled(in: s) == true)
    }
}
