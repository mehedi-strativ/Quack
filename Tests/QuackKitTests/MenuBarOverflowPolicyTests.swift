import Testing
import CoreGraphics
@testable import QuackKit

@Suite struct MenuBarOverflowPolicyTests {
    private let notch = NotchGeometry.NotchSpan(minX: 663, maxX: 848)

    @Test func hidesLowestPriorityItemWhenAnyVisibleItemIsCrushed() {
        let action = MenuBarOverflowPolicy.nextAction(items: [
            .init(id: "duck", priority: 100, isAvailable: true, isManagedHidden: false, frameMinX: 900),
            .init(id: "countdown", priority: 80, isAvailable: true, isManagedHidden: false, frameMinX: 830),
            .init(id: "timer", priority: 20, isAvailable: true, isManagedHidden: false, frameMinX: 860),
        ], notch: notch)

        #expect(action == .hide("timer"))
    }

    @Test func revealsHighestPriorityHiddenItemWhenLayoutIsClear() {
        let action = MenuBarOverflowPolicy.nextAction(items: [
            .init(id: "duck", priority: 100, isAvailable: true, isManagedHidden: false, frameMinX: 900),
            .init(id: "countdown", priority: 80, isAvailable: true, isManagedHidden: true, frameMinX: nil),
            .init(id: "timer", priority: 20, isAvailable: true, isManagedHidden: true, frameMinX: nil),
        ], notch: notch)

        #expect(action == .reveal("countdown"))
    }

    @Test func doesNothingWithoutNotch() {
        let action = MenuBarOverflowPolicy.nextAction(items: [
            .init(id: "timer", priority: 20, isAvailable: true, isManagedHidden: false, frameMinX: 10),
        ], notch: nil)

        #expect(action == .none)
    }

    @Test func doesNotHideTheOnlyAvailableItem() {
        let action = MenuBarOverflowPolicy.nextAction(items: [
            .init(id: "duck", priority: 100, isAvailable: true, isManagedHidden: false, frameMinX: 830),
        ], notch: notch)

        #expect(action == .none)
    }
}
