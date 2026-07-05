import Testing
@testable import QuackKit

@Suite struct ScrollAnimatorTests {
    /// Steps at 60 Hz until idle; returns total emitted per axis.
    private func drain(_ a: inout ScrollAnimator, maxSeconds: Double = 2) -> (x: Double, y: Double) {
        var x = 0.0, y = 0.0, t = 0.0
        let dt = 1.0 / 60.0
        while !a.isIdle && t < maxSeconds {
            if let f = a.step(dt: dt) { x += f.dx; y += f.dy }
            t += dt
        }
        return (x, y)
    }

    @Test func startsIdle() {
        var a = ScrollAnimator()
        #expect(a.isIdle)
        #expect(a.step(dt: 1.0 / 60.0) == nil)
    }

    @Test func emitsExactlyWhatWasAdded() {
        var a = ScrollAnimator()
        a.add(dx: 0, dy: -120)
        let total = drain(&a)
        #expect(abs(total.y - (-120)) < 0.001)
        #expect(total.x == 0)
        #expect(a.isIdle)
    }

    @Test func consecutiveTicksAccumulate() {
        var a = ScrollAnimator()
        a.add(dx: 0, dy: 40)
        let first = a.step(dt: 1.0 / 60.0)!.dy   // partially drained…
        a.add(dx: 0, dy: 40)                      // …then another tick lands
        let rest = drain(&a).y
        // Everything added eventually comes out.
        #expect(abs(first + rest - 80) < 0.001)
    }

    @Test func axesAreIndependent() {
        var a = ScrollAnimator()
        a.add(dx: 30, dy: -50)
        let total = drain(&a)
        #expect(abs(total.x - 30) < 0.001)
        #expect(abs(total.y - (-50)) < 0.001)
    }

    @Test func reachesIdleWithinTail() {
        var a = ScrollAnimator(tailSeconds: 0.25)
        a.add(dx: 0, dy: 400)
        var t = 0.0
        while !a.isIdle { _ = a.step(dt: 1.0 / 60.0); t += 1.0 / 60.0 }
        #expect(t < 0.5)   // decays well before 2× the tail
    }

    @Test func earlyFramesAreLargest() {
        var a = ScrollAnimator()
        a.add(dx: 0, dy: -300)
        let f1 = a.step(dt: 1.0 / 60.0)!
        let f2 = a.step(dt: 1.0 / 60.0)!
        #expect(abs(f1.dy) > abs(f2.dy))   // ease-out: big first, then decaying
    }

    @Test func zeroAddIsNoOp() {
        var a = ScrollAnimator()
        a.add(dx: 0, dy: 0)
        #expect(a.isIdle)
    }
}
