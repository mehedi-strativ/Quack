import AppKit
import CoreGraphics

/// Caches real-glyph captures keyed by AX item id. Captures ONLY on-screen
/// items (off-screen capture returns nil on macOS 26 — see the hidden-bar
/// spike). The glyph for an AX item is the capture of the layer-25 window
/// sitting at the same X.
@MainActor
final class MenuBarItemImageCache {
    private var cache: [String: NSImage] = [:]

    var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    func image(forID id: String) -> NSImage? { cache[id] }

    /// Capture the given items, which the caller guarantees are on-screen now.
    /// Skips negative-X items (uncapturable) and merges results into the cache,
    /// keeping prior captures for items not currently on-screen.
    func captureOnScreen(items: [MenuBarAXItem], windows: [StatusWindow], tolerance: CGFloat = 6) {
        guard hasScreenRecording else { return }
        for item in items where item.frame.minX >= 0 {
            guard let win = windows.min(by: {
                abs($0.frame.minX - item.frame.minX) < abs($1.frame.minX - item.frame.minX)
            }), abs(win.frame.minX - item.frame.minX) <= tolerance else { continue }
            guard let cg = CGWindowListCreateImage(
                .null, .optionIncludingWindow, win.windowID,
                [.boundsIgnoreFraming, .bestResolution]),
                cg.width > 1, cg.height > 1 else { continue }
            cache[item.id] = NSImage(cgImage: cg,
                size: NSSize(width: item.frame.width, height: item.frame.height))
        }
    }
}
