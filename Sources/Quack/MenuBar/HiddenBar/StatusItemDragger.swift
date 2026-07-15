import AppKit
import CoreGraphics

/// Synthesizes a ⌘-drag of a menu-bar status item from `from` to x=`toX`,
/// keeping the menu-bar Y. Holding ⌘ for the whole gesture is what makes macOS
/// treat it as a status-item reorder (same gesture a user performs by hand).
/// Posts events only — no CGEvent tap — so it cannot gate input / freeze the Mac
/// (see CLAUDE.md). Call OFF the main actor: it sleeps between drag steps.
enum StatusItemDragger {
    /// `from` is in global Quartz coordinates (top-left origin), matching AX frames.
    static func drag(from: CGPoint, toX: CGFloat, steps: Int = 20) {
        let restore = CGEvent(source: nil)?.location
        let src = CGEventSource(stateID: .combinedSessionState)

        func post(_ type: CGEventType, _ p: CGPoint) {
            let e = CGEvent(mouseEventSource: src, mouseType: type,
                            mouseCursorPosition: p, mouseButton: .left)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }

        CGWarpMouseCursorPosition(from)
        post(.leftMouseDown, from)
        usleep(20_000)
        for i in 1...max(1, steps) {
            let t = CGFloat(i) / CGFloat(max(1, steps))
            let x = from.x + (toX - from.x) * t
            post(.leftMouseDragged, CGPoint(x: x, y: from.y))
            usleep(8_000)
        }
        post(.leftMouseUp, CGPoint(x: toX, y: from.y))
        if let restore {
            usleep(60_000)
            CGWarpMouseCursorPosition(restore)
        }
    }
}
