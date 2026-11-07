import CoreBluetooth
import Testing
@testable import AwayLock

typealias Effect = ProximityMachine.Effect

/// Which real engine's cadence table the simulation plays.
enum EngineKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case connected, passive
    var testDescription: String { rawValue }

    /// Seconds per sample for each cadence, read from the real engines (nil = no timer).
    var table: [Cadence: Double] {
        let engine: any ProximityEngine = self == .connected ? ConnectedRSSIEngine() : PassiveScanEngine()
        var t: [Cadence: Double] = [:]
        for c in [Cadence.off, .away, .stable, .fast] {
            if let d = engine.interval(for: c) { t[c] = d / .seconds(1) }
        }
        return t
    }
}

/// RSSI over time: seconds → raw dBm, or nil when the device is silent.
struct RSSITrace: Sendable, CustomTestStringConvertible {
    var name: String
    var seconds: Double
    var settings = ProximitySettings.default
    var rssi: @Sendable (Double) -> Double?
    var testDescription: String { name }
}

/// Plays engine + system: samples at the engine's interval for the machine's current cadence,
/// reports `.lost` after 2× cadence of silence, ticks every second, and answers `.lock` with
/// the screen-locked notification. 0.1 s steps.
struct Simulation {
    var machine = ProximityMachine()
    var log: [(t: Double, effect: Effect)] = []
    var firstFarReading: Double?

    mutating func send(_ e: ProximityMachine.Event, at t: Double, _ s: ProximitySettings) {
        let effects = machine.handle(e, at: .milliseconds(Int((t * 1000).rounded())), settings: s)
        for effect in effects { log.append((t, effect)) }
        if effects.contains(.lock) { send(.screenLocked(byApp: true), at: t, s) }
    }

    static func run(_ trace: RSSITrace, engine: EngineKind = .connected) -> Simulation {
        var sim = Simulation()
        let s = trace.settings
        let table = engine.table
        sim.send(.start, at: 0, s)
        var nextRead = 0.0, lastHeard = 0.0, lostSent = false
        for step in 0...Int(trace.seconds * 10) {
            let t = Double(step) / 10
            if let iv = table[sim.machine.cadence], t >= nextRead - 1e-9 {
                if let r = trace.rssi(t) {
                    if r < s.lockRSSI, sim.firstFarReading == nil { sim.firstFarReading = t }
                    sim.send(.reading(r), at: t, s); lastHeard = t; lostSent = false
                } else if !lostSent, t - lastHeard >= 2 * iv - 1e-9 {
                    sim.send(.lost, at: t, s); lostSent = true
                }
                nextRead = t + (table[sim.machine.cadence] ?? iv)
            }
            if step % 10 == 0 {
                let before = sim.machine.cadence
                sim.send(.tick, at: t, s)
                if sim.machine.cadence != before, let iv = table[sim.machine.cadence] { nextRead = min(nextRead, t + iv) }
            }
        }
        return sim
    }

    var lockTimes: [Double] { log.filter { $0.effect == .lock }.map(\.t) }
    func first(_ e: Effect) -> Double? { log.first { $0.effect == e }?.t }
    func has(_ e: Effect) -> Bool { log.contains { $0.effect == e } }
}

/// Deterministic jitter in [-amp, +amp].
nonisolated func jitter(_ t: Double, _ amp: Double) -> Double {
    var x = UInt64(t * 10) &* 6364136223846793005 &+ 1442695040888963407
    x ^= x >> 33
    return (Double(x % 10_000) / 10_000 * 2 - 1) * amp
}

extension RSSITrace {
    /// Walk-away cases: (trace, time the device crossed the lock level).
    static let walkAwayCases: [(RSSITrace, Double)] = [5, 10, 30, 60].flatMap { n -> [(RSSITrace, Double)] in
        var s = ProximitySettings.default
        s.awaySeconds = n
        return [
            // Sharp drop landing on a reading (t = 20).
            (RSSITrace(name: "sharp drop, N=\(n)", seconds: 120, settings: s) { $0 < 20 ? -50 : -85 }, 20),
            // Walking out: −50 → −90 over 10 s, starting at t = 22 (crosses −75 at t = 28.25).
            (RSSITrace(name: "fade out, N=\(n)", seconds: 140, settings: s) { t in
                t < 22 ? -50 : max(-90, -50 - (t - 22) * 4) + jitter(t, 2)
            }, 28.25),
        ]
    }
}

