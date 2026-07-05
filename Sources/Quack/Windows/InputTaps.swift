import Foundation

/// Per-feature switches for the CGEvent-based input taps, so they can be
/// enabled/verified one at a time.
///
/// Each tap runs on a dedicated thread and is fully stopped + recreated on every
/// `com.apple.accessibility.api` change (MonitorControl's pattern) so toggling
/// Accessibility can't freeze input. See `CursorBrightnessService.reinstallKeyTap`.
enum InputTaps {
    static let brightness = true    // F1/F2 → external-display brightness
    static let hotkey = true        // ⌘⌥ + arrow window shortcuts
    static let swipe = true         // two-finger title-bar swipe
    static let mouseButtons = true  // buttons 4/5 remap
    static let smoothScroll = true  // wheel-tick smoothing
}
