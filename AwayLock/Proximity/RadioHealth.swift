/// Is the Mac's own Bluetooth hearing anything? While an engine scans, adverts from *any*
/// peripheral count. Silence from everyone, where there is usually plenty, means the radio stalled,
/// not that the device left.
///
/// Baseline: median ambient adverts per 5 s of scanning, over the last 120 buckets (10 min of scanning).
nonisolated struct RadioHealth: Sendable {
    static let silence: Duration = .seconds(5)
    static let minBaseline = 5
    static let buckets = 120

    private var counts: [Int] = []
    private var bucketStart: ContinuousClock.Instant?
    private var scanStart: ContinuousClock.Instant?
    private var inBucket = 0
    private var lastAmbient: ContinuousClock.Instant?

    /// One advert from anyone. Call before filtering for the target.
    mutating func heard(at now: ContinuousClock.Instant) {
        inBucket += 1
        lastAmbient = now
    }

    /// Call on every sample. Only continuous scanning fills buckets.
    mutating func sample(at now: ContinuousClock.Instant, scanning: Bool) {
        guard scanning else { scanStart = nil; bucketStart = nil; return }
        if scanStart == nil { scanStart = now; bucketStart = now; inBucket = 0 }
        if let start = bucketStart, now - start >= Self.silence {
            counts.append(inBucket)
            if counts.count > Self.buckets { counts.removeFirst() }
            bucketStart = now
            inBucket = 0
        }
    }

    var baseline: Int? {
        guard !counts.isEmpty else { return nil }
        return counts.sorted()[counts.count / 2]
    }

    /// Healthy unless scanning has run ≥ 5 s with silence from everyone, where the baseline says there's traffic.
    func isHealthy(at now: ContinuousClock.Instant) -> Bool {
        guard let scanStart, now - scanStart >= Self.silence, let baseline else { return true }
        let heard = max(lastAmbient ?? scanStart, scanStart)
        return !Self.isStalled(lastAmbient: heard, baseline: baseline, now: now)
    }

    static func isStalled(lastAmbient: ContinuousClock.Instant, baseline: Int, now: ContinuousClock.Instant) -> Bool {
        baseline >= minBaseline && now - lastAmbient >= silence
    }
}
