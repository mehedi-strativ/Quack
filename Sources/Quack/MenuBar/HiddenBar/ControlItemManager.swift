import AppKit

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

    enum Length { static let expanded: CGFloat = 10_000 }

    init(onChevronHover: @escaping () -> Void,
         onChevronExit: @escaping () -> Void,
         onChevronClick: @escaping () -> Void) {
        self.onClick = onChevronClick
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
        ch.button?.image = Self.chevronImage
        ch.button?.setAccessibilityLabel("Show hidden menu bar items")
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

    private static let chevronImage: NSImage? =
        NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Show hidden menu bar items")

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
