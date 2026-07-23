import Foundation

/// Polls `probe` on `queue` every `interval`, up to `maxAttempts` times, until
/// `isSettled` passes. Starting a new wait cancels whichever wait from this
/// instance is still in flight, so there's no shared counter to leak across
/// retriggers — just one cancellable chain per waiter.
public final class AXSettleWaiter<Value> {
    private var token: DispatchWorkItem?

    public init() {}

    public enum Outcome {
        case settled(Value)
        case exhausted(Value)
    }

    /// `probe` and `completion` both run on `queue` — pass `.main` for
    /// AppKit/NSStatusItem reads, a background queue for cross-process AX
    /// calls (and hop back to `.main` yourself inside `completion`).
    public func start(
        on queue: DispatchQueue,
        maxAttempts: Int = 25,
        interval: TimeInterval = 0.2,
        probe: @escaping () -> Value,
        isSettled: @escaping (Value) -> Bool,
        completion: @escaping (Outcome) -> Void
    ) {
        token?.cancel()
        let myToken = DispatchWorkItem {}
        token = myToken

        func attempt(_ n: Int) {
            guard !myToken.isCancelled else { return }
            let value = probe()
            if isSettled(value) { completion(.settled(value)); return }
            if n >= maxAttempts { completion(.exhausted(value)); return }
            queue.asyncAfter(deadline: .now() + interval) {
                guard !myToken.isCancelled else { return }
                attempt(n + 1)
            }
        }
        queue.async { attempt(1) }
    }

    /// Cancels any in-flight wait without calling `completion`.
    public func cancel() {
        token?.cancel()
        token = nil
    }
}

extension AXSettleWaiter.Outcome: Equatable where Value: Equatable {}
