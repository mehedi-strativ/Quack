import Foundation

/// Turns discrete scroll-wheel ticks into a smooth ease-out stream of pixel
/// deltas. Pure math — the caller owns timing and event synthesis.
///
/// Model: added distance goes into a per-axis "pending" pool. Each `step(dt:)`
/// emits `pending * (1 - e^(-dt/τ))` and shrinks the pool, an exponential
/// ease-out. τ is derived from `tailSeconds` so the pool is ~98% drained at
/// the tail (τ = tail/4). Sub-pixel remainders are flushed when the pool drops
/// below half a pixel, so totals are exact and the animation provably ends.
public struct ScrollAnimator: Sendable {
    public struct Frame: Equatable, Sendable {
        public var dx: Double
        public var dy: Double
        public init(dx: Double, dy: Double) { self.dx = dx; self.dy = dy }
    }

    private var pendingX = 0.0
    private var pendingY = 0.0
    private let tau: Double

    public init(tailSeconds: Double = 0.25) {
        self.tau = max(0.01, tailSeconds) / 4
    }

    public var isIdle: Bool { pendingX == 0 && pendingY == 0 }

    /// Queue additional travel (pixels). Consecutive ticks pile up, so fast
    /// flicks glide further.
    public mutating func add(dx: Double, dy: Double) {
        pendingX += dx
        pendingY += dy
    }

    /// Advance by `dt` seconds. Returns the pixel delta to emit this frame,
    /// or nil when idle. Negative or zero `dt` is clamped to 0 (safe; no decay).
    public mutating func step(dt: Double) -> Frame? {
        if isIdle { return nil }
        let dt = max(0, dt)
        let factor = 1 - exp(-dt / tau)
        var outX = pendingX * factor
        var outY = pendingY * factor
        pendingX -= outX
        pendingY -= outY
        // Flush sub-pixel tails so the animation ends and totals stay exact.
        if abs(pendingX) < 0.5 { outX += pendingX; pendingX = 0 }
        if abs(pendingY) < 0.5 { outY += pendingY; pendingY = 0 }
        return Frame(dx: outX, dy: outY)
    }
}
