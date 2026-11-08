nonisolated enum LockVerdict: String, Sendable, Codable {
    case likelyFalse, likelyGood, unknown
}

/// Was a lock wrong? A lock is `likelyFalse` when AwayLock made it, the user unlocked by hand
/// within 20 s, and within 5 s after that the device read at or above the "back" level.
nonisolated struct EpisodeLabeler: Sendable {
    static let manualWindow: Duration = .seconds(20)
    static let nearWindow: Duration = .seconds(5)

    struct Outcome: Sendable, Equatable {
        var verdict: LockVerdict
        var byApp: Bool
        var afterSeconds: Double
        var nearAfter: Bool?   // nil = no reading after the unlock
    }

    private var lockedAt: Duration?
    private var pending: (at: Duration, after: Double, sawReading: Bool)?

    /// Only AwayLock's own locks are labelled.
    mutating func locked(at t: Duration, byApp: Bool) {
        lockedAt = byApp ? t : nil
        pending = nil
    }

    mutating func unlocked(at t: Duration, byApp: Bool) -> Outcome? {
        guard let lock = lockedAt else { return nil }
        lockedAt = nil
        let after = (t - lock) / .seconds(1)
        if byApp || t - lock > Self.manualWindow {
            return Outcome(verdict: .likelyGood, byApp: byApp, afterSeconds: after, nearAfter: nil)
        }
        pending = (t, after, false)
        return nil
    }

    mutating func reading(at t: Duration, smoothed: Double, backRSSI: Double) -> Outcome? {
        guard let p = pending, t - p.at <= Self.nearWindow else { return tick(at: t) }
        pending?.sawReading = true
        guard smoothed >= backRSSI else { return nil }
        pending = nil
        return Outcome(verdict: .likelyFalse, byApp: false, afterSeconds: p.after, nearAfter: true)
    }

    /// Closes the 5 s window once it has passed.
    mutating func tick(at t: Duration) -> Outcome? {
        guard let p = pending, t - p.at > Self.nearWindow else { return nil }
        pending = nil
        return Outcome(verdict: p.sawReading ? .likelyGood : .unknown, byApp: false, afterSeconds: p.after,
                       nearAfter: p.sawReading ? false : nil)
    }
}
