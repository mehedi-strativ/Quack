import Testing
@testable import QuackKit

@Suite struct ControlItemSeedingTests {

    // Positions are "NSStatusItem Preferred Position" values: distance from the
    // screen's RIGHT edge, so larger = further left. The divider must sit left
    // of the chevron.

    @Test func lostChevronIsSeededJustRightOfDivider() {
        let s = ControlItemSeeding.seeds(chevron: nil, divider: 463)
        #expect(s.chevron == 462)
        #expect(s.divider == nil)
    }

    @Test func lostDividerIsSeededJustLeftOfChevron() {
        let s = ControlItemSeeding.seeds(chevron: 440, divider: nil)
        #expect(s.chevron == nil)
        #expect(s.divider == 441)
    }

    @Test func bothPresentSeedsNothing() {
        let s = ControlItemSeeding.seeds(chevron: 440, divider: 463)
        #expect(s.chevron == nil)
        #expect(s.divider == nil)
    }

    @Test func bothMissingSeedsNothing() {
        // Fresh install: let macOS place both; they land adjacent anyway.
        let s = ControlItemSeeding.seeds(chevron: nil, divider: nil)
        #expect(s.chevron == nil)
        #expect(s.divider == nil)
    }

    @Test func seededChevronNeverGoesNonPositive() {
        let s = ControlItemSeeding.seeds(chevron: nil, divider: 0.5)
        #expect(s.chevron == 1)
    }
}
