import CoreGraphics

struct StatusWindow {
    let windowID: UInt32
    let frame: CGRect   // global Quartz
}

/// On-screen layer-25 (menu-bar) windows, any owner. Used only to match a
/// windowID to an AX item by X so the glyph can be captured while on-screen.
/// (Menu-bar windows are owned by Control Center, so owner pid is not useful.)
enum StatusWindowList {
    static func onScreen() -> [StatusWindow] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [StatusWindow] = []
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 25,
                  let wid = w[kCGWindowNumber as String] as? UInt32,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let ww = b["Width"], let hh = b["Height"], ww > 0
            else { continue }
            out.append(StatusWindow(windowID: wid, frame: CGRect(x: x, y: y, width: ww, height: hh)))
        }
        return out
    }
}
