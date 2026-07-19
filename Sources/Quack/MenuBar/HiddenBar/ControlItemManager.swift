import AppKit
import QuackKit

/// Owns Quack's two hidden-bar control items. Roles are assigned DYNAMICALLY by
/// current position rather than creation order: the RIGHTMOST item is the visible
/// chevron (trigger, must be right of the notch to be seen), the LEFTMOST is the
/// collapsing divider (expands to push hidden items off-screen). This is robust
/// to macOS/autosave placing the items in either order — the chevron glyph always
/// lands on whichever item is visible, and collapse never eats the chevron.
/// Layout (L→R): [hidden items] [divider] [chevron] [shown items].
@MainActor
final class ControlItemManager {
    private let itemA: NSStatusItem
    private let itemB: NSStatusItem
    private let onClick: () -> Void
    private var hoverA: HoverForwarder?
    private var hoverB: HoverForwarder?
    private var arranging = false
    private var chevronHidden = false
    /// True while the real bar is pinned open (icons revealed in place). Drives
    /// the chevron glyph: right (▶, "hide again") when expanded, left otherwise.
    private var chevronExpanded = false

    enum Length { static let expanded: CGFloat = 10_000 }

    init(onChevronHover: @escaping () -> Void,
         onChevronExit: @escaping () -> Void,
         onChevronClick: @escaping () -> Void) {
        self.onClick = onChevronClick
        Self.seedLostAutosavePositions()
        itemA = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        itemB = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Autosave persists position so the user's placement (chevron right of the
        // notch, items left of the divider) survives relaunches.
        itemA.autosaveName = "quack.hiddenbar.chevron.v2"
        itemB.autosaveName = "quack.hiddenbar.divider.v2"

        hoverA = wire(itemA, enter: onChevronHover, exit: onChevronExit)
        hoverB = wire(itemB, enter: onChevronHover, exit: onChevronExit)
        refreshRoles()
    }

    /// A control item whose autosaved position was lost (wiped by a ⌘-drag
    /// experiment, a hard kill, etc.) is recreated at the far LEFT of the bar —
    /// left of the notch — where the leftmost-is-divider role logic collapses
    /// it uselessly and nothing gets hidden. Re-seed lost positions next to the
    /// surviving partner (or, if BOTH are gone, at a default slot right of the
    /// notch) BEFORE creating the items.
    private static func seedLostAutosavePositions() {
        let defaults = UserDefaults.standard
        let chevronKey = "NSStatusItem Preferred Position quack.hiddenbar.chevron.v2"
        let dividerKey = "NSStatusItem Preferred Position quack.hiddenbar.divider.v2"
        let seeds = ControlItemSeeding.seeds(
            chevron: defaults.object(forKey: chevronKey) as? Double,
            divider: defaults.object(forKey: dividerKey) as? Double,
            defaultChevron: defaultChevronPosition())
        if let c = seeds.chevron { defaults.set(c, forKey: chevronKey) }
        if let d = seeds.divider { defaults.set(d, forKey: dividerKey) }
    }

    /// A chevron "preferred position" (distance from the screen's right edge)
    /// that lands ~200pt right of the notch on the main display, so a
    /// from-scratch seed puts the chevron in the safe right-of-notch zone.
    /// Falls back to a proven constant on a non-notched main display.
    private static func defaultChevronPosition() -> Double {
        guard let screen = NSScreen.main, let notch = NotchProbe.span(for: screen) else { return 462 }
        return Double(screen.frame.maxX - (notch.maxX + 200))
    }

    private func wire(_ item: NSStatusItem, enter: @escaping () -> Void, exit: @escaping () -> Void) -> HoverForwarder {
        let fwd = HoverForwarder(enter: enter, exit: exit)
        if let b = item.button {
            b.imagePosition = .imageOnly
            b.target = self
            b.action = #selector(clicked)
            b.addTrackingArea(NSTrackingArea(
                rect: b.bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: fwd, userInfo: nil))
        }
        return fwd
    }

