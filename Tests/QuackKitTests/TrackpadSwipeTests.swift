import Testing
import CoreGraphics
@testable import QuackKit

@Suite struct TrackpadSwipeTests {

    // With natural scrolling OFF (invertedFromDevice == false), fingers moving
    // right produce a negative scrollDeltaX; the helper must report dx > 0.
    @Test func fingersRightNaturalOff() {
        let v = TrackpadSwipe.fingerDelta(scrollDeltaX: -30, scrollDeltaY: 0, invertedFromDevice: false)
        #expect(v.dx > 0)
    }

    // With natural scrolling ON, fingers right produce positive scrollDeltaX.
    @Test func fingersRightNaturalOn() {
        let v = TrackpadSwipe.fingerDelta(scrollDeltaX: 30, scrollDeltaY: 0, invertedFromDevice: true)
        #expect(v.dx > 0)
    }

    // dx and dy must receive identical sign treatment (the vertical-only
    // inversion bug was an extra negation on dy). Same scroll input on either
    // axis must yield the same magnitude/sign mapping.
    @Test func axesAreConsistent() {
        let off = TrackpadSwipe.fingerDelta(scrollDeltaX: 20, scrollDeltaY: 20, invertedFromDevice: false)
        #expect(off.dx == off.dy)
        let on = TrackpadSwipe.fingerDelta(scrollDeltaX: 20, scrollDeltaY: 20, invertedFromDevice: true)
        #expect(on.dx == on.dy)
        // Inversion flips both axes.
        #expect(off.dy == -on.dy)
    }

    @Test func swipeDirectionRightFeedsScreenGeometry() {
        let v = TrackpadSwipe.fingerDelta(scrollDeltaX: -120, scrollDeltaY: 5, invertedFromDevice: false)
        #expect(ScreenGeometry.direction(forDelta: v, minMagnitude: 50) == .right)
    }

    @Test func requiredDisplacementScalesWithSensitivity() {
        #expect(TrackpadSwipe.requiredDisplacement(sensitivity: 0) == 200)
        #expect(TrackpadSwipe.requiredDisplacement(sensitivity: 1) == 50)
        #expect(TrackpadSwipe.requiredDisplacement(sensitivity: 0.5) == 125)
    }

    // ⌘ gate: no action without the Command modifier, in any direction.
    @Test func noActionWithoutCommand() {
        #expect(TrackpadSwipe.shouldPerformAction(direction: .up,    commandHeld: false, snapEnabled: true)  == false)
        #expect(TrackpadSwipe.shouldPerformAction(direction: .down,  commandHeld: false, snapEnabled: true)  == false)
        #expect(TrackpadSwipe.shouldPerformAction(direction: .left,  commandHeld: false, snapEnabled: true)  == false)
        #expect(TrackpadSwipe.shouldPerformAction(direction: .right, commandHeld: false, snapEnabled: true)  == false)
    }

    // No resolved direction (below threshold) => no action, even with ⌘.
    @Test func noActionWithoutDirection() {
        #expect(TrackpadSwipe.shouldPerformAction(direction: nil, commandHeld: true, snapEnabled: true) == false)
    }

    // Up/down (fill/minimize) fire with ⌘ regardless of the snap setting.
    @Test func upDownFireWithCommand() {
        #expect(TrackpadSwipe.shouldPerformAction(direction: .up,   commandHeld: true, snapEnabled: false) == true)
        #expect(TrackpadSwipe.shouldPerformAction(direction: .down, commandHeld: true, snapEnabled: false) == true)
    }

    // Left/right (snap) require ⌘ AND snap enabled.
    @Test func leftRightRequireSnapEnabled() {
        #expect(TrackpadSwipe.shouldPerformAction(direction: .left,  commandHeld: true, snapEnabled: true)  == true)
        #expect(TrackpadSwipe.shouldPerformAction(direction: .right, commandHeld: true, snapEnabled: true)  == true)
        #expect(TrackpadSwipe.shouldPerformAction(direction: .left,  commandHeld: true, snapEnabled: false) == false)
        #expect(TrackpadSwipe.shouldPerformAction(direction: .right, commandHeld: true, snapEnabled: false) == false)
    }
}

@Suite struct BrightnessMathTests {
    @Test func stepsUp() {
        #expect(abs(BrightnessMath.stepped(current: 0.5, stepPercent: 10, increase: true) - 0.6) < 1e-9)
    }
    @Test func stepsDown() {
        #expect(abs(BrightnessMath.stepped(current: 0.5, stepPercent: 10, increase: false) - 0.4) < 1e-9)
    }
    @Test func clampsAtBounds() {
        #expect(BrightnessMath.stepped(current: 0.95, stepPercent: 10, increase: true) == 1.0)
        #expect(BrightnessMath.stepped(current: 0.05, stepPercent: 10, increase: false) == 0.0)
    }
}
