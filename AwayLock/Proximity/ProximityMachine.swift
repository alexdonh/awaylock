/// How often the engine should sample. Engines map this to their own timings.
nonisolated enum Cadence: Sendable, Equatable {
    case off      // paused, asleep, no device
    case away     // locked / far: connected = pending connect only, passive = slow resample
    case stable   // near, well above threshold
    case fast     // a decision is close
}

nonisolated enum ProximityState: Sendable, Equatable {
    case idle                      // not running (no device, paused, asleep)
    case unknown(until: Duration)  // first 5 s after start/wake: no transitions
    case near(armed: Bool)         // armed = seen near since the last manual unlock; only armed can lock
    case leaving(since: Duration)  // countdown runs from `since`
    case locked(byApp: Bool)
}

nonisolated struct ProximitySettings: Sendable, Equatable {
    var lockRSSI: Double = -75
    var awaySeconds: Int = 10
    var lockOnSignalLost = true
    var keepAwakeWhileNear = true
    var autoUnlock = false

    static let `default` = ProximitySettings()
    static let hysteresis = 8.0
    static let stableMargin = 12.0

    var backRSSI: Double { lockRSSI + Self.hysteresis }
    var stableRSSI: Double { lockRSSI + Self.stableMargin }
    var awayDelay: Duration { .seconds(awaySeconds) }
}

/// Functional core: events in, effects out. No I/O, no clock reads — callers pass
/// the time (`now`, a monotonic offset), so tests run instantly on scripted traces.
///
/// Leaving's countdown is backdated to the first *raw* reading below the lock level
/// (smoothing only confirms the walk), so filter lag doesn't add to the away delay.
nonisolated struct ProximityMachine: Sendable {
    enum Event: Sendable, Equatable {
        case start                  // launch, wake, resume, device changed
        case stop                   // sleep, pause, no device
        case reading(Double)        // raw RSSI, dBm
        case lost                   // engine: no reading for 2× cadence, disconnect, Bluetooth off
        case tick                   // time passes
        case screenLocked(byApp: Bool)
        case screenUnlocked
        case lockFailed             // the lock call didn't take: count down again and retry
    }

    enum Effect: Sendable, Equatable {
        case lock
        case unlock
        case holdAwake(Bool)
        case setCadence(Cadence)
    }

    static let unknownWindow: Duration = .seconds(5)
    static let returnHold: Duration = .seconds(3)

    private(set) var state: ProximityState = .idle
    private(set) var cadence: Cadence = .off
    private(set) var lastRaw: Double?
    var smoothed: Double? { filter.value }

    private var filter = RSSIFilter()
    private var belowSince: Duration?
    private var aboveSince: Duration?
    private var unlockSent = false
    private var screenLocked = false
    private var awake = false

    init() {}

    /// Seconds left on the away countdown, for the menu.
    func remaining(at now: Duration, settings s: ProximitySettings) -> Duration? {
        guard case .leaving(let since) = state else { return nil }
        return max(.zero, since + s.awayDelay - now)
    }

    mutating func handle(_ event: Event, at now: Duration, settings s: ProximitySettings) -> [Effect] {
        var effects: [Effect] = []
        var fresh = false

        switch event {
        case .start:
            filter.reset()
            lastRaw = nil; belowSince = nil; aboveSince = nil
            state = .unknown(until: now + Self.unknownWindow)

        case .stop:
            state = .idle

        case .reading(let raw):
            fresh = true
            lastRaw = raw
            filter.add(raw)
            belowSince = raw < s.lockRSSI ? (belowSince ?? now) : nil

        case .lost:
            lastRaw = nil
            // Countdown from detection, not the last reading: detection already lags 2× cadence,
            // and backdating would turn a short dropout into an instant lock.
            if s.lockOnSignalLost, state == .near(armed: true) {
                state = .leaving(since: now)
            }

        case .tick:
            break

        case .lockFailed:
            if state == .locked(byApp: true) { state = .leaving(since: now) }

        case .screenLocked(let byApp):
            screenLocked = true
            let alreadyOurs = byApp && state == .locked(byApp: true)
            if state != .idle, !alreadyOurs { enterLocked(byApp: byApp) }

        case .screenUnlocked:
            screenLocked = false
            if case .locked = state {
                // Readings during the lock are only trustworthy if we kept sampling fast.
                let live = cadence == .fast
                if !live { filter.reset(); lastRaw = nil }
                state = .near(armed: live && (smoothed ?? -.infinity) >= s.backRSSI)
            }
        }

        // Time-driven transitions: on any event.
        switch state {
        case .unknown(let until) where now >= until:
            state = screenLocked ? .locked(byApp: false)
                                 : .near(armed: (smoothed ?? -.infinity) >= s.lockRSSI)
        case .leaving(let since) where now >= since + s.awayDelay:
            enterLocked(byApp: true)
            effects.append(.lock)
        default: break
        }

        // Level-driven transitions: only on a new reading.
        if fresh, let v = smoothed {
            switch state {
            case .near(armed: false) where v >= s.backRSSI:
                state = .near(armed: true)
            case .near(armed: true) where v < s.lockRSSI:
                state = .leaving(since: belowSince ?? now)
                if now >= (belowSince ?? now) + s.awayDelay {
                    enterLocked(byApp: true)
                    effects.append(.lock)
                }
            case .leaving where v >= s.backRSSI:
                state = .near(armed: true)
            case .locked(byApp: true) where s.autoUnlock:
                if v >= s.backRSSI {
                    let since = aboveSince ?? now
                    aboveSince = since
                    if !unlockSent, now - since >= Self.returnHold {
                        unlockSent = true
                        effects.append(.unlock)
                    }
                } else {
                    aboveSince = nil
                    unlockSent = false
                }
            default: break
            }
        }

        // Derived effects, emitted only on change.
        // Only while we actually hear the device: a lost signal never suppresses the system idle lock.
        let wantAwake = state == .near(armed: true) && s.keepAwakeWhileNear && lastRaw != nil
        if wantAwake != awake {
            awake = wantAwake
            effects.append(.holdAwake(wantAwake))
        }
        let want = desiredCadence(s)
        if want != cadence {
            cadence = want
            effects.append(.setCadence(want))
        }
        return effects
    }

    private mutating func enterLocked(byApp: Bool) {
        state = .locked(byApp: byApp)
        aboveSince = nil
        unlockSent = false
    }

    private func desiredCadence(_ s: ProximitySettings) -> Cadence {
        switch state {
        case .idle: return .off
        case .unknown, .leaving: return .fast
        case .near(armed: false): return .stable
        case .near(armed: true):
            // Escalate on the raw value so a walk-away is sampled fast from its first reading.
            let low = min(lastRaw ?? .infinity, smoothed ?? .infinity)
            return low < s.stableRSSI ? .fast : .stable
        case .locked(byApp: true) where s.autoUnlock:
            // Keep sampling: the link may never drop, so a return only shows up in readings.
            return (lastRaw ?? -.infinity) >= s.lockRSSI ? .fast : .stable
        case .locked:
            return .away
        }
    }
}