    // MARK: Roles

    private func minX(_ item: NSStatusItem) -> CGFloat {
        item.button?.window?.frame.minX ?? .greatestFiniteMagnitude
    }

    /// Leftmost = divider (collapser); rightmost = chevron (trigger).
    private var divider: NSStatusItem { minX(itemA) <= minX(itemB) ? itemA : itemB }
    private var chevron: NSStatusItem { minX(itemA) <= minX(itemB) ? itemB : itemA }

    /// Reassign the chevron glyph to the current rightmost item and the divider
    /// marker to the leftmost. Call when positions are settled (both on-screen).
    func refreshRoles() {
        let ch = chevron, dv = divider
        ch.button?.image = chevronExpanded ? Self.chevronRightImage : Self.chevronLeftImage
        ch.button?.setAccessibilityLabel(chevronExpanded
            ? "Hide menu bar items" : "Show hidden menu bar items")
        ch.isVisible = !chevronHidden
        dv.button?.image = arranging ? Self.dividerImage : nil
        dv.button?.setAccessibilityLabel("Quack hidden items divider")
        dv.isVisible = true
    }

    // MARK: Geometry accessors (used by the service)

    var chevronFrameOnScreen: CGRect? { chevron.button?.window?.frame }
    var dividerFrameOnScreen: CGRect? { divider.button?.window?.frame }
    var chevronMinX: CGFloat? { chevronFrameOnScreen?.minX }
    var dividerMinX: CGFloat? { dividerFrameOnScreen?.minX }

    // MARK: Actions

    func collapse() { divider.length = Length.expanded }
    func expand()   { divider.length = NSStatusItem.variableLength }

    /// Hide the chevron entirely when there's nothing to reveal (external show-all).
    func setChevronVisible(_ visible: Bool) {
        chevronHidden = !visible
        chevron.isVisible = visible
    }
    var chevronIsVisible: Bool { chevron.isVisible }

    /// Flip the chevron glyph to reflect pinned-open (▶) vs collapsed (◀) state.
    func setChevronExpanded(_ expanded: Bool) {
        chevronExpanded = expanded
        let ch = chevron
        ch.button?.image = expanded ? Self.chevronRightImage : Self.chevronLeftImage
        ch.button?.setAccessibilityLabel(expanded
            ? "Hide menu bar items" : "Show hidden menu bar items")
    }

    /// Show/hide the white boundary marker on the divider during Arrange mode.
    func setDividerVisible(_ visible: Bool) {
        arranging = visible
        divider.button?.image = visible ? Self.dividerImage : nil
    }

    func teardown() {
        NSStatusBar.system.removeStatusItem(itemA)
        NSStatusBar.system.removeStatusItem(itemB)
        hoverA = nil; hoverB = nil
    }

    @objc private func clicked() { onClick() }

    // MARK: Images

    private static let chevronLeftImage: NSImage? =
        NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Show hidden menu bar items")

    private static let chevronRightImage: NSImage? =
        NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Hide menu bar items")

    private static let dividerImage: NSImage = {
        let img = NSImage(size: NSSize(width: 10, height: 18))
        img.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 3, y: 1, width: 5, height: 16), xRadius: 2, yRadius: 2).fill()
        img.unlockFocus()
        img.isTemplate = false
        return img
    }()
}

/// Retains hover callbacks for a tracking area (the area's owner is unretained).
private final class HoverForwarder: NSResponder {
    private let enter: () -> Void
    private let exit: () -> Void
    init(enter: @escaping () -> Void, exit: @escaping () -> Void) {
        self.enter = enter; self.exit = exit
        super.init()
    }
    required init?(coder: NSCoder) { nil }
    override func mouseEntered(with event: NSEvent) { enter() }
    override func mouseExited(with event: NSEvent) { exit() }
}
