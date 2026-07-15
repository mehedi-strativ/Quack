import CoreGraphics

/// Pure interpretation of a two-finger trackpad swipe, kept testable and free
/// of any AppKit/event-tap dependency.
public enum TrackpadSwipe {

    /// Converts a scroll-wheel delta into a **physical finger** delta in screen
    /// space (Y-down, the AX/CGEvent convention): `dx > 0` = fingers moved
    /// right, `dy < 0` = fingers moved up.
    ///
    /// macOS reports scroll deltas opposite to finger motion, and flips the sign
    /// again when "natural scrolling" is on (`invertedFromDevice`). Both effects
    /// are normalized here so the result always tracks the user's fingers.
    public static func fingerDelta(
        scrollDeltaX: CGFloat,
        scrollDeltaY: CGFloat,
        invertedFromDevice: Bool
    ) -> CGVector {
        // Both axes get the same correction so they stay consistent: scroll
        // deltas are opposite to finger motion, and natural scrolling flips that
        // again. (Empirically: an extra Y-only negation here inverted the
        // vertical swipe — fingers-down moved the window to the upper screen.)
        let sign: CGFloat = invertedFromDevice ? 1 : -1
        return CGVector(dx: sign * scrollDeltaX, dy: sign * scrollDeltaY)
    }

    /// The accumulated finger displacement needed to count as a swipe, scaled by
    /// sensitivity (0…1). Higher sensitivity → smaller threshold (easier).
    /// ~200 points at 0, ~50 points at 1.
    public static func requiredDisplacement(sensitivity: Double) -> CGFloat {
        let s = CGFloat(max(0, min(1, sensitivity)))
        return 200 - 150 * s
    }

    /// Whether a completed title-bar swipe should perform a window action.
    /// - direction:   resolved swipe direction (nil = below threshold → no action).
    /// - commandHeld: ⌘ modifier state at the decision moment.
    /// - snapEnabled: the `windowSnapEnabled` setting.
    ///
    /// Every action requires ⌘. Left/right (snap) additionally require snapping
    /// to be enabled; up/down (fill/minimize) do not. This is the single source
    /// of truth shared by the indicator badge and the end-of-gesture action, so
    /// the badge shows exactly when the action will fire.
    public static func shouldPerformAction(
        direction: SwipeDirection?,
        commandHeld: Bool,
        snapEnabled: Bool
    ) -> Bool {
        guard commandHeld, let direction else { return false }
        switch direction {
        case .up, .down:    return true
        case .left, .right: return snapEnabled
        }
    }
}

/// Pure brightness-stepping math for the F1/F2 key routing.
public enum BrightnessMath {

    /// Steps `current` (0…1) by `stepPercent` in the given direction, clamped.
    public static func stepped(current: Double, stepPercent: Int, increase: Bool) -> Double {
        let step = Double(max(0, stepPercent)) / 100.0
        let next = current + (increase ? step : -step)
        return min(max(next, 0), 1)
    }
}
