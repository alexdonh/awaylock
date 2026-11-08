import AppKit
import Observation

/// What the menu and settings show.
@Observable
final class ProximityModel {
    var state: ProximityState = .idle
    var rssi: Double?
    var remaining: Int?
    /// Length of the running countdown (away delay, plus the abrupt-loss extra when it applies).
    var countdownTotal: Int?
    var pausedUntil: Date?
    var bluetoothOff = false
    /// The last lock call didn't lock (e.g. "Require password" isn't immediate).
    var lockFailed = false
    /// Set when a newly chosen device failed the background trackability check.
    var untrackableName: String?
    /// A tuning hint from the lock history, shown in Settings until applied or dismissed.
    var suggestion: Suggestions.Suggestion?
    /// Why the running countdown started, so the menu can say why it is longer.
    var leaveReason: LeaveReason?
    /// The Mac's Bluetooth stopped hearing anyone; a lost countdown is paused.
    var radioStalled = false
}

/// Imperative shell: the only place effects run. Feeds the pure machine from the
/// engine, the screen-state stream, keyboard/mouse activity, settings changes and one cadence loop.
final class ProximityController {
    static let trackabilityCheck: Duration = .seconds(120)
    /// Radio unhealthy this long: rebuild the engine (a new CBCentralManager) once.
    static let radioRestartAfter: Duration = .seconds(15)
    /// A screen unlock this soon after our `.unlock` counts as ours.
    static let appUnlockAttribution: Duration = .seconds(10)

    let model = ProximityModel()
    let journal: Journal
    private let settings: AppSettings
    private let screen: any ScreenLocking
    private let power: any PowerAsserting
    private let unlocker: UnlockService
    private let activity: any ActivityReading
    private let makeEngine: @MainActor (AppSettings) -> any ProximityEngine

    private var machine = ProximityMachine()
    private var labeler = EpisodeLabeler()
    private var engine: (any ProximityEngine)?
    private var readingsTask: Task<Void, Never>?
    private var loop: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var radioTask: Task<Void, Never>?
    private var expectingLock = false
    private var asleep = false
    private var lastReadingAt: ContinuousClock.Instant?
    /// Last raw readings (seconds since start, dBm; nil = lost), logged with each lock.
    private var recent: [(t: Int, rssi: Int?)] = []
    private var pendingInstall: (() -> Void)?
    private var heldAt: Duration?
    private var lockDate: Date?
    private var unlockRequestedAt: Duration?
    private var lastActivityCode: UInt8?
    private var listening = false
    /// Non-nil while measuring: raw readings land here.
    private var collected: [Double]?
    /// Calibration sheet open: locking and unlocking are off, so the user can walk out and back.
    private var calibrating = false
    /// Readings before this (walking to the far spot) aren't kept.
    private var collectFrom: Duration = .zero
    private let epoch = ContinuousClock.now

    init(settings: AppSettings,
         screen: any ScreenLocking = SystemScreenLock(),
         power: any PowerAsserting = PowerAssertion(),
         unlocker: UnlockService = UnlockService(),
         activity: any ActivityReading = SystemActivity(),
         journal: Journal = Journal(),
         makeEngine: @escaping @MainActor (AppSettings) -> any ProximityEngine = ProximityEngineFactory.make) {
        self.settings = settings
        self.screen = screen
        self.power = power
        self.unlocker = unlocker
        self.activity = activity
        self.journal = journal
        self.makeEngine = makeEngine
    }

