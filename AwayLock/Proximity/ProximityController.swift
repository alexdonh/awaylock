import AppKit
import Observation

/// What the menu and settings show.
@Observable
final class ProximityModel {
    var state: ProximityState = .idle
    var rssi: Double?
    var remaining: Int?
    var pausedUntil: Date?
    var bluetoothOff = false
    /// The last lock call didn't lock (e.g. "Require password" isn't immediate).
    var lockFailed = false
    /// Set when a newly chosen device failed the background trackability check.
    var untrackableName: String?
}

/// Imperative shell: the only place effects run. Feeds the pure machine from the
/// engine, the screen-state stream, settings changes and one cadence loop.
final class ProximityController {
    static let trackabilityCheck: Duration = .seconds(120)

    let model = ProximityModel()
    private let settings: AppSettings
    private let screen: any ScreenLocking
    private let power: any PowerAsserting
    private let unlocker: UnlockService
    private let makeEngine: @MainActor (AppSettings) -> any ProximityEngine

    private var machine = ProximityMachine()
    private var engine: (any ProximityEngine)?
    private var readingsTask: Task<Void, Never>?
    private var loop: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var expectingLock = false
    private var asleep = false
    private var lastReadingAt: ContinuousClock.Instant?
    /// Last raw readings (seconds since start, dBm; nil = lost), logged with each lock.
    private var recent: [(t: Int, rssi: Int?)] = []
    private var pendingInstall: (() -> Void)?
    private let epoch = ContinuousClock.now

    init(settings: AppSettings,
         screen: any ScreenLocking = SystemScreenLock(),
         power: any PowerAsserting = PowerAssertion(),
         unlocker: UnlockService = UnlockService(),
         makeEngine: @escaping @MainActor (AppSettings) -> any ProximityEngine = ProximityEngineFactory.make) {
        self.settings = settings
        self.screen = screen
        self.power = power
        self.unlocker = unlocker
        self.makeEngine = makeEngine
    }

    func start() {
        Task {
            for await event in ScreenState.events() { handle(event) }
        }
        Task { [settings] in
            let device = Observations { DeviceChoice(uuid: settings.deviceUUID, mode: settings.signalMode) }
            for await _ in device.dropFirst() { restart() }
        }
        Task { [settings] in
            for await _ in Observations({ settings.proximity }).dropFirst() { send(.tick) }
        }
        restart()
    }

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

    // MARK: updates

    var isSafeToRelaunch: Bool { machine.state == .near(armed: true) }

    /// Sparkle installs only while the device is near and no countdown runs.
    func whenSafeToRelaunch(_ install: @escaping () -> Void) {
        if isSafeToRelaunch { install() } else { pendingInstall = install }
    }

    // MARK: engine lifecycle

    private func restart() {
        stopEngine()
        guard let id = settings.deviceUUID, model.pausedUntil == nil, !asleep else {
            send(.stop)
            return
        }
        let engine = makeEngine(settings)
        self.engine = engine
        readingsTask = Task {
            for await reading in await engine.readings(for: id) {
                switch reading {
                case .rssi(let value):
                    model.bluetoothOff = false
                    lastReadingAt = .now
                    send(.reading(value))
                case .lost:
                    send(.lost)
                case .bluetoothOff:
                    model.bluetoothOff = true
                    send(.lost)
                }
            }
        }
        send(.stop)    // reset cadence so .start re-emits it for the new engine
        send(.start)
    }

    private func stopEngine() {
        readingsTask?.cancel()
        loop?.cancel()
        if let engine { Task { await engine.stop() } }
        engine = nil
    }

    /// One timer: sample, tick, sleep with tolerance so macOS can coalesce wakeups.
    private func restartLoop(_ cadence: Cadence) {
        loop?.cancel()
        guard let engine else { return }
        let interval = engine.interval(for: cadence)
        loop = Task {
            await engine.setCadence(cadence)
            guard let interval else { return }
            while !Task.isCancelled {
                await engine.sample()
                send(.tick)
                try? await Task.sleep(for: interval, tolerance: interval / 5)
            }
        }
    }

    private func handle(_ event: ScreenEvent) {
        switch event {
        case .locked:
            send(.screenLocked(byApp: expectingLock))
            expectingLock = false
        case .unlocked:
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

    private func send(_ event: ProximityMachine.Event) {
        let now = ContinuousClock.now - epoch
        let s = settings.proximity
        switch event {
        case .reading(let v): remember(now, Int(v))
        case .lost: remember(now, nil)
        default: break
        }
        for effect in machine.handle(event, at: now, settings: s) { run(effect) }
        model.state = machine.state
        model.rssi = machine.smoothed
        model.remaining = machine.remaining(at: now, settings: s).map { Int(($0 / .seconds(1)).rounded(.up)) }
        if let install = pendingInstall, isSafeToRelaunch {
            pendingInstall = nil
            install()
        }
    }

    private func remember(_ now: Duration, _ rssi: Int?) {
        recent.append((Int(now / .seconds(1)), rssi))
        if recent.count > 30 { recent.removeFirst() }
    }

    private func run(_ effect: ProximityMachine.Effect) {
        switch effect {
        case .lock:
            let trace = recent.map { "\($0.t):\($0.rssi.map(String.init) ?? "lost")" }.joined(separator: " ")
            let s = settings.proximity
            let why = machine.lastRaw == nil ? "signal lost" : "below lock level"
            let smoothed = machine.smoothed ?? 0
            Log.session.notice("""
                locking: \(why, privacy: .public) \
                smoothed \(smoothed, privacy: .public) lock \(s.lockRSSI, privacy: .public) \
                delay \(s.awaySeconds, privacy: .public)s trace \(trace, privacy: .public)
                """)
            expectingLock = true
            Task {
                let ok = await screen.lock()
                model.lockFailed = !ok
                if !ok {
                    expectingLock = false
                    send(.lockFailed)
                }
            }
        case .unlock:
            guard settings.autoUnlock else { return }
            Log.session.info("device back: unlocking")
            Task { await unlocker.unlock(using: screen) }
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
