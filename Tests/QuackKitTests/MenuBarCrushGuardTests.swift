// Tests/QuackKitTests/MenuBarCrushGuardTests.swift
import Testing
import CoreGraphics
@testable import QuackKit

@Suite struct MenuBarCrushGuardTests {

    // Same fixture notch as NotchGeometryTests: 14" MBP, notch 663–848.
    private let notch = NotchGeometry.NotchSpan(minX: 663, maxX: 848)

    private func item(_ id: String, priority: Int, visible: Bool, minX: CGFloat) -> MenuBarCrushGuard.Item {
        .init(id: id, priority: priority, isVisible: visible, frameMinX: minX)
    }

    @Test func noNotchIsAlwaysInert() {
        let items = [item("duck", priority: 0, visible: true, minX: 500)]
        let decision = MenuBarCrushGuard.decide(items: items, notch: nil, clearStreak: 0)
        #expect(decision.action == nil)
        #expect(decision.isClear)
    }

    @Test func nothingCrushedIsNoAction() {
        let items = [
            item("duck", priority: 0, visible: true, minX: 900),
            item("countdown", priority: 1, visible: true, minX: 950),
            item("temperature", priority: 2, visible: true, minX: 1050),
        ]
        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: 0)
        #expect(decision.action == nil)
        #expect(decision.isClear)
    }

    @Test func crushedNonTopItemHidesTheLowestPriorityVisibleItem() {
        // countdown (priority 1) is crushed; duck (priority 0) and temperature
        // (priority 2) are fine. Lowest-priority VISIBLE item is temperature —
        // that's what gets hidden to free space, not countdown itself.
        let items = [
            item("duck", priority: 0, visible: true, minX: 900),
            item("countdown", priority: 1, visible: true, minX: 700),   // crushed
            item("temperature", priority: 2, visible: true, minX: 1000),
        ]
        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: 0)
        #expect(decision.action == .hide(id: "temperature"))
        #expect(!decision.isClear)
    }

    @Test func onlyDuckVisibleAndCrushedHasNoAction() {
        // No lower-priority item exists to sacrifice — duck never yields.
        let items = [item("duck", priority: 0, visible: true, minX: 700)]
        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: 0)
        #expect(decision.action == nil)
    }

    @Test func crushedTopmostVisibleItemAloneIsIgnored() {
        // duck (topmost, priority 0) is crushed but nothing else is —
        // the "other than the single highest-priority visible one" exclusion
        // means this alone never triggers a hide. But isClear should still
        // reflect that duck IS crushed (even though it won't be hidden).
        let items = [
            item("duck", priority: 0, visible: true, minX: 700),      // crushed but excluded
            item("countdown", priority: 1, visible: true, minX: 900),
        ]
        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: 0)
        #expect(decision.action == nil)
        #expect(!decision.isClear)
    }

    @Test func duckCrushedAloneBlocksRevealDespiteHighClearStreak() {
        // duck (topmost, priority 0) is crushed alone, and something is
        // already hidden. Even though clearStreak is high (would normally
        // trigger reveal), the crush on duck blocks it.
        let items = [
            item("duck", priority: 0, visible: true, minX: 700),        // crushed, but alone (topmost)
            item("temperature", priority: 2, visible: false, minX: 1000),
        ]
        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: 5)
        #expect(decision.action == nil)
        #expect(!decision.isClear)
    }

    @Test func clearWithHiddenCandidateDoesNotRevealBeforeTwoTicks() {
        let items = [
            item("duck", priority: 0, visible: true, minX: 900),
            item("temperature", priority: 2, visible: false, minX: 1000),
        ]
        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: 0)
        #expect(decision.action == nil)
        #expect(decision.isClear)
    }

    @Test func clearForTwoConsecutiveTicksReveals() {
        let items = [
            item("duck", priority: 0, visible: true, minX: 900),
            item("temperature", priority: 2, visible: false, minX: 1000),
        ]
        // clearStreak: 1 (this is the tick that makes streak reach 2)
        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: 1)
        #expect(decision.action == .reveal(id: "temperature"))
        #expect(decision.isClear)
    }

    @Test func revealPrefersHigherPriorityAmongMultipleHiddenItems() {
        // Both temperature (priority 2) and timer (priority 3) are hidden.
        // temperature is higher priority (lower number) — reveal it first.
        let items = [
            item("duck", priority: 0, visible: true, minX: 900),
            item("temperature", priority: 2, visible: false, minX: 1000),
            item("timer", priority: 3, visible: false, minX: 1100),
        ]
        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: 1)
        #expect(decision.action == .reveal(id: "temperature"))
    }
}
