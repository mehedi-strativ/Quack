import AppKit

/// Owns Quack's two hidden-bar control items: a visible chevron (trigger +
/// boundary) and an empty divider whose length collapses items off-screen.
/// Layout (L→R): [hidden items] [hiddenDivider] [chevron] [shown items].
@MainActor
final class ControlItemManager {
    private let chevron: NSStatusItem
    private let hiddenDivider: NSStatusItem
    private let onChevronClick: () -> Void
    private var hoverForwarder: HoverForwarder?

    enum Length { static let expanded: CGFloat = 10_000 }

    init(onChevronHover: @escaping () -> Void,
         onChevronExit: @escaping () -> Void,
         onChevronClick: @escaping () -> Void) {
        self.onChevronClick = onChevronClick
        // ORDER MATTERS: a later-created status item is laid out to the LEFT of an
        // earlier one (verified by the Task 0 spike). We need [divider][chevron]
        // (chevron to the RIGHT of the divider) so that collapsing the divider
        // (length 10_000) pushes items to ITS left off-screen while the chevron
        // stays visible. So create the chevron FIRST (rightmost), divider SECOND.
        // Both start at variableLength (items visible) so the service can
        // warm-capture glyphs before its first collapse() (Task 9).
        chevron = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hiddenDivider = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Deliberately NO autosaveName: persisted positions let macOS restore a
        // flipped order (divider ending up RIGHT of the chevron), which makes
        // collapse() shove the chevron off-screen. Without autosave the items
        // take creation-order placement every launch — chevron created first
        // (rightmost), divider second (leftmost) → the required [divider][chevron].
        hiddenDivider.button?.title = ""
        hiddenDivider.button?.setAccessibilityLabel("Quack hidden items divider")

        let forwarder = HoverForwarder(enter: onChevronHover, exit: onChevronExit)
        hoverForwarder = forwarder

        if let b = chevron.button {
            b.image = NSImage(systemSymbolName: "chevron.left",
                              accessibilityDescription: "Show hidden menu bar items")
            b.imagePosition = .imageOnly
            b.target = self
            b.action = #selector(chevronClicked)
            b.setAccessibilityLabel("Show hidden menu bar items")
            // Hover tracking — NO CGEvent tap (CLAUDE.md). Button tracking area only.
            let area = NSTrackingArea(rect: b.bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: forwarder, userInfo: nil)
            b.addTrackingArea(area)
        }
    }

    var chevronFrameOnScreen: CGRect? {
        guard let window = chevron.button?.window else { return nil }
        return window.frame
    }

    var dividerFrameOnScreen: CGRect? {
        guard let window = hiddenDivider.button?.window else { return nil }
        return window.frame
    }

    var dividerMinX: CGFloat? { dividerFrameOnScreen?.minX }

    var chevronMinX: CGFloat? { chevronFrameOnScreen?.minX }

    func collapse() { hiddenDivider.length = Length.expanded }
    func expand()   { hiddenDivider.length = NSStatusItem.variableLength }

    /// Hide the chevron entirely when there's nothing to reveal (e.g. on an
    /// external display where nothing is hidden).
    func setChevronVisible(_ visible: Bool) { chevron.isVisible = visible }

    /// Shows/hides a visible boundary marker on the divider so the user has a
    /// clear target to ⌘-drag icons against during Arrange mode.
    func setDividerVisible(_ visible: Bool) {
        hiddenDivider.button?.image = visible ? Self.dividerImage() : nil
    }

    private static func dividerImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 10, height: 18))
        img.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 3, y: 1, width: 5, height: 16), xRadius: 2, yRadius: 2).fill()
        img.unlockFocus()
        img.isTemplate = false   // keep it white, not tinted by the menu bar
        return img
    }

    func teardown() {
        NSStatusBar.system.removeStatusItem(chevron)
        NSStatusBar.system.removeStatusItem(hiddenDivider)
        hoverForwarder = nil
    }

    @objc private func chevronClicked() { onChevronClick() }
}

/// Retains hover callbacks for a tracking area (the area's owner is unretained,
/// so `ControlItemManager` holds a strong reference to this).
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
