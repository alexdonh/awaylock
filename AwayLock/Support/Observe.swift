import Observation

/// macOS 14 stand-in for `Observations`: yields `value()` now, then again after any change to what it read.
/// Changes made in the same main-actor turn coalesce into one value, like `Observations`. Never finishes.
func observing<T: Sendable>(_ value: @escaping @MainActor @Sendable () -> T) -> AsyncStream<T> {
    AsyncStream { track(value, $0) }
}

private func track<T: Sendable>(_ value: @escaping @MainActor @Sendable () -> T, _ out: AsyncStream<T>.Continuation) {
    out.yield(withObservationTracking { value() } onChange: {
        Task { @MainActor in track(value, out) }   // onChange runs before the write lands: re-read on the next turn
    })
}
