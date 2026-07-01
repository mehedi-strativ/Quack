import AppKit
import CoreGraphics
import QuackKit

/// Enumerates on-screen menu-bar status-item windows via the window server and
/// returns the ones the notch has crushed. Reads live `CGWindowList` data (the
/// impure half); the crushed/visible decision is delegated to the pure
/// `NotchGeometry.crushedItems`, which is unit-tested.
enum StatusItemScanner {

    /// The window layer menu-bar status items report. The system menu bar itself
    /// is layer 24 (`NSMainMenuWindowLevel`); third-party status items sit at 25
    /// (`NSStatusWindowLevel`). Isolated as a constant because it is a stable but
    /// undocumented convention that may need tuning on a future macOS.
    private static let statusWindowLayer = 25

    /// The crushed status items on the built-in screen, left-to-right. `notch`
    /// and `screenXRange` come from `NotchScreenReader.currentLayout()`.
    @MainActor
    static func scan(notch: NotchGeometry.NotchSpan, screenXRange: ClosedRange<CGFloat>) -> [StatusItemFrame] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var items: [StatusItemFrame] = []
        for info in raw {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == statusWindowLayer,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let windowID = info[kCGWindowNumber as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = cgRect(fromWindowBounds: boundsDict)
            else { continue }

            // Menu-bar band only: short windows sitting at the top of the built-in
            // screen, within its horizontal extent.
            guard bounds.height <= 40, bounds.minY <= 40,
                  bounds.midX >= screenXRange.lowerBound, bounds.midX <= screenXRange.upperBound
            else { continue }

            items.append(StatusItemFrame(ownerPID: pid, windowID: UInt32(windowID), frame: bounds))
        }

        return NotchGeometry.crushedItems(items, notch: notch)
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func cgRect(fromWindowBounds dict: [String: Any]) -> CGRect? {
        var rect = CGRect.zero
        return CGRectMakeWithDictionaryRepresentation(dict as CFDictionary, &rect) ? rect : nil
    }
}