struct ProximityMachineTests {
    /// The machine's share of the latency: lock within N + 3 s of the first far reading it gets.
    /// Connected mode (5 s stable cadence) also meets N + 3 s from the moment the device crossed.
    /// Passive mode's 10 s stable cadence can add up to ~10 s of sampling lag on top (see BACKLOG).
    @Test("Locks within away delay + 3 s, never early",
          arguments: RSSITrace.walkAwayCases, EngineKind.allCases)
    func walkAway(_ c: (trace: RSSITrace, leftAt: Double), engine: EngineKind) throws {
        let sim = Simulation.run(c.trace, engine: engine)
        let n = Double(c.trace.settings.awaySeconds)
        let lock = try #require(sim.lockTimes.first)
        let far = try #require(sim.firstFarReading)
        #expect(lock <= far + n + 3)
        #expect(lock >= c.leftAt + n - 1)
        if engine == .connected { #expect(lock <= c.leftAt + n + 3) }
        #expect(sim.lockTimes.count == 1)
    }

    @Test(arguments: EngineKind.allCases)
    func outAndBackWithinDelayNeverLocks(engine: EngineKind) {
        let sim = Simulation.run(RSSITrace(name: "out and back", seconds: 120) { t in
            (30..<36).contains(t) ? -88 : -50
        }, engine: engine)
        #expect(sim.lockTimes.isEmpty)
    }

    @Test func singleSpikeNeverLocks() {
        var s = ProximitySettings.default
        s.awaySeconds = 5
        let sim = Simulation.run(RSSITrace(name: "spike", seconds: 120, settings: s) { t in
            abs(t - 30) < 0.05 ? -99 : -50
        })
        #expect(sim.lockTimes.isEmpty)
    }

    @Test(arguments: EngineKind.allCases)
    func deskDayNeverLocksAndStaysAwake(engine: EngineKind) {
        let sim = Simulation.run(RSSITrace(name: "8 h desk", seconds: 8 * 3600) { -50 + jitter($0, 6) }, engine: engine)
        #expect(sim.lockTimes.isEmpty)
        #expect(sim.has(.holdAwake(true)))
        #expect(!sim.has(.holdAwake(false)))
        #expect(sim.machine.cadence == .stable)
    }

    @Test(arguments: EngineKind.allCases)
    func backPocketWobbleNeverLocks(engine: EngineKind) {
        let sim = Simulation.run(RSSITrace(name: "pocket", seconds: 3600) { -68 + jitter($0, 8) }, engine: engine)
        #expect(sim.lockTimes.isEmpty)
    }

    @Test(arguments: [true, false], EngineKind.allCases)
    func signalLost(lockOnLost: Bool, engine: EngineKind) throws {
        var s = ProximitySettings.default
        s.lockOnSignalLost = lockOnLost
        let sim = Simulation.run(RSSITrace(name: "lost", seconds: 120, settings: s) { $0 < 20 ? -50 : nil }, engine: engine)
        #expect(sim.lockTimes.isEmpty == !lockOnLost)
        // Last reading before 20, lost detected after 2× stable cadence, then the full delay.
        let stable = try #require(engine.table[.stable])
        if lockOnLost { #expect(sim.lockTimes[0] <= 20 + 2 * stable + 10 + 1) }
        // Either way, a device we can't hear never holds the Mac awake.
        #expect(sim.has(.holdAwake(false)))
    }

    /// Link never drops (BLE reaches far beyond −75 dBm): the return must still show up.
    @Test(arguments: EngineKind.allCases)
    func autoUnlockWhenDeviceReturnsWithoutDropout(engine: EngineKind) throws {
        var s = ProximitySettings.default
        s.autoUnlock = true
        let sim = Simulation.run(RSSITrace(name: "away and back", seconds: 140, settings: s) { t in
            t < 20 ? -50 : t < 60 ? -85 : -45
        }, engine: engine)
        let lock = try #require(sim.lockTimes.first)
        let unlock = try #require(sim.first(.unlock))
        let stable = try #require(engine.table[.stable])
        #expect(lock < 60)
        #expect(unlock >= 60 + 3)
        #expect(unlock <= 60 + stable + 10)
    }

    @Test func briefDropoutThatRecoversNeverLocks() {
        let sim = Simulation.run(RSSITrace(name: "dropout", seconds: 120) { t in
            (30..<37).contains(t) ? nil : -50
        })
        #expect(sim.lockTimes.isEmpty)
    }

    @Test func noTransitionsInFirstFiveSeconds() {
        var m = ProximityMachine()
        let s = ProximitySettings.default
        _ = m.handle(.start, at: .zero, settings: s)
        for t in 0..<5 {
            #expect(m.handle(.reading(-95), at: .seconds(t), settings: s).contains(.lock) == false)
            if case .unknown = m.state {} else { Issue.record("left unknown at \(t)") }
        }
        // Started far (e.g. login without the phone): unarmed, never locks.
        _ = m.handle(.tick, at: .seconds(5), settings: s)
        #expect(m.state == .near(armed: false))
        for t in 6..<60 { #expect(!m.handle(.reading(-95), at: .seconds(t), settings: s).contains(.lock)) }
    }

    // MARK: scripted screen events

    /// Near, then walk away until the app locks. Returns machine and time of lock.
    func lockedByApp(_ s: ProximitySettings) -> (ProximityMachine, Int) {
        var m = ProximityMachine()
        _ = m.handle(.start, at: .zero, settings: s)
        for t in 0...6 { _ = m.handle(.reading(-50), at: .seconds(t), settings: s) }
        #expect(m.state == .near(armed: true))
        var t = 7
        while !m.handle(.reading(-90), at: .seconds(t), settings: s).contains(.lock) { t += 1 }
        _ = m.handle(.screenLocked(byApp: true), at: .seconds(t), settings: s)
        #expect(m.state == .locked(byApp: true))
        return (m, t)
    }

    @Test func manualUnlockWhileAwayDoesNotRelockUntilSeenNear() {
        let s = ProximitySettings.default
        var (m, t) = lockedByApp(s)
        _ = m.handle(.screenUnlocked, at: .seconds(t + 30), settings: s)
        #expect(m.state == .near(armed: false))
        var effects: [Effect] = []
        for i in 31..<120 { effects += m.handle(.reading(-90), at: .seconds(t + i), settings: s) }
        #expect(!effects.contains(.lock))
        #expect(!effects.contains(.holdAwake(true)))
        // Device returns → armed again, keep-awake on; then walking off locks again.
        for i in 120..<130 { effects += m.handle(.reading(-50), at: .seconds(t + i), settings: s) }
        #expect(m.state == .near(armed: true))
        #expect(effects.contains(.holdAwake(true)))
    }

    @Test func manualLockNeverAutoUnlocks() {
        var s = ProximitySettings.default
        s.autoUnlock = true
        var m = ProximityMachine()
        _ = m.handle(.start, at: .zero, settings: s)
        for t in 0...6 { _ = m.handle(.reading(-50), at: .seconds(t), settings: s) }
        _ = m.handle(.screenLocked(byApp: false), at: .seconds(7), settings: s)
        var effects: [Effect] = []
        for t in 8..<60 { effects += m.handle(.reading(-45), at: .seconds(t), settings: s) }
        #expect(!effects.contains(.unlock))
    }

    @Test func autoUnlockNeedsThreeSecondsSustained() {
        var s = ProximitySettings.default
        s.autoUnlock = true
        var (m, t) = lockedByApp(s)
        // A lucky reading, then far again: no unlock.
        var effects = m.handle(.reading(-40), at: .seconds(t + 10), settings: s)
        effects += m.handle(.reading(-40), at: .seconds(t + 11), settings: s)
        for i in 12..<20 { effects += m.handle(.reading(-95), at: .seconds(t + i), settings: s) }
        #expect(!effects.contains(.unlock))
        // Sustained return.
        var unlockedAt: Int?
        for i in 20..<40 where unlockedAt == nil {
            if m.handle(.reading(-45), at: .seconds(t + i), settings: s).contains(.unlock) { unlockedAt = i }
        }
        #expect(unlockedAt != nil)
        #expect((unlockedAt ?? 0) >= 23)
        // Our unlock lands: device is near, so armed straight away.
        _ = m.handle(.screenUnlocked, at: .seconds(t + 40), settings: s)
        #expect(m.state == .near(armed: true))
    }

    @Test func autoUnlockOffNeverUnlocks() {
        let s = ProximitySettings.default
        var (m, t) = lockedByApp(s)
        var effects: [Effect] = []
        for i in 1..<30 { effects += m.handle(.reading(-45), at: .seconds(t + i), settings: s) }
        #expect(!effects.contains(.unlock))
        #expect(m.cadence == .away)
    }

    @Test func stopReleasesKeepAwakeAndStopsSampling() {
        var m = ProximityMachine()
        let s = ProximitySettings.default
        _ = m.handle(.start, at: .zero, settings: s)
        for t in 0...6 { _ = m.handle(.reading(-50), at: .seconds(t), settings: s) }
        let effects = m.handle(.stop, at: .seconds(7), settings: s)
        #expect(effects == [.holdAwake(false), .setCadence(.off)])
    }
}

struct LockFailureTests {
    @Test func failedLockCountsDownAgainAndRetries() {
        let s = ProximitySettings.default
        var m = ProximityMachine()
        _ = m.handle(.start, at: .zero, settings: s)
        for t in 0...6 { _ = m.handle(.reading(-50), at: .seconds(t), settings: s) }
        var t = 7
        while !m.handle(.reading(-90), at: .seconds(t), settings: s).contains(.lock) { t += 1 }
        #expect(m.state == .locked(byApp: true))
        _ = m.handle(.lockFailed, at: .seconds(t + 2), settings: s)
        #expect(m.state == .leaving(since: .seconds(t + 2)))
        #expect(!m.handle(.tick, at: .seconds(t + 2 + 9), settings: s).contains(.lock))
        #expect(m.handle(.tick, at: .seconds(t + 2 + 10), settings: s).contains(.lock))
    }
}

struct DisconnectGraceTests {
    /// 2026-11-06: four false locks, each 3.1–3.4 s after iOS hung up (HCI 0x13) with the phone on the desk.
    @Test func hangUpWaitsLongRangeLossDoesNot() {
        #expect(ConnectedRSSIEngine.grace(after: CBError(.peripheralDisconnected)) == ConnectedRSSIEngine.hangUpGrace)
        #expect(ConnectedRSSIEngine.grace(after: CBError(.connectionTimeout)) == ConnectedRSSIEngine.reconnectGrace)
        #expect(ConnectedRSSIEngine.grace(after: nil) == ConnectedRSSIEngine.reconnectGrace)
    }

    @Test func hangUpIsConfirmedByAdverts() {
        typealias E = ConnectedRSSIEngine
        let t0 = ContinuousClock.now
        // Never heard advertising: fall back to the long grace.
        #expect(E.lostAt(since: t0, grace: E.hangUpGrace, lastAdvert: nil) == t0 + E.hangUpGrace)
        // Known to advertise (an earlier outage), silent now: lost after the silence window.
        #expect(E.lostAt(since: t0, grace: E.hangUpGrace, lastAdvert: t0 - .seconds(300)) == t0 + E.advertSilence)
        // Still advertising 20 s in: the deadline moves with the adverts.
        #expect(E.lostAt(since: t0, grace: E.hangUpGrace, lastAdvert: t0 + .seconds(20)) == t0 + .seconds(20) + E.advertSilence)
        // Advertising forever but never reconnecting: the cap still loses it.
        #expect(E.lostAt(since: t0, grace: E.hangUpGrace, lastAdvert: t0 + .seconds(59)) == t0 + E.hangUpGrace)
        // Supervision timeout ignores adverts.
        #expect(E.lostAt(since: t0, grace: E.reconnectGrace, lastAdvert: t0 + .seconds(2)) == t0 + E.reconnectGrace)
    }
}
