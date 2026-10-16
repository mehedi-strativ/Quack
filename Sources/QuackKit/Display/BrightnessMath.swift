/// Pure brightness-stepping math for the F1/F2 key routing.
public enum BrightnessMath {

    /// Steps `current` (0…1) by `stepPercent` in the given direction, clamped.
    public static func stepped(current: Double, stepPercent: Int, increase: Bool) -> Double {
        let step = Double(max(0, stepPercent)) / 100.0
        let next = current + (increase ? step : -step)
        return min(max(next, 0), 1)
    }
}
