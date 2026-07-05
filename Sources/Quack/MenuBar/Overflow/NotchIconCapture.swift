import Foundation
import QuackKit

/// Scans for status items crushed behind the notch and captures a live pixel
/// snapshot of each. Shared by the reveal strip and the unified notch panel.
/// Safe to call off the main actor: `CGWindowListCopyWindowInfo` /
/// `CGWindowListCreateImage` are thread-safe and touch no main-actor state —
/// callers run this on a background queue to keep hover-in animation smooth.
/// `notch` / `screenXRange` must be read from `NotchScreenReader.currentLayout()`
/// on the main actor before dispatch.
enum NotchIconCapture {

    static func scanAndMirror(
        notch: NotchGeometry.NotchSpan,
        screenXRange: ClosedRange<CGFloat>
    ) -> [NotchItem] {
        let crushed = StatusItemScanner.scan(notch: notch, screenXRange: screenXRange)
        return crushed.compactMap { item in
            guard let image = StatusItemMirror.snapshot(of: item) else { return nil }
            return NotchItem(id: item.windowID, image: image, source: item)
        }
    }
}
