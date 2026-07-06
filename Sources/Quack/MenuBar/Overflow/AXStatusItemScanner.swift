import AppKit
import ApplicationServices
import QuackKit

/// One menu-bar status item the notch is hiding: identified via the owning
/// app's Accessibility tree, shown with the app's icon, clickable via AXPress.
struct HiddenStatusItem: Identifiable {
    let id: String              // pid:index — stable while the app runs
    let appName: String
    let icon: NSImage?
    let title: String
    let element: AXUIElement
}

/// Finds status items macOS has crushed behind (or left of) the notch.
///
/// The window server UNMAPS crushed items — they have no window, no pixels —
/// so the old CGWindowList + pixel-mirror approach cannot see them. Their
/// owning apps still expose them through Accessibility (`AXExtrasMenuBar`),
/// with real frames laid out under/left of the notch. On a notched Mac no
/// status item is ever drawn left of the notch, so an item in the menu-bar
/// band whose frame starts left of the notch's right edge is hidden.
///
/// Needs the Accessibility permission (returns [] without it). Safe to call
/// off the main actor: AX queries are IPC to other apps and are exactly what
/// we don't want blocking the hover-in animation.
enum AXStatusItemScanner {

    /// - Parameters:
    ///   - notch: the notch span in global Quartz X coordinates.
    ///   - menuBarBandY: global Quartz Y range of the built-in menu bar; items
    ///     parked off-screen by their apps (e.g. at the screen's bottom corner
    ///     when "removed" from the menu bar) fall outside it and are skipped.
    static func scan(
        notch: NotchGeometry.NotchSpan,
        menuBarBandY: ClosedRange<CGFloat>
    ) -> [HiddenStatusItem] {
        // Sweep apps in parallel with a short per-app AX timeout: sequentially,
        // one hung/unresponsive process's default messaging timeout stalls the
        // whole scan (observed 12–13s for a full sweep — results always arrived
        // after the pointer had left).
        let apps = NSWorkspace.shared.runningApplications
        let lock = NSLock()
        var found: [(frame: CGRect, item: HiddenStatusItem)] = []
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let hits = scanApp(apps[i], notch: notch, menuBarBandY: menuBarBandY)
            guard !hits.isEmpty else { return }
            lock.lock(); found.append(contentsOf: hits); lock.unlock()
        }
        return found.sorted { $0.frame.minX < $1.frame.minX }.map(\.item)
    }

    private static func scanApp(
        _ app: NSRunningApplication,
        notch: NotchGeometry.NotchSpan,
        menuBarBandY: ClosedRange<CGFloat>
    ) -> [(frame: CGRect, item: HiddenStatusItem)] {
        // Never list Quack's own items: they'd all render as identical duck
        // app-icons, and AXPress on an own-process element runs the button's
        // action synchronously ON THE CALLING (background) THREAD — main-only
        // AppKit then traps (see crash: openSettings → makeKeyAndOrderFront
        // off-main). Same self-targeting class as the window-shortcuts crash.
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return [] }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        guard let bar = element(attr(ax, "AXExtrasMenuBar")),
              let children = attr(bar, kAXChildrenAttribute) as? [AXUIElement]
        else { return [] }
        var hits: [(CGRect, HiddenStatusItem)] = []
        for (index, child) in children.enumerated() {
            guard let frame = frame(of: child), frame.width > 0,
                  menuBarBandY.contains(frame.midY),
                  NotchGeometry.isHiddenByNotch(itemMinX: frame.minX, notch: notch)
            else { continue }
            let title = (attr(child, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (attr(child, kAXDescriptionAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? app.localizedName ?? "Menu bar item"
            hits.append((frame, HiddenStatusItem(
                id: "\(app.processIdentifier):\(index)",
                appName: app.localizedName ?? "?",
                icon: app.icon,
                title: title,
                element: child
            )))
        }
        return hits
    }

    /// Clicks a hidden item by asking its app to press it — works even though
    /// the item has no window to click. Call off the main actor (blocking IPC).
    static func press(_ item: HiddenStatusItem) {
        AXUIElementPerformAction(item.element, kAXPressAction as CFString)
    }

    // MARK: - AX plumbing

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        guard let posVal = attr(el, kAXPositionAttribute),
              let sizeVal = attr(el, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
