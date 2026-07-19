import Testing
@testable import QuackKit

@Suite struct HiddenBarRevealTests {

    @Test func hoverRevealsThenGraceHides() {
        #expect(HiddenBarReveal.next(.hidden, on: .hoverChevron) == .revealed)
        // Leaving arms grace; grace elapsing hides.
        #expect(HiddenBarReveal.next(.revealed, on: .exitAll) == .revealed)
        #expect(HiddenBarReveal.startsGraceTimer(from: .revealed, to: .revealed) == true)
        #expect(HiddenBarReveal.next(.revealed, on: .graceElapsed) == .hidden)
    }

    @Test func hoverPanelKeepsOpenAndCancelsGrace() {
        #expect(HiddenBarReveal.next(.revealed, on: .hoverPanel) == .revealed)
        #expect(HiddenBarReveal.next(.revealed, on: .hoverChevron) == .revealed)
    }

    @Test func clickPinsAndClickOutsideUnpins() {
        #expect(HiddenBarReveal.next(.revealed, on: .clickChevron) == .pinned)
        #expect(HiddenBarReveal.next(.hidden, on: .clickChevron) == .pinned)  // no prior hover
        #expect(HiddenBarReveal.next(.pinned, on: .exitAll) == .pinned)       // pinned ignores hover-out
        #expect(HiddenBarReveal.next(.pinned, on: .graceElapsed) == .pinned)
        #expect(HiddenBarReveal.next(.pinned, on: .clickChevron) == .hidden)  // toggle off
        #expect(HiddenBarReveal.next(.pinned, on: .clickOutside) == .hidden)
    }
}
