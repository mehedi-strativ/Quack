import AppKit
import ApplicationServices

struct MenuBarAXItem {
    let id: String
    let pid: pid_t
    let appName: String
    let title: String        // AX title/description — identifies Control Center modules
    let appIcon: NSImage?
    let element: AXUIElement
    let frame: CGRect
}

/// Walks every running app's AXExtrasMenuBar and returns all menu-bar status
/// items with real frames. Identity/app/icon/element come from AX because the
/// window list attributes menu-bar windows to Control Center (see the hidden-bar
/// spike). Call off the main actor: AX is blocking IPC. Needs the Accessibility
/// grant (returns [] silently without it).
enum MenuBarAXScanner {
    /// `menuBarBands` are the per-display menu-bar Y ranges (AX/Quartz global,
    /// top-left origin); an item is kept if its midY falls in ANY of them.
    static func scanAll(menuBarBands: [ClosedRange<CGFloat>]) -> [MenuBarAXItem] {
        let apps = NSWorkspace.shared.runningApplications
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let lock = NSLock()
        var found: [MenuBarAXItem] = []
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let app = apps[i]
            guard app.processIdentifier != ownPID else { return }
            let hits = scanApp(app, menuBarBands: menuBarBands)
            guard !hits.isEmpty else { return }
            lock.lock(); found.append(contentsOf: hits); lock.unlock()
        }
        return found.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// System menu-extra hosts the user can't ⌘-drag and that render as blank
    /// glyphs — excluded so the strip shows only real apps the user hid.
    private static let systemDenylist: Set<String> = [
        "com.apple.systemuiserver",
        "com.apple.TextInputMenuAgent",
        "com.apple.Spotlight",
        "com.apple.Siri",
        "com.apple.wifi.WiFiAgent",
    ]

    private static func scanApp(_ app: NSRunningApplication,
                                menuBarBands: [ClosedRange<CGFloat>]) -> [MenuBarAXItem] {
        if let bid = app.bundleIdentifier, systemDenylist.contains(bid) { return [] }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        var barVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &barVal) == .success,
              let bar = barVal, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        var childrenVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenVal) == .success,
              let children = childrenVal as? [AXUIElement] else { return [] }
        var out: [MenuBarAXItem] = []
        for (index, child) in children.enumerated() {
            guard let frame = frame(of: child), frame.width > 0,
                  menuBarBands.contains(where: { $0.contains(frame.midY) }) else { continue }
            let title = (attr(child, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (attr(child, kAXDescriptionAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? ""
            out.append(MenuBarAXItem(
                id: "\(app.processIdentifier):\(index)",
                pid: app.processIdentifier,
                appName: app.localizedName ?? "?",
                title: title,
                appIcon: app.icon,
                element: child,
                frame: frame))
        }
        return out
    }

    /// Live frame of an AX element — used to click the item at its current
    /// on-screen position after it snaps back via expand().
    static func elementFrame(_ el: AXUIElement) -> CGRect? { frame(of: el) }

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        var posVal: CFTypeRef?, sizeVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeVal) == .success
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
