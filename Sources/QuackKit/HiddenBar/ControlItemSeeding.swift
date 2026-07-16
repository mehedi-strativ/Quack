import Foundation

public enum ControlItemSeeding {
    /// Repairs a lost "NSStatusItem Preferred Position" autosave value for one
    /// of the two hidden-bar control items. Positions are distances from the
    /// screen's RIGHT edge (larger = further left); the divider must sit left
    /// of the chevron.
    ///
    /// An item with no saved position is placed by macOS at the FAR LEFT of the
    /// menu bar. The role logic (leftmost = divider) then collapses the wrong
    /// item — one that has nothing to its left — so nothing gets hidden. Seed
    /// the missing item's position right next to its partner instead.
    ///
    /// Returns the values to write (nil = leave that key untouched). When both
    /// are missing (fresh install) nothing is seeded: macOS places the two new
    /// items adjacent anyway.
    public static func seeds(chevron: Double?, divider: Double?) -> (chevron: Double?, divider: Double?) {
        switch (chevron, divider) {
        case (nil, let divider?): return (max(divider - 1, 1), nil)
        case (let chevron?, nil): return (nil, chevron + 1)
        default:                  return (nil, nil)
        }
    }
}