    func start() {
        Task {
            for await event in ScreenState.events() { handle(event) }
        }
        Task { [settings] in
            let device = observing { DeviceChoice(uuid: settings.deviceUUID, mode: settings.signalMode) }
            for await _ in device.dropFirst() { restart() }
        }
        Task { [settings] in
            for await _ in observing({ settings.proximity }).dropFirst() { send(.tick) }
        }
        // Tuning suggestions: on launch, then once a day.
        Task {
            while !Task.isCancelled {
                await refreshSuggestion()
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
        restart()
    }

    private var now: Duration { ContinuousClock.now - epoch }

    // MARK: menu actions

    func pause(for duration: Duration = .seconds(3600)) {
        model.pausedUntil = .now.addingTimeInterval(TimeInterval(duration.components.seconds))
        restart()
        resumeTask?.cancel()
        resumeTask = Task {
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { resume() }
        }
    }

    func resume() {
        resumeTask?.cancel()
        model.pausedUntil = nil
        restart()
    }

    /// A manual lock: `expectingLock` stays false, so it is never auto-unlocked.
    func lockNow() {
        Task { _ = await screen.lock() }
    }

    /// Picker choice. Third-party devices get a background check; failures revert.
    func choose(_ device: DiscoveredDevice) {
        let previous = (settings.deviceUUID, settings.deviceName, settings.deviceIsApple)
        settings.deviceName = device.name
        settings.deviceIsApple = device.isApple
        settings.deviceUUID = device.id
        checkTask?.cancel()
        guard !device.isApple else { return }
        checkTask = Task {
            try? await Task.sleep(for: Self.trackabilityCheck)
            guard !Task.isCancelled, settings.deviceUUID == device.id else { return }
            let heardRecently = lastReadingAt.map { ContinuousClock.now - $0 < Self.trackabilityCheck / 2 } ?? false
            // ponytail: "adverts stopped" only; add "near-identical device appeared" if bands slip through.
            guard !heardRecently else { return }
            settings.untrackableUUIDs.insert(device.id)
            model.untrackableName = device.name
            (settings.deviceUUID, settings.deviceName, settings.deviceIsApple) = previous
        }
    }

    // MARK: calibration

    /// Locking stays off from here until `endCalibration`, which the sheet calls when it closes,
    /// so walking back before pressing Apply can't lock on the old level.
    func beginCalibration() {
        calibrating = true
        send(.tick)
    }

    func endCalibration() {
        calibrating = false
        send(.tick)
    }

    /// Raw readings for `duration` after skipping `skip`, sampled fast. Cancelling ends early with
    /// what was collected.
    func collectReadings(for duration: Duration, skip: Duration = .zero) async -> [Double] {
        collected = []
        collectFrom = now + skip
        restartLoop(machine.cadence)
        try? await Task.sleep(for: skip + duration)
        let out = collected ?? []
        collected = nil
        restartLoop(machine.cadence)
        send(.tick)
        return out
    }

    // MARK: history

    /// Applies the suggestion and returns the change that undoes it.
    @discardableResult
    func applySuggestion() -> Suggestions.Change? {
        guard let change = model.suggestion?.change else { return nil }
        let undo: Suggestions.Change = switch change {
        case .lockRSSI: .lockRSSI(settings.lockRSSI)
        case .awaySeconds: .awaySeconds(settings.awaySeconds)
        }
        apply(change)
        dismissSuggestion()
        return undo
    }

    func apply(_ change: Suggestions.Change) {
        switch change {
        case .lockRSSI(let level): settings.lockRSSI = level
        case .awaySeconds(let n): settings.awaySeconds = n
        }
    }

    func dismissSuggestion() {
        settings.suggestionDismissedAt = .now
        model.suggestion = nil
    }

    func clearHistory() {
        model.suggestion = nil
        Task { await journal.clear() }
    }

    private func refreshSuggestion() async {
        if let dismissed = settings.suggestionDismissedAt, Date.now.timeIntervalSince(dismissed) < Suggestions.period {
            model.suggestion = nil
            return
        }
        let records = await journal.records()
        model.suggestion = Suggestions.evaluate(records, lockRSSI: settings.lockRSSI, awaySeconds: settings.awaySeconds)
    }

    private func write(_ record: JournalRecord) {
        Task { await journal.append(record) }
    }

    // MARK: updates

    var isSafeToRelaunch: Bool { machine.state == .near(armed: true) }

    /// Sparkle installs only while the device is near and no countdown runs.
    func whenSafeToRelaunch(_ install: @escaping () -> Void) {
        if isSafeToRelaunch { install() } else { pendingInstall = install }
    }

    // MARK: engine lifecycle

    private func restart() {
        stopEngine()
        radioTask?.cancel()
        model.radioStalled = false
        guard let id = settings.deviceUUID, model.pausedUntil == nil, !asleep else {
            send(.stop)
            return
        }
        startEngine(id)
        send(.stop)    // reset cadence so .start re-emits it for the new engine
        send(.start)
    }

    private func startEngine(_ id: UUID) {
        let engine = makeEngine(settings)
        self.engine = engine
        listening = false
        readingsTask = Task {
            for await reading in await engine.readings(for: id) { receive(reading) }
        }
    }

    private func stopEngine() {
        readingsTask?.cancel()
        loop?.cancel()
        if let engine { Task { await engine.stop() } }
        engine = nil
    }

    private func receive(_ reading: ProximityReading) {
        switch reading {
        case .rssi(let value):
            model.bluetoothOff = false
            lastReadingAt = .now
            radioTask?.cancel()   // a reading proves the radio works
            model.radioStalled = false
            send(.reading(value))
        case .lost:
            send(.lost)
        case .bluetoothOff:
            model.bluetoothOff = true
            send(.lost)
        case .radio(let healthy):
            radio(healthy: healthy)
        case .activity(let info):
            lastActivityCode = info.activity
            send(.activity(code: info.activity))
        }
    }

    private func radio(healthy: Bool) {
        model.radioStalled = !healthy
        var entry = JournalRecord(kind: .radio)
        entry.healthy = healthy
        write(entry)
        send(.radio(healthy: healthy))
        radioTask?.cancel()
        guard !healthy else { return }
        // Once per stall: the new engine starts without a baseline, so it can't report this stall again.
        radioTask = Task {
            try? await Task.sleep(for: Self.radioRestartAfter)
            guard !Task.isCancelled, let id = settings.deviceUUID, engine != nil else { return }
            Log.session.notice("radio stalled \(Self.radioRestartAfter, privacy: .public): restarting the Bluetooth engine")
            stopEngine()
            startEngine(id)
            restartLoop(machine.cadence)
        }
    }

    /// One timer: sample, report input, tick, sleep with tolerance so macOS can coalesce wakeups.
    private func restartLoop(_ cadence: Cadence) {
        loop?.cancel()
        guard let engine else { return }
        let cadence = collected == nil ? cadence : .fast
        let interval = engine.interval(for: cadence)
        loop = Task {
            await engine.setCadence(cadence)
            guard let interval else { return }
            while !Task.isCancelled {
                await engine.sample()
                send(.input(lastAt: now - .seconds(activity.idleSeconds())))
                send(.tick)
                try? await Task.sleep(for: interval, tolerance: interval / 5)
            }
        }
    }

    private func handle(_ event: ScreenEvent) {
        switch event {
        case .locked:
            labeler.locked(at: now, byApp: expectingLock)
            send(.screenLocked(byApp: expectingLock))
            expectingLock = false
        case .unlocked:
            let t = now
            let byApp = unlockRequestedAt.map { t - $0 <= Self.appUnlockAttribution } ?? false
            unlockRequestedAt = nil
            if let outcome = labeler.unlocked(at: t, byApp: byApp) { record(outcome) }
            send(.screenUnlocked)
        case .willSleep:
            asleep = true
            stopEngine()
            send(.stop)
        case .didWake:
            asleep = false
            restart()
        }
    }

    // MARK: machine

    /// While calibrating or measuring, locking and unlocking are off.
    private var effectiveSettings: ProximitySettings {
        var s = settings.proximity
        if calibrating || collected != nil {
            s.lockRSSI = -200
            s.lockOnSignalLost = false
            s.unlockMode = .off
        }
        return s
    }

    private func send(_ event: ProximityMachine.Event) {
        let now = self.now
        let s = effectiveSettings
        switch event {
        case .reading(let v): remember(now, Int(v))
        case .lost: remember(now, nil)
        default: break
        }
        let before = machine.state
        for effect in machine.handle(event, at: now, settings: s) { run(effect, now) }
        noteTransition(from: before, now, s)
        if case .reading(let raw) = event {
            if now >= collectFrom { collected?.append(raw) }
            if let v = machine.smoothed, let o = labeler.reading(at: now, smoothed: v, backRSSI: s.backRSSI) { record(o) }
        } else if let o = labeler.tick(at: now) {
            record(o)
        }
        publish(\.state, machine.state)
        publish(\.rssi, machine.smoothed)
        publish(\.remaining, machine.remaining(at: now).map { Int(($0 / .seconds(1)).rounded(.up)) })
        publish(\.countdownTotal, machine.countdownTotal.map { Int(($0 / .seconds(1)).rounded(.up)) })
        publish(\.leaveReason, machine.leaveReason)
        if let install = pendingInstall, isSafeToRelaunch {
            pendingInstall = nil
            install()
        }
    }

    /// Writes only real changes: every write invalidates the menu header and Settings, and events
    /// (input samples, ticks) arrive every second while a decision is close.
    private func publish<T: Equatable>(_ key: ReferenceWritableKeyPath<ProximityModel, T>, _ value: T) {
        if model[keyPath: key] != value { model[keyPath: key] = value }
    }

    private func noteTransition(from before: ProximityState, _ now: Duration, _ s: ProximitySettings) {
        let after = machine.state
        if case .held = after {
            if heldAt == nil {
                heldAt = now
                Log.session.notice("holding: device away, but you're using this Mac")
            }
        } else if let since = heldAt {
            heldAt = nil
            var entry = JournalRecord(kind: .held)
            entry.seconds = ((now - since) / .seconds(1)).rounded()
            write(entry)
        }
        // Experimental Nearby Info gate: listen while waiting to type the password.
        let listen = after == .locked(byApp: true) && s.unlockMode == .password && s.nearbyInfoGate
        if listen != listening, let engine {
            listening = listen
            Task { await engine.listenForActivity(listen) }
        }
    }

    private func record(_ outcome: EpisodeLabeler.Outcome) {
        var unlock = JournalRecord(t: lockDate?.addingTimeInterval(outcome.afterSeconds) ?? .now, kind: .unlock)
        unlock.by = outcome.byApp ? "app" : "user"
        unlock.afterSeconds = outcome.afterSeconds.rounded()
        unlock.nearAfter = outcome.nearAfter
        var label = JournalRecord(kind: .label)
        label.lock = lockDate
        label.verdict = outcome.verdict
        write(unlock)
        write(label)
        if outcome.verdict == .likelyFalse {
            Log.session.notice("lock looks false: unlocked by hand after \(Int(outcome.afterSeconds))s with the device near")
            Task {
                try? await Task.sleep(for: .seconds(1))   // after the writes above
                await refreshSuggestion()
            }
        }
    }

    private func remember(_ now: Duration, _ rssi: Int?) {
        recent.append((Int(now / .seconds(1)), rssi))
        if recent.count > 30 { recent.removeFirst() }
    }

    private func run(_ effect: ProximityMachine.Effect, _ now: Duration) {
        switch effect {
        case .lock:
            let s = settings.proximity
            let reason = machine.leaveReason ?? .belowLevel
            let slope = machine.slope
            let smoothed = machine.smoothed ?? 0
            let trace = recent.map { "\($0.t):\($0.rssi.map(String.init) ?? "lost")" }.joined(separator: " ")
            Log.session.notice("""
                locking: \(reason.rawValue, privacy: .public) \
                smoothed \(smoothed, privacy: .public) slope \(slope ?? .nan, privacy: .public) \
                lock \(s.lockRSSI, privacy: .public) delay \(s.awaySeconds, privacy: .public)s \
                trace \(trace, privacy: .public)
                """)
            var entry = JournalRecord(kind: .lock)
            entry.reason = reason
            entry.smoothed = machine.smoothed.map { ($0 * 10).rounded() / 10 }
            entry.slope = slope.map { ($0 * 100).rounded() / 100 }
            entry.lockRSSI = s.lockRSSI
            entry.awaySeconds = s.awaySeconds
            entry.mode = ProximityEngineFactory.resolve(settings.signalMode, isApple: settings.deviceIsApple,
                                                         name: settings.deviceName).rawValue
            entry.idle = (activity.idleSeconds() * 10).rounded() / 10
            entry.activity = s.nearbyInfoGate ? lastActivityCode : nil
            let t0 = recent.first?.t ?? 0
            entry.trace = recent.map { [$0.t - t0, $0.rssi] }
            expectingLock = true
            Task {
                let ok = await screen.lock()
                model.lockFailed = !ok
                if ok {
                    lockDate = entry.t
                    write(entry)
                } else {
                    expectingLock = false
                    send(.lockFailed)
                }
            }
        case .unlock:
            unlockRequestedAt = now
            switch settings.unlockMode {
            case .off:
                break
            case .wake:
                Log.session.info("device back: waking the display")
                UnlockService.wakeDisplay()
            case .password:
                Log.session.info("device back: unlocking")
                Task {
                    if await !unlocker.unlock(using: screen) {
                        Log.session.notice("unlock failed, not retrying this lock")
                    }
                }
            }
        case .holdAwake(let on):
            power.hold(on)
        case .setCadence(let cadence):
            restartLoop(cadence)
        }
    }
}

private nonisolated struct DeviceChoice: Equatable, Sendable {
    var uuid: UUID?
    var mode: SignalMode
}
