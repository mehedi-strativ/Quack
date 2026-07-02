import AppKit
import Combine
import QuackKit

/// One revealed icon: a live snapshot of a crushed status item plus the source
/// frame needed to forward a click back to it.
struct NotchItem: Identifiable {
    let id: UInt32          // the source window ID (stable per status item)
    let image: NSImage
    let source: StatusItemFrame
}

/// Observable state for the notch reveal panel. The service sets `items` after a
/// scan and reacts to `onHoverChange` / `onTap`; the SwiftUI view renders it.
@MainActor
final class NotchViewModel: ObservableObject {
    @Published var isOpen = false
    @Published var items: [NotchItem] = []

    /// Called when the cursor enters (true) or leaves (false) the panel content.
    var onHoverChange: ((Bool) -> Void)?
    /// Called when a revealed icon is tapped.
    var onTap: ((StatusItemFrame) -> Void)?
}
