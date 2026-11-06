/// Median of the last 5 raw readings (kills single spikes), then EMA α = 0.3
/// (follows a real walk within ~3 readings).
nonisolated struct RSSIFilter: Sendable {
    static let windowSize = 5
    static let alpha = 0.3

    private var window: [Double] = []
    private(set) var value: Double?

    @discardableResult
    mutating func add(_ raw: Double) -> Double {
        window.append(raw)
        if window.count > Self.windowSize { window.removeFirst() }
        let median = window.sorted()[window.count / 2]
        let next = value.map { $0 + Self.alpha * (median - $0) } ?? median
        value = next
        return next
    }

    mutating func reset() {
        window.removeAll(keepingCapacity: true)
        value = nil
    }
}
