import Foundation

/// Rate-limits `warmAndCollapse`'s full expand()/collapse() cycle. Repeated
/// cycling (e.g. `didBecomeActiveNotification` firing back-to-back, or the
/// 5s "refresh while showing" timer landing while a panel is already open)
/// was confirmed (2026-07-24, live device logging) to cumulatively shift the
/// divider/chevron `NSStatusItem`s' real on-screen X position further left on
/// each cycle — corrupting which items get classified as hidden. Debouncing
/// fresh triggers avoids back-to-back cycles instead of trusting callers not
/// to over-fire.
public enum HiddenBarDebounce {
    public static let window: TimeInterval = 3

    public static func shouldProceed(lastTriggerAt: Date?, now: Date) -> Bool {
        guard let lastTriggerAt else { return true }
        return now.timeIntervalSince(lastTriggerAt) >= window
    }
}
