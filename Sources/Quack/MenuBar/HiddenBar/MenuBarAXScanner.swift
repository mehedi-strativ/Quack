import AppKit
import ApplicationServices

struct MenuBarAXItem {
    let id: String
    let pid: pid_t
    let appName: String
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
    static func scanAll(menuBarBandY: ClosedRange<CGFloat>) -> [MenuBarAXItem] {
        let apps = NSWorkspace.shared.runningApplications
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let lock = NSLock()
        var found: [MenuBarAXItem] = []
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let app = apps[i]
            guard app.processIdentifier != ownPID else { return }
            let hits = scanApp(app, menuBarBandY: menuBarBandY)
            guard !hits.isEmpty else { return }
            lock.lock(); found.append(contentsOf: hits); lock.unlock()
        }
        return found.sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func scanApp(_ app: NSRunningApplication,
                                menuBarBandY: ClosedRange<CGFloat>) -> [MenuBarAXItem] {
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
                  menuBarBandY.contains(frame.midY) else { continue }
            out.append(MenuBarAXItem(
                id: "\(app.processIdentifier):\(index)",
                pid: app.processIdentifier,
                appName: app.localizedName ?? "?",
                appIcon: app.icon,
                element: child,
                frame: frame))
        }
        return out
    }

    /// Press a status item by its AX element (hidden-bar click-forward: we
    /// already hold the element from the scan). Call off the main actor.
    static func press(element: AXUIElement) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
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
