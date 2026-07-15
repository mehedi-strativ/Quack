// Tests/QuackKitTests/MenuBarLayoutPlanTests.swift
import Testing
@testable import QuackKit

@Suite struct MenuBarLayoutPlanTests {

    // Identical layout → no operations.
    @Test func noChangeProducesNoOps() {
        let ops = MenuBarLayoutPlan.plan(
            currentOrder: ["a", "b", "c"], currentBoundary: 1,
            desiredOrder: ["a", "b", "c"], desiredBoundary: 1)
        #expect(ops.isEmpty)
    }

    // Boundary shifts, order unchanged → a single moveDivider op at the new count.
    @Test func boundaryOnlyMovesDivider() {
        let ops = MenuBarLayoutPlan.plan(
            currentOrder: ["a", "b", "c"], currentBoundary: 1,
            desiredOrder: ["a", "b", "c"], desiredBoundary: 2)
        #expect(ops == [.init(kind: .moveDivider, targetIndex: 2)])
    }

    // One item dragged to a new slot within its section → a single reorderItem op
    // carrying that item's id and its destination index. No divider op.
    @Test func reorderWithinSectionMovesOneItem() {
        let ops = MenuBarLayoutPlan.plan(
            currentOrder: ["a", "b", "c"], currentBoundary: 0,
            desiredOrder: ["a", "c", "b"], desiredBoundary: 0)
        #expect(ops == [.init(kind: .reorderItem(id: "c"), targetIndex: 1)])
    }

    // Dragging a shown item left across the boundary into Hidden → it both moves
    // in the order AND the boundary grows: reorder op first, then divider op.
    @Test func moveShownItemIntoHiddenEmitsReorderThenDivider() {
        // "c" (shown) dragged to the front, and now hidden.
        let ops = MenuBarLayoutPlan.plan(
            currentOrder: ["a", "b", "c"], currentBoundary: 1,   // hidden: [a]
            desiredOrder: ["c", "a", "b"], desiredBoundary: 2)    // hidden: [c, a]
        #expect(ops == [
            .init(kind: .reorderItem(id: "c"), targetIndex: 0),
            .init(kind: .moveDivider, targetIndex: 2),
        ])
    }

    // Everything hidden with no reordering → boundary jumps 0 → n, one divider op.
    @Test func hideAllIsDividerOnly() {
        let ops = MenuBarLayoutPlan.plan(
            currentOrder: ["a", "b"], currentBoundary: 0,
            desiredOrder: ["a", "b"], desiredBoundary: 2)
        #expect(ops == [.init(kind: .moveDivider, targetIndex: 2)])
    }
}
