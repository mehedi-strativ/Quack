import CoreGraphics

/// Pure policy for Quack's own menu-bar overflow rail.
///
/// The app layer supplies live status-item frames and applies the returned
/// action. Keeping the decision here makes the notch-specific behavior easy to
/// test without requiring a running menu bar or a real notched display.
public enum MenuBarOverflowPolicy {
    public struct Item: Equatable, Sendable {
        public let id: String
        public let priority: Int
        public let isAvailable: Bool
        public let isManagedHidden: Bool
        public let frameMinX: CGFloat?

        public init(id: String, priority: Int, isAvailable: Bool,
                    isManagedHidden: Bool, frameMinX: CGFloat?) {
            self.id = id
            self.priority = priority
            self.isAvailable = isAvailable
            self.isManagedHidden = isManagedHidden
            self.frameMinX = frameMinX
        }
    }

    public enum Action: Equatable, Sendable {
        case hide(String)
        case reveal(String)
        case none
    }

    /// Returns one conservative visibility change. The caller should run this
    /// again after AppKit has had time to relayout the menu bar.
    public static func nextAction(items: [Item], notch: NotchGeometry.NotchSpan?) -> Action {
        guard let notch else { return .none }

        let available = items.filter(\.isAvailable)
        let visible = available.filter { !$0.isManagedHidden }
        let crushed = visible.contains {
            guard let minX = $0.frameMinX else { return false }
            return NotchGeometry.isHiddenByNotch(itemMinX: minX, notch: notch)
        }

        if crushed {
            // Preserve the highest-priority item if possible. Hiding one item
            // at a time lets AppKit settle each layout change before we make
            // the next decision.
            guard visible.count > 1,
                  let candidate = visible.max(by: { $0.priority < $1.priority }) else {
                return .none
            }
            let lowest = visible.min { $0.priority < $1.priority }
            guard let lowest, lowest.id != candidate.id else { return .none }
            return .hide(lowest.id)
        }

        // Reveal the most useful hidden item first. The driver applies
        // hysteresis because an immediate reveal can briefly recreate crush.
        guard let candidate = available
            .filter(\.isManagedHidden)
            .max(by: { $0.priority < $1.priority }) else {
            return .none
        }
        return .reveal(candidate.id)
    }
}
