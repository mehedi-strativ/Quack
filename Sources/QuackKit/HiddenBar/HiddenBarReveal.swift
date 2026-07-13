public enum RevealState: Equatable, Sendable { case hidden, revealed, pinned }

public enum RevealEvent: Equatable, Sendable {
    case hoverChevron, hoverPanel, exitAll, clickChevron, graceElapsed, clickOutside
}

/// Pure reveal state machine. The owner arms a grace timer when
/// `startsGraceTimer` returns true and cancels it on any hover event.
public enum HiddenBarReveal {
    public static func next(_ state: RevealState, on event: RevealEvent) -> RevealState {
        switch (state, event) {
        case (.hidden, .hoverChevron):        return .revealed
        case (.revealed, .hoverChevron),
             (.revealed, .hoverPanel):        return .revealed
        case (.revealed, .exitAll):           return .revealed   // grace armed, not yet hidden
        case (.revealed, .graceElapsed):      return .hidden
        case (.revealed, .clickChevron):      return .pinned
        case (.pinned, .clickChevron),
             (.pinned, .clickOutside):        return .hidden
        case (.pinned, _):                    return .pinned
        default:                              return state
        }
    }

    /// Grace timer is armed only when the pointer leaves while revealed.
    public static func startsGraceTimer(from old: RevealState, to new: RevealState) -> Bool {
        old == .revealed && new == .revealed
    }
}
