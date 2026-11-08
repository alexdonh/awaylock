import Foundation

/// Lock level from a near sample (sitting as usual) and an optional far sample (where it should lock).
nonisolated enum Calibration {
    static let nearSeconds = 30
    /// Time to walk to the far spot; readings from it aren't used.
    static let walkSeconds = 10
    static let farSeconds = 20
    /// The "near again" level (lock + hysteresis) sits this far below the near P10, so normal desk
    /// readings re-arm and auto-unlock reliably. Lock = nearP10 − 8 − 4.
    static let backMargin = 4.0

    /// Linear-interpolated percentile, p in 0…100. nil for no values.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let rank = p / 100 * Double(s.count - 1)
        let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
    }

    /// nil when there are no near readings. With a far sample: the midpoint, but never so high that
    /// the "near again" level climbs into normal desk readings. `warning`: far readings don't fall
    /// below that level, so near and far can't be told apart.
    static func result(near: [Double], far: [Double]) -> (lockRSSI: Double, warning: Bool)? {
        guard let nearP10 = percentile(near, 10) else { return nil }
        let r = AppSettings.rssiRange
        let cap = nearP10 - ProximitySettings.hysteresis - backMargin
        let farP90 = percentile(far, 90)
        let level = min(r.upperBound, max(r.lowerBound, min(cap, farP90.map { ($0 + nearP10) / 2 } ?? cap).rounded()))
        return (level, farP90.map { $0 >= level } ?? false)
    }
}

/// Tuning hints from the journal's labelled locks. Shown in Settings, never applied automatically.
nonisolated enum Suggestions {
    static let period: TimeInterval = 7 * 24 * 3600
    static let minFalseLocks = 3
    static let margin = 4.0

    enum Change: Sendable, Equatable {
        case lockRSSI(Double)
        case awaySeconds(Int)
    }

    struct Suggestion: Sendable, Equatable {
        var change: Change
        /// Probably-wrong locks behind it, for "locked 3 times this week".
        var falseLocks: Int
    }

    static func evaluate(_ records: [JournalRecord], lockRSSI: Double, awaySeconds: Int,
                         now: Date = .now) -> Suggestion? {
        let since = now.addingTimeInterval(-period)
        let locks = Dictionary(records.filter { $0.kind == .lock }.map { ($0.t, $0) }, uniquingKeysWith: { a, _ in a })
        let falseLocks = records
            .filter { $0.kind == .label && $0.verdict == .likelyFalse && $0.t >= since }
            .compactMap { $0.lock.flatMap { locks[$0] } }

        let below = falseLocks.filter { $0.reason == .belowLevel }
        if below.count >= minFalseLocks, let low = below.compactMap(\.smoothed).min() {
            let r = AppSettings.rssiRange
            let level = min(r.upperBound, max(r.lowerBound, (low - margin).rounded()))
            if level < lockRSSI { return Suggestion(change: .lockRSSI(level), falseLocks: below.count) }
        }
        let lost = falseLocks.filter { $0.reason == .lost || $0.reason == .abrupt }
        if lost.count >= minFalseLocks, let next = AppSettings.awayChoices.first(where: { $0 > awaySeconds }) {
            return Suggestion(change: .awaySeconds(next), falseLocks: lost.count)
        }
        return nil
    }
}
