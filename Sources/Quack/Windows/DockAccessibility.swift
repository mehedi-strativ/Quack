import AppKit
import ApplicationServices
import CoreGraphics

/// Finds the application whose Dock icon is under the cursor, using the
/// Accessibility API to read the Dock's icon list. Used by `DockPinchMonitor` to
/// decide which app a pinch-to-quit gesture targets.
enum DockAccessibility {

    /// The app under the cursor in the Dock, plus its icon center in Cocoa
    /// (Y-up) coordinates for placing the close badge.
    struct Hit {
        let app: NSRunningApplication
        let iconCenter: CGPoint   // Cocoa global, Y-up
    }

    /// Resolves the Dock app item directly under the current mouse location.
    /// Returns nil if the cursor isn't over an application Dock icon, or the
    /// icon's app can't be matched to a running application.
    static func appUnderCursor() -> Hit? {
        let mouse = NSEvent.mouseLocation            // Cocoa, Y-up
        let ph = primaryHeight()
        let axPoint = CGPoint(x: mouse.x, y: ph - mouse.y)   // AX, Y-down

        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(axPoint.x), Float(axPoint.y), &element) == .success,
              var current = element else { return nil }

        // Walk up until we hit an application Dock item.
        var dockItem: AXUIElement?
        var depth = 0
        while depth < 6 {
            if subrole(of: current) == "AXApplicationDockItem" { dockItem = current; break }
            guard let parent = copyElement(current, kAXParentAttribute as String) else { break }
            current = parent
            depth += 1
        }
        guard let item = dockItem, isDockOwned(item) else { return nil }
        guard let app = runningApp(for: item) else { return nil }
        return Hit(app: app, iconCenter: iconCenter(of: item, primaryHeight: ph))
    }

    // MARK: - App resolution

    /// Matches a Dock item to a running application, preferring its bundle URL
    /// (robust against duplicate/localized names) and falling back to title.
    private static func runningApp(for item: AXUIElement) -> NSRunningApplication? {
        if let url = urlValue(item, "AXURL") {
            let target = url.standardizedFileURL
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleURL?.standardizedFileURL == target
            }) { return app }
            if let bid = Bundle(url: url)?.bundleIdentifier,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                return app
            }
        }
        if let title = stringValue(item, kAXTitleAttribute as String) {
            return NSWorkspace.shared.runningApplications.first {
                $0.activationPolicy == .regular && $0.localizedName == title
            }
        }
        return nil
    }

    private static func isDockOwned(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock"
    }

    // MARK: - Geometry

    private static func iconCenter(of item: AXUIElement, primaryHeight ph: CGFloat) -> CGPoint {
        guard let pos = pointValue(item, kAXPositionAttribute as String),
              let size = sizeValue(item, kAXSizeAttribute as String) else {
            // Fall back to the cursor if the frame is unreadable.
            return NSEvent.mouseLocation
        }
        let axCenter = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
        return CGPoint(x: axCenter.x, y: ph - axCenter.y)   // AX (Y-down) → Cocoa (Y-up)
    }

    /// Height of the primary screen (the one with origin at zero), used to flip
    /// between Cocoa (Y-up) and AX (Y-down) coordinate spaces.
    private static func primaryHeight() -> CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height)
            ?? NSScreen.main?.frame.height
            ?? 0
    }

    // MARK: - AX attribute readers

    private static func subrole(of element: AXUIElement) -> String? {
        stringValue(element, kAXSubroleAttribute as String)
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func urlValue(_ element: AXUIElement, _ attribute: String) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFURLGetTypeID() else { return nil }
        return (value as! NSURL) as URL
    }

    private static func pointValue(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let v = axValue(element, attribute) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    private static func sizeValue(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let v = axValue(element, attribute) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
