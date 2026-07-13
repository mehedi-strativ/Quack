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
        // Start expanded (items visible) so the service can warm-capture glyphs
        // while items are on-screen before its first collapse() (Task 9).
        hiddenDivider = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        chevron = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hiddenDivider.autosaveName = "quack.hiddenDivider"
        chevron.autosaveName = "quack.chevron"
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

    var chevronMinX: CGFloat? { chevronFrameOnScreen?.minX }

    func collapse() { hiddenDivider.length = Length.expanded }
    func expand()   { hiddenDivider.length = NSStatusItem.variableLength }

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
