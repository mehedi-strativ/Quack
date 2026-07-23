import Testing
import Dispatch
import Foundation
@testable import QuackKit

@Suite struct AXSettleWaiterTests {

    @Test func settlesImmediatelyWhenProbeAlreadyPasses() async throws {
        let waiter = AXSettleWaiter<Int>()
        var result: AXSettleWaiter<Int>.Outcome?
        waiter.start(on: .global(), maxAttempts: 3, interval: 0.01,
                     probe: { 5 },
                     isSettled: { $0 == 5 },
                     completion: { result = $0 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(result == .settled(5))
    }

    @Test func exhaustsAfterMaxAttemptsWithLastProbedValue() async throws {
        let waiter = AXSettleWaiter<Int>()
        var calls = 0
        var result: AXSettleWaiter<Int>.Outcome?
        waiter.start(on: .global(), maxAttempts: 3, interval: 0.01,
                     probe: { calls += 1; return calls },
                     isSettled: { _ in false },
                     completion: { result = $0 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(calls == 3)
        #expect(result == .exhausted(3))
    }

    @Test func newWaitCancelsThePriorInFlightWait() async throws {
        let waiter = AXSettleWaiter<Int>()
        var firstResult: AXSettleWaiter<Int>.Outcome?
        waiter.start(on: .global(), maxAttempts: 10, interval: 0.05,
                     probe: { 1 },
                     isSettled: { _ in false },
                     completion: { firstResult = $0 })
        var secondResult: AXSettleWaiter<Int>.Outcome?
        waiter.start(on: .global(), maxAttempts: 1, interval: 0.01,
                     probe: { 2 },
                     isSettled: { $0 == 2 },
                     completion: { secondResult = $0 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(secondResult == .settled(2))
        #expect(firstResult == nil)
    }

    @Test func cancellationDuringSloProbeDoesNotFireCompletion() async throws {
        let waiter = AXSettleWaiter<Int>()
        var firstResult: AXSettleWaiter<Int>.Outcome?
        let probeQueue = DispatchQueue(label: "test.probe")

        // Start a wait with a slow probe that sleeps while executing.
        waiter.start(on: probeQueue, maxAttempts: 10, interval: 0.1,
                     probe: {
                         Thread.sleep(forTimeInterval: 0.05)
                         return 1
                     },
                     isSettled: { _ in false },
                     completion: { firstResult = $0 })

        // Cancel after a short delay, while the first probe is still sleeping.
        try await Task.sleep(for: .milliseconds(25))
        waiter.cancel()

        // Wait long enough for the probe to complete and for any pending
        // completion to fire if it were going to.
        try await Task.sleep(for: .milliseconds(200))

        // The first wait's completion should never have fired because we
        // cancelled it while the probe was executing.
        #expect(firstResult == nil)
    }
}
