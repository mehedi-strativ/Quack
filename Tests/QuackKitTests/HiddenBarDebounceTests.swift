import Foundation
import Testing
@testable import QuackKit

@Suite struct HiddenBarDebounceTests {

    @Test func proceedsOnFirstTrigger() {
        #expect(HiddenBarDebounce.shouldProceed(lastTriggerAt: nil, now: Date()) == true)
    }

    @Test func blocksWithinWindow() {
        let now = Date()
        let last = now.addingTimeInterval(-1)   // 1s ago, inside the 3s window
        #expect(HiddenBarDebounce.shouldProceed(lastTriggerAt: last, now: now) == false)
    }

    @Test func proceedsExactlyAtWindowBoundary() {
        let now = Date()
        let last = now.addingTimeInterval(-HiddenBarDebounce.window)
        #expect(HiddenBarDebounce.shouldProceed(lastTriggerAt: last, now: now) == true)
    }

    @Test func proceedsAfterWindowElapses() {
        let now = Date()
        let last = now.addingTimeInterval(-3.5)   // 3.5s ago, outside the 3s window
        #expect(HiddenBarDebounce.shouldProceed(lastTriggerAt: last, now: now) == true)
    }
}
