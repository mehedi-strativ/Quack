// Sources/QuackKit/HiddenBar/MenuBarLayoutPlan.swift

/// Pure planner: turns a before→after menu-bar layout into the minimal list of
/// drag operations the executor must perform on the live bar. Coordinate-free —
/// the Quack-side executor converts each op's target index into an on-screen X.
///
/// `order` is the item ids left→right (Quack's divider excluded). `boundary` is
/// the number of Hidden items: indices `0..<boundary` are Hidden, the rest Shown.
public enum MenuBarLayoutPlan {

    public struct DragOp: Equatable {
        public enum Kind: Equatable {
            case reorderItem(id: String)   // move this real item to `targetIndex`
            case moveDivider               // move Quack's divider so `targetIndex` items are left of it
        }
        public let kind: Kind
        public let targetIndex: Int
        public init(kind: Kind, targetIndex: Int) {
            self.kind = kind
            self.targetIndex = targetIndex
        }
    }

    public static func plan(currentOrder: [String], currentBoundary: Int,
                            desiredOrder: [String], desiredBoundary: Int) -> [DragOp] {
        var ops: [DragOp] = []

        if currentOrder != desiredOrder {
            // A single user drag moves exactly one item; every other item keeps
            // its relative order. The moved item is the one whose removal makes
            // the two sequences identical, and whose index actually changed.
            if let moved = desiredOrder.enumerated().first(where: { i, id in
                currentOrder.firstIndex(of: id) != i
                    && currentOrder.filter { $0 != id } == desiredOrder.filter { $0 != id }
            }) {
                ops.append(.init(kind: .reorderItem(id: moved.element), targetIndex: moved.offset))
            }
        }

        if currentBoundary != desiredBoundary {
            ops.append(.init(kind: .moveDivider, targetIndex: desiredBoundary))
        }

        return ops
    }
}
