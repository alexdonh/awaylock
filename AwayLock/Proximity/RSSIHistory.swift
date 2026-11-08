/// Raw readings from the last 10 s of signal, for the trend of a loss.
nonisolated struct RSSIHistory: Sendable {
    static let window: Duration = .seconds(10)
    static let minPoints = 3

    private var points: [(t: Duration, dBm: Double)] = []

    mutating func add(_ dBm: Double, at t: Duration) {
        points.append((t, dBm))
        if let newest = points.last?.t { points.removeAll { newest - $0.t > Self.window } }
    }

    mutating func reset() { points.removeAll(keepingCapacity: true) }

    /// Least-squares slope in dB/s over the 10 s ending at the newest reading (a loss is detected
    /// after the readings stop, so the window can't end at "now"). nil below 3 readings.
    func slope() -> Double? {
        guard points.count >= Self.minPoints, let t0 = points.first?.t else { return nil }
        let xs = points.map { ($0.t - t0) / .seconds(1) }
        let ys = points.map(\.dBm)
        let n = Double(points.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 0 else { return nil }
        let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        return sxy / sxx
    }
}
