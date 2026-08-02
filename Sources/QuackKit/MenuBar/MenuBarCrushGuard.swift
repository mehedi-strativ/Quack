// Sources/QuackKit/MenuBar/MenuBarCrushGuard.swift
import CoreGraphics

/// Pure decision logic for hiding/revealing Quack's OWN menu-bar items when
/// the notch crushes one of them. Unlike the removed hidden-bar feature, this
/// never touches third-party items — every `Item` here is one Quack owns
/// directly, so no AX scan or CGWindowList capture is needed anywhere in this
/// feature; callers read `NSStatusItem.button.window.frame` directly (real
/// AppKit state for a window this process owns) and pass it in here.
public enum MenuBarCrushGuard {

    /// One of Quack's own status items, as of the current tick.
    public struct Item: Equatable, Sendable {
        public let id: String
        /// Lower number = more important = hidden last, revealed first.
        public let priority: Int
        public let isVisible: Bool
        public let frameMinX: CGFloat

        public init(id: String, priority: Int, isVisible: Bool, frameMinX: CGFloat) {
            self.id = id
            self.priority = priority
            self.isVisible = isVisible
            self.frameMinX = frameMinX
        }
    }

    public enum Action: Equatable, Sendable {
        case hide(id: String)
        case reveal(id: String)
    }

    /// `isClear` is true when no visible item is currently crushed — callers
    /// accumulate this across ticks to gate reveal with hysteresis. It stays
    /// true even when there's nothing to reveal (nothing hidden, or notch is
    /// absent) — "clear" describes the absence of a crush, not the presence
    /// of a pending reveal.
    public struct Decision: Equatable, Sendable {
        public let action: Action?
        public let isClear: Bool
    }

    /// One tick's decision.
    ///
    /// - `notch`: nil on a non-notched screen — always inert there.
    /// - `clearStreak`: how many consecutive PRIOR ticks were clear (i.e. the
    ///   value the caller stored after the previous call). This tick's own
    ///   clearness is added on top before comparing to the hysteresis
    ///   threshold, so a `clearStreak` of 1 reveals on this call.
    public static func decide(
        items: [Item],
        notch: NotchGeometry.NotchSpan?,
        clearStreak: Int
    ) -> Decision {
        guard let notch else { return Decision(action: nil, isClear: true) }

        let visible = items.filter(\.isVisible)
        let topPriority = visible.map(\.priority).min()

        let crushedOthers = visible.contains {
            $0.priority != topPriority && NotchGeometry.isHiddenByNotch(itemMinX: $0.frameMinX, notch: notch)
        }

        if crushedOthers, let lowestPriorityVisible = visible.max(by: { $0.priority < $1.priority }) {
            return Decision(action: .hide(id: lowestPriorityVisible.id), isClear: false)
        }

        let hidden = items.filter { !$0.isVisible }
        guard let revealCandidate = hidden.min(by: { $0.priority < $1.priority }) else {
            return Decision(action: nil, isClear: true)
        }

        let hysteresisTicks = 2
        if clearStreak + 1 >= hysteresisTicks {
            return Decision(action: .reveal(id: revealCandidate.id), isClear: true)
        }
        return Decision(action: nil, isClear: true)
    }
}
