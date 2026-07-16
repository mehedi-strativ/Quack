import Testing
@testable import QuackKit

@Suite struct ControlItemSeedingTests {

    // Positions are "NSStatusItem Preferred Position" values: distance from the
    // screen's RIGHT edge, so larger = further left. The divider must sit left
    // of the chevron.

    @Test func lostChevronIsSeededJustRightOfDivider() {
        let s = ControlItemSeeding.seeds(chevron: nil, divider: 463, defaultChevron: 400)
        #expect(s.chevron == 462)
        #expect(s.divider == nil)
    }

    @Test func lostDividerIsSeededJustLeftOfChevron() {
        let s = ControlItemSeeding.seeds(chevron: 440, divider: nil, defaultChevron: 400)
        #expect(s.chevron == nil)
        #expect(s.divider == 441)
    }

    @Test func bothPresentSeedsNothing() {
        let s = ControlItemSeeding.seeds(chevron: 440, divider: 463, defaultChevron: 400)
        #expect(s.chevron == nil)
        #expect(s.divider == nil)
    }

    @Test func bothMissingSeedsDefaultsWithDividerLeftOfChevron() {
        // Both lost (e.g. autosave wiped): seed the chevron at the default
        // right-of-notch slot and the divider one step further left.
        let s = ControlItemSeeding.seeds(chevron: nil, divider: nil, defaultChevron: 400)
        #expect(s.chevron == 400)
        #expect(s.divider == 401)
    }

    @Test func seededChevronNeverGoesNonPositive() {
        let s = ControlItemSeeding.seeds(chevron: nil, divider: 0.5, defaultChevron: 400)
        #expect(s.chevron == 1)
    }

    @Test func bothMissingClampsNonPositiveDefault() {
        let s = ControlItemSeeding.seeds(chevron: nil, divider: nil, defaultChevron: 0)
        #expect(s.chevron == 1)
        #expect(s.divider == 2)
    }
}
