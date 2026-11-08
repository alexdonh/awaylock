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
    case held(since: Duration)     // countdown ran out, but the user has been at the keyboard throughout
    case locked(byApp: Bool)
}

/// Why the current (or last) countdown started.
nonisolated enum LeaveReason: String, Sendable, Codable {
    case belowLevel   // readings kept coming, below the lock level
    case lost         // signal lost while falling or already weak
    case abrupt       // signal lost straight out of a strong, flat signal: likely the link, not the person
}

nonisolated enum UnlockMode: String, CaseIterable, Identifiable, Sendable {
    case off       // nothing
    case wake      // wake the display; Apple Watch Auto Unlock does the rest
    case password  // wake and type the Keychain password
    var id: Self { self }
}

nonisolated struct ProximitySettings: Sendable, Equatable {
    var lockRSSI: Double = -75
    var awaySeconds: Int = 10
    var lockOnSignalLost = true
    var keepAwakeWhileNear = true
    var activityGuard = true
    var unlockMode: UnlockMode = .off
    var unlockWindow: Duration = .seconds(30 * 60)
    /// Experimental: `password` unlock also needs recent Nearby Info activity from the device.
    var nearbyInfoGate = false

    static let `default` = ProximitySettings()
    static let hysteresis = 8.0
    static let stableMargin = 12.0
    /// Input within this long counts as "using the Mac".
    static let activeWindow: Duration = .seconds(5)
    /// Extra countdown for a loss straight out of a strong, flat signal.
    static let abruptLossExtra: Duration = .seconds(15)
    /// Slope (dB/s) at or above which a signal counts as flat.
    static let abruptSlope = -0.5
    /// A radio stall pauses a lost countdown at most this long. Security wins over convenience.
    static let stallLimit: Duration = .seconds(60)
    /// Nearby Info activity older than this doesn't count for `nearbyInfoGate`.
    static let activityFreshness: Duration = .seconds(30)

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
        case input(lastAt: Duration) // time of the last keyboard/mouse input, same clock as `now`
        case radio(healthy: Bool)   // the Mac's Bluetooth hears (or stopped hearing) anyone at all
        case activity(code: UInt8)  // Nearby Info activity code from the device's adverts
        case screenLocked(byApp: Bool)
        case screenUnlocked
        case lockFailed             // the lock call didn't take: count down again and retry
    }

    enum Effect: Sendable, Equatable {
        case lock
        case unlock                 // mode comes from settings: the controller wakes or types
        case holdAwake(Bool)
        case setCadence(Cadence)
    }

    static let unknownWindow: Duration = .seconds(5)
    static let returnHold: Duration = .seconds(3)

    private(set) var state: ProximityState = .idle
    private(set) var cadence: Cadence = .off
    private(set) var lastRaw: Double?
    /// Why the current or last countdown started, for the lock log and journal.
    private(set) var leaveReason: LeaveReason?
    var smoothed: Double? { filter.value }
    var slope: Double? { history.slope() }

    private var filter = RSSIFilter()
    private var history = RSSIHistory()
    private var belowSince: Duration?
    private var aboveSince: Duration?
    private var unlockSent = false
    private var screenLocked = false
    private var awake = false
    private var deadline: Duration?
    private var lastInputAt: Duration?
    private var lastInputSample: Duration?
    private var activeThrough = false
    private var stalledSince: Duration?
    private var lockedAt: Duration?
    private var unlockAttempts = 0
    private var lastActivity: (code: UInt8, at: Duration)?

    init() {}

    /// Seconds left on the away countdown, for the menu. Frozen while a radio stall pauses it.
    func remaining(at now: Duration) -> Duration? {
        guard case .leaving = state, let d = effectiveDeadline(now) else { return nil }
        return max(.zero, d - now)
    }

    /// Full length of the current countdown, for the menu's progress bar.
    var countdownTotal: Duration? {
        guard case .leaving(let since) = state, let deadline else { return nil }
        return deadline - since
    }

    mutating func handle(_ event: Event, at now: Duration, settings s: ProximitySettings) -> [Effect] {
        var effects: [Effect] = []
        var fresh = false

        switch event {
        case .start:
            filter.reset()
            history.reset()
            lastRaw = nil; belowSince = nil; aboveSince = nil; deadline = nil; stalledSince = nil
            state = .unknown(until: now + Self.unknownWindow)

        case .stop:
            state = .idle

        case .reading(let raw):
            fresh = true
            lastRaw = raw
            filter.add(raw)
            history.add(raw, at: now)
            belowSince = raw < s.lockRSSI ? (belowSince ?? now) : nil
            radioRecovered(now)   // a reading proves the radio works

        case .lost:
            lastRaw = nil
            // Countdown from detection, not the last reading: detection already lags 2× cadence,
            // and backdating would turn a short dropout into an instant lock.
            if s.lockOnSignalLost, state == .near(armed: true) {
                // A walk-away fades first. Gone straight out of a strong, flat signal is the link.
                let abrupt = (smoothed ?? -.infinity) >= s.stableRSSI
                    && (history.slope() ?? 0) >= ProximitySettings.abruptSlope
                beginLeaving(since: now, delay: s.awayDelay + (abrupt ? ProximitySettings.abruptLossExtra : .zero),
                             reason: abrupt ? .abrupt : .lost, now: now)
            }

        case .tick:
            break

        case .input(let at):
            // Back-to-back samples whose input times are further apart than the window: a gap that
            // fell between two checks. Sparse (stable-cadence) samples prove nothing, so skip those.
            if let prev = lastInputAt, let sampled = lastInputSample, now - sampled <= .seconds(2),
               at - prev > ProximitySettings.activeWindow {
                activeThrough = false
            }
            lastInputAt = at
            lastInputSample = now

        case .radio(let healthy):
            if healthy { radioRecovered(now) } else if stalledSince == nil { stalledSince = now }

        case .activity(let code):
            lastActivity = (code, now)

        case .lockFailed:
            if state == .locked(byApp: true) {
                beginLeaving(since: now, delay: s.awayDelay, reason: leaveReason ?? .belowLevel, now: now)
            }

        case .screenLocked(let byApp):
            screenLocked = true
            let alreadyOurs = byApp && state == .locked(byApp: true)
            if state != .idle, !alreadyOurs { enterLocked(byApp: byApp, now) }

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
        if case .unknown(let until) = state, now >= until {
            state = screenLocked ? .locked(byApp: false)
                                 : .near(armed: (smoothed ?? -.infinity) >= s.lockRSSI)
        }
        switch state {
        case .leaving, .held: activeThrough = activeThrough && isActive(now)   // one gap ends it for the episode
        default: break
        }
        fireIfDue(now, s, &effects)

        // Level-driven transitions: only on a new reading.
        if fresh, let v = smoothed {
            switch state {
            case .near(armed: false) where v >= s.backRSSI:
                state = .near(armed: true)
            case .near(armed: true) where v < s.lockRSSI:
                beginLeaving(since: belowSince ?? now, delay: s.awayDelay, reason: .belowLevel, now: now)
                fireIfDue(now, s, &effects)
            case .leaving where v >= s.backRSSI, .held where v >= s.backRSSI:
                state = .near(armed: true)
                deadline = nil
            case .locked(byApp: true) where s.unlockMode != .off:
                if v >= s.backRSSI {
                    let since = aboveSince ?? now
                    aboveSince = since
                    if !unlockSent, now - since >= Self.returnHold, unlockAllowed(now, s) {
                        unlockSent = true
                        if s.unlockMode == .password { unlockAttempts += 1 }
                        effects.append(.unlock)
                    }
                } else {
                    aboveSince = nil
                    unlockSent = false   // hysteresis only; `unlockAttempts` is the hard cap
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
        let want = desiredCadence(s, now)
        if want != cadence {
            cadence = want
            effects.append(.setCadence(want))
        }
        return effects
    }

    // MARK: countdown

    private func isActive(_ now: Duration) -> Bool {
        lastInputAt.map { now - $0 <= ProximitySettings.activeWindow } ?? false
    }

    // ponytail: continuity is checked from when the machine *notices* leaving, not from `since`. In
    // passive mode's 10 s stable cadence that can be ~10 s late, so someone who sits down within that
    // window can hold the lock. Needs input history (a 1 Hz idle poll) to close.
    private mutating func beginLeaving(since: Duration, delay: Duration, reason: LeaveReason, now: Duration) {
        state = .leaving(since: since)
        deadline = since + delay
        leaveReason = reason
        activeThrough = isActive(now)   // must be active when leaving starts
    }

    /// The deadline, pushed out by the part of a radio stall that overlaps a lost countdown (capped).
    private func effectiveDeadline(_ now: Duration) -> Duration? {
        guard let deadline else { return nil }
        guard leaveReason != .belowLevel, let stalled = stalledSince,
              now - stalled < ProximitySettings.stallLimit,
              case .leaving(let since) = state else { return deadline }
        return deadline + (now - max(stalled, since))
    }

    private mutating func radioRecovered(_ now: Duration) {
        guard stalledSince != nil else { return }
        deadline = effectiveDeadline(now)
        stalledSince = nil
    }

    private mutating func fireIfDue(_ now: Duration, _ s: ProximitySettings, _ effects: inout [Effect]) {
        let guarding = s.activityGuard && activeThrough
        switch state {
        case .leaving(let since):
            guard let d = effectiveDeadline(now), now >= d else { return }
            if guarding { state = .held(since: since) } else { lock(now, &effects) }
        case .held where !guarding:
            lock(now, &effects)
        default: break
        }
    }

    private mutating func lock(_ now: Duration, _ effects: inout [Effect]) {
        enterLocked(byApp: true, now)
        effects.append(.lock)
    }

    private mutating func enterLocked(byApp: Bool, _ now: Duration) {
        state = .locked(byApp: byApp)
        deadline = nil
        aboveSince = nil
        unlockSent = false
        unlockAttempts = 0
        lockedAt = byApp ? now : nil
    }

    // MARK: unlock gates

    /// Within the unlock window since the lock; for `password`, no earlier attempt this lock and,
    /// if `nearbyInfoGate` is on, fresh activity from the device. The caller already required a 3 s
    /// return to an app-made lock. A sleep since the lock never unlocks: waking restarts the machine
    /// into `locked(byApp: false)`.
    private func unlockAllowed(_ now: Duration, _ s: ProximitySettings) -> Bool {
        guard inUnlockWindow(now, s) else { return false }
        guard s.unlockMode == .password else { return true }
        guard unlockAttempts == 0 else { return false }
        guard s.nearbyInfoGate else { return true }
        guard let a = lastActivity, now - a.at <= ProximitySettings.activityFreshness else { return false }
        return NearbyInfo.unlockCodes.contains(a.code)
    }

    private func inUnlockWindow(_ now: Duration, _ s: ProximitySettings) -> Bool {
        lockedAt.map { now - $0 <= s.unlockWindow } ?? false
    }

    private func desiredCadence(_ s: ProximitySettings, _ now: Duration) -> Cadence {
        switch state {
        case .idle: return .off
        case .unknown, .leaving, .held: return .fast
        case .near(armed: false): return .stable
        case .near(armed: true):
            // Escalate on the raw value so a walk-away is sampled fast from its first reading.
            let low = min(lastRaw ?? .infinity, smoothed ?? .infinity)
            return low < s.stableRSSI ? .fast : .stable
        case .locked(byApp: true) where s.unlockMode != .off && inUnlockWindow(now, s):
            // Keep sampling: the link may never drop, so a return only shows up in readings.
            return (lastRaw ?? -.infinity) >= s.lockRSSI ? .fast : .stable
        case .locked:
            return .away
        }
    }
}
