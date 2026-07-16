import Foundation

public enum ControlItemSeeding {
    /// Repairs lost "NSStatusItem Preferred Position" autosave values for the
    /// two hidden-bar control items. Positions are distances from the screen's
    /// RIGHT edge (larger = further left); the divider must sit left of the
    /// chevron.
    ///
    /// An item with no saved position is placed by macOS at the FAR LEFT of the
    /// menu bar — left of the notch. The role logic (leftmost = divider) then
    /// collapses the wrong item (one with nothing to its left) so nothing gets
    /// hidden, and the chevron ends up left of the notch. Seed a missing item
    /// next to its surviving partner, or — when BOTH are missing — at
    /// `defaultChevron` (a position that lands right of the notch), keeping the
    /// divider one step to its left.
    ///
    /// Returns the values to write (nil = leave that key untouched).
    public static func seeds(chevron: Double?,
                             divider: Double?,
                             defaultChevron: Double) -> (chevron: Double?, divider: Double?) {
        switch (chevron, divider) {
        case (_?, _?):            return (nil, nil)
        case (nil, let divider?): return (max(divider - 1, 1), nil)
        case (let chevron?, nil): return (nil, chevron + 1)
        case (nil, nil):          let c = max(defaultChevron, 1); return (c, c + 1)
        }
    }
}
