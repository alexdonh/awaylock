import Observation
import os

/// macOS 14 stand-in for `Observations`: yields `value()` now, then again after any change to what it read.
/// Changes made in the same main-actor turn coalesce into one value, like `Observations`. Never finishes
/// on its own; stops tracking once the consumer is gone.
func observing<T: Sendable>(_ value: @escaping @MainActor @Sendable () -> T) -> AsyncStream<T> {
    AsyncStream { out in
        let alive = OSAllocatedUnfairLock(initialState: true)
        out.onTermination = { _ in alive.withLock { $0 = false } }
        track(value, out, alive)
    }
}

private func track<T: Sendable>(_ value: @escaping @MainActor @Sendable () -> T, _ out: AsyncStream<T>.Continuation,
                                _ alive: OSAllocatedUnfairLock<Bool>) {
    guard alive.withLock({ $0 }) else { return }
    out.yield(withObservationTracking { value() } onChange: {
        Task { @MainActor in track(value, out, alive) }   // onChange runs before the write lands: re-read on the next turn
    })
}
