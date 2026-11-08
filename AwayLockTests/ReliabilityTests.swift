import Foundation
import Testing
@testable import AwayLock

// MARK: - Activity guard

struct ActivityGuardTests {
    /// Sharp drop to −85 at t = 20; `typing` says when someone is at the keyboard.
    static func trace(_ name: String, seconds: Double = 240, n: Int = 10, guardOn: Bool = true,
                      rssi: @escaping @Sendable (Double) -> Double? = { $0 < 20 ? -50 : -85 },
                      typing: @escaping @Sendable (Double) -> Bool) -> RSSITrace {
        var s = ProximitySettings.default
        s.awaySeconds = n
        s.activityGuard = guardOn
        var t = RSSITrace(name: name, seconds: seconds, settings: s, rssi: rssi)
        t.input = typing
        return t
    }

    @Test(arguments: EngineKind.allCases)
    func typingWithPhoneInBagHolds(engine: EngineKind) throws {
        let sim = Simulation.run(Self.trace("typing, phone in bag") { $0 < 200 }, engine: engine)
        let held = try #require(sim.firstHeld)
        #expect(held >= 20 + 10 - 1)
        // Typing until 200, then idle: locks once the 5 s window passes.
        #expect(sim.lockTimes.count == 1)
        let lock = try #require(sim.lockTimes.first)
        #expect(lock >= 200 + 4.9 && lock <= 200 + 6)
    }

    @Test(arguments: EngineKind.allCases)
    func inputStopsWhileHeldLocksWithinWindow(engine: EngineKind) throws {
        let sim = Simulation.run(Self.trace("stops at 60") { $0 < 60 }, engine: engine)
        let lock = try #require(sim.lockTimes.first)
        #expect(lock >= 60 + 4.9 && lock <= 60 + 6)
    }

    @Test(arguments: EngineKind.allCases)
    func idleBeforeLeavingLocksOnTime(engine: EngineKind) throws {
        let sim = Simulation.run(Self.trace("stops at 18") { $0 < 18 }, engine: engine)
        let lock = try #require(sim.lockTimes.first)
        #expect(sim.firstHeld == nil)
        #expect(lock >= 20 + 10 - 1 && lock <= 20 + 10 + 3 + (engine == .passive ? 10 : 0))
    }

    /// The user stands up at 19; someone sits down and types from 26. The gap ends the guard.
    /// Connected only: passive mode notices the walk-away up to 10 s late (see `beginLeaving`).
    @Test(arguments: [EngineKind.connected])
    func someoneSitsDownStillLocks(engine: EngineKind) throws {
        let sim = Simulation.run(Self.trace("someone sits down") { $0 < 19 || $0 >= 26 }, engine: engine)
        let lock = try #require(sim.lockTimes.first)
        #expect(sim.firstHeld == nil)
        #expect(lock <= 20 + 10 + 3 + (engine == .passive ? 10 : 0))
    }

    @Test(arguments: EngineKind.allCases)
    func lostWithContinuousInputHolds(engine: EngineKind) {
        let sim = Simulation.run(Self.trace("lost while typing", rssi: { $0 < 20 ? -50 : nil }) { _ in true }, engine: engine)
        #expect(sim.lockTimes.isEmpty)
        if case .held = sim.machine.state {} else { Issue.record("expected held, got \(sim.machine.state)") }
    }

    @Test(arguments: EngineKind.allCases)
    func heldThenDeviceReturns(engine: EngineKind) {
        let sim = Simulation.run(Self.trace("back while held", seconds: 120, rssi: { (20..<70).contains($0) ? -85 : -50 }) { _ in true },
                                 engine: engine)
        #expect(sim.firstHeld != nil)
        #expect(sim.lockTimes.isEmpty)
        #expect(sim.machine.state == .near(armed: true))
    }

    /// Guard off: the walk-away cases behave as before even with someone typing throughout.
    @Test(arguments: RSSITrace.walkAwayCases, EngineKind.allCases)
    func guardOffKeepsWalkAway(_ c: (trace: RSSITrace, leftAt: Double), engine: EngineKind) throws {
        var trace = c.trace
        trace.settings.activityGuard = false
        trace.input = { _ in true }
        let sim = Simulation.run(trace, engine: engine)
        let n = Double(trace.settings.awaySeconds)
        let lock = try #require(sim.lockTimes.first)
        let far = try #require(sim.firstFarReading)
        #expect(lock <= far + n + 3)
        #expect(lock >= c.leftAt + n - 1)
    }
}

// MARK: - Abrupt loss

struct LossPlausibilityTests {
    @Test(arguments: EngineKind.allCases)
    func flatThenSilentWaitsLonger(engine: EngineKind) throws {
        let sim = Simulation.run(RSSITrace(name: "link glitch at desk", seconds: 120) { $0 < 30 ? -50 : nil }, engine: engine)
        let lock = try #require(sim.lockTimes.first)
        #expect(lock >= 30 + 10 + 15)
        #expect(sim.machine.leaveReason == .abrupt)
    }

    @Test(arguments: EngineKind.allCases)
    func fadingThenSilentIsNormalLoss(engine: EngineKind) throws {
        // −50 → −72 over 15 s (stays above the −75 lock level), a few seconds there, then nothing.
        let sim = Simulation.run(RSSITrace(name: "fade then gone", seconds: 120) { t in
            t < 20 ? -50 : t < 35 ? -50 - (t - 20) * 22 / 15 : t < 45 ? -72 : nil
        }, engine: engine)
        let lock = try #require(sim.lockTimes.first)
        #expect(sim.machine.leaveReason == .lost)
        #expect(lock <= 45 + 2 + 10 + 2)
    }

    @Test(arguments: EngineKind.allCases)
    func flatSilentThenBackNeverLocks(engine: EngineKind) {
        let sim = Simulation.run(RSSITrace(name: "glitch, back at 40", seconds: 120) { (30..<40).contains($0) ? nil : -50 },
                                 engine: engine)
        #expect(sim.lockTimes.isEmpty)
    }

    @Test func sharpDropIsBelowLevel() {
        let sim = Simulation.run(RSSITrace(name: "sharp drop", seconds: 60) { $0 < 20 ? -50 : -85 })
        #expect(sim.lockTimes.count == 1)
        #expect(sim.machine.leaveReason == .belowLevel)
    }

    @Test func historySlope() throws {
        var h = RSSIHistory()
        #expect(h.slope() == nil)
        h.add(-50, at: .seconds(0))
        h.add(-52, at: .seconds(1))
        #expect(h.slope() == nil)   // < 3 points
        h.add(-54, at: .seconds(2))
        h.add(-56, at: .seconds(3))
        #expect(abs(try #require(h.slope()) - -2) < 1e-9)
        // Older than 10 s before the newest reading falls out.
        h.add(-40, at: .seconds(20))
        #expect(h.slope() == nil)
        h.reset()
        #expect(h.slope() == nil)
    }

    @Test func countdownTotalIncludesAbruptExtra() {
        var m = ProximityMachine()
        let s = ProximitySettings.default
        _ = m.handle(.start, at: .zero, settings: s)
        for t in 0...6 { _ = m.handle(.reading(-50), at: .seconds(t), settings: s) }
        _ = m.handle(.lost, at: .seconds(10), settings: s)
        #expect(m.countdownTotal == .seconds(25))
        #expect(m.remaining(at: .seconds(10)) == .seconds(25))
    }
}

// MARK: - Radio health

struct RadioHealthTests {
    /// Near at −50, lost (abrupt, deadline 20 + 25 = 45) at t = 20 with the radio stalled from t = 20.
    func stalled(healthyAt: Int?) -> (lock: Int?, frozen: Duration?) {
        var m = ProximityMachine()
        let s = ProximitySettings.default
        _ = m.handle(.start, at: .zero, settings: s)
        for t in 0...6 { _ = m.handle(.reading(-50), at: .seconds(t), settings: s) }
        _ = m.handle(.radio(healthy: false), at: .seconds(20), settings: s)
        _ = m.handle(.lost, at: .seconds(20), settings: s)
        var frozen: Duration?
        for t in 21...200 {
            if t == healthyAt {
                frozen = m.remaining(at: .seconds(t))
                _ = m.handle(.radio(healthy: true), at: .seconds(t), settings: s)
            }
            if m.handle(.tick, at: .seconds(t), settings: s).contains(.lock) { return (t, frozen) }
        }
        return (nil, frozen)
    }

    @Test func stallPausesLostCountdown() {
        let r = stalled(healthyAt: 50)
        #expect(r.frozen == .seconds(25))    // paused for the whole stall
        #expect(r.lock == 75)                // 45 + 30 s of stall
    }

    @Test func longStallStillLocks() {
        #expect(stalled(healthyAt: nil).lock == 80)   // 20 + stallLimit
    }

    @Test func stallDoesNotPauseBelowLevel() {
        var m = ProximityMachine()
        let s = ProximitySettings.default
        _ = m.handle(.start, at: .zero, settings: s)
        for t in 0...6 { _ = m.handle(.reading(-50), at: .seconds(t), settings: s) }
        _ = m.handle(.radio(healthy: false), at: .seconds(7), settings: s)
        var lockedAt: Int?
        for t in 8...60 where lockedAt == nil {
            if m.handle(.reading(-90), at: .seconds(t), settings: s).contains(.lock) { lockedAt = t }
        }
        #expect((lockedAt ?? 99) <= 8 + 10)
    }

    @Test func health() {
        let t0 = ContinuousClock.now
        func at(_ s: Int) -> ContinuousClock.Instant { t0 + .seconds(s) }
        #expect(RadioHealth.isStalled(lastAmbient: at(0), baseline: 5, now: at(5)))
        #expect(!RadioHealth.isStalled(lastAmbient: at(0), baseline: 4, now: at(5)))   // quiet place
        #expect(!RadioHealth.isStalled(lastAmbient: at(1), baseline: 50, now: at(5)))

        var h = RadioHealth()
        // 10 s of busy scanning builds a baseline of 20 per 5 s.
        for s in 0...10 {
            for _ in 0..<4 { h.heard(at: at(s)) }
            h.sample(at: at(s), scanning: true)
        }
        #expect(h.baseline == 20)
        #expect(h.isHealthy(at: at(10)))
        // Then silence from everyone.
        for s in 11...16 { h.sample(at: at(s), scanning: true) }
        #expect(!h.isHealthy(at: at(16)))
        // Not scanning: no verdict.
        h.sample(at: at(17), scanning: false)
        #expect(h.isHealthy(at: at(17)))
        // A fresh scan needs 5 s before it can call a stall.
        h.sample(at: at(18), scanning: true)
        #expect(h.isHealthy(at: at(20)))
    }

    @Test func watchdog() {
        #expect(!ConnectedRSSIEngine.watchdogTripped(missed: 2))
        #expect(ConnectedRSSIEngine.watchdogTripped(missed: 3))
    }
}

// MARK: - Unlock modes and limits

struct UnlockGateTests {
    func locked(_ s: ProximitySettings) -> (ProximityMachine, Int) {
        ProximityMachineTests().lockedByApp(s)
    }

    func unlocks(_ m: inout ProximityMachine, from: Int, to: Int, rssi: Double = -45, _ s: ProximitySettings) -> Int {
        var n = 0
        for t in from..<to where m.handle(.reading(rssi), at: .seconds(t), settings: s).contains(.unlock) { n += 1 }
        return n
    }

    @Test func noUnlockAfterWindow() {
        var s = ProximitySettings.default
        s.unlockMode = .password
        var (m, t) = locked(s)
        #expect(unlocks(&m, from: t + 40 * 60, to: t + 40 * 60 + 30, s) == 0)
    }

    @Test func unlockInsideWindow() {
        var s = ProximitySettings.default
        s.unlockMode = .password
        var (m, t) = locked(s)
        #expect(unlocks(&m, from: t + 29 * 60, to: t + 29 * 60 + 30, s) == 1)
    }

    @Test func onePasswordAttemptPerLock() {
        var s = ProximitySettings.default
        s.unlockMode = .password
        var (m, t) = locked(s)
        var n = unlocks(&m, from: t + 10, to: t + 20, s)
        n += unlocks(&m, from: t + 20, to: t + 30, rssi: -95, s)   // dips
        n += unlocks(&m, from: t + 30, to: t + 40, s)              // back again
        #expect(n == 1)
    }

    @Test func wakeModeUnlocks() {
        var s = ProximitySettings.default
        s.unlockMode = .wake
        var (m, t) = locked(s)
        #expect(unlocks(&m, from: t + 10, to: t + 20, s) == 1)
    }

    @Test func sleepSinceLockNeverUnlocks() {
        var s = ProximitySettings.default
        s.unlockMode = .password
        var (m, t) = locked(s)
        _ = m.handle(.stop, at: .seconds(t + 5), settings: s)
        _ = m.handle(.start, at: .seconds(t + 600), settings: s)
        for i in 0..<6 { _ = m.handle(.tick, at: .seconds(t + 600 + i), settings: s) }
        #expect(m.state == .locked(byApp: false))
        #expect(unlocks(&m, from: t + 610, to: t + 640, s) == 0)
    }

    /// Experimental: with `nearbyInfoGate`, `password` also needs fresh Nearby Info activity.
    @Test(arguments: [
        (UInt8?.none, 0, false),
        (UInt8(0x07), 0, true),
        (UInt8(0x0B), 0, true),
        (UInt8(0x0A), 0, true),
        (UInt8(0x03), 0, false),
        (UInt8(0x07), 40, false),
    ])
    func nearbyInfoGate(code: UInt8?, age: Int, expected: Bool) {
        var s = ProximitySettings.default
        s.unlockMode = .password
        s.nearbyInfoGate = true
        var (m, t) = locked(s)
        if let code { _ = m.handle(.activity(code: code), at: .seconds(t + 50 - age), settings: s) }
        #expect((unlocks(&m, from: t + 50, to: t + 70, s) == 1) == expected)
    }

    @MainActor @Test func migration() throws {
        func fresh() -> UserDefaults { UserDefaults(suiteName: "awaylock.tests.\(UUID().uuidString)")! }
        let on = fresh()
        on.set(true, forKey: "autoUnlock")
        #expect(AppSettings(defaults: on).unlockMode == .password)
        #expect(on.string(forKey: "unlockMode") == "password")

        let off = fresh()
        off.set(false, forKey: "autoUnlock")
        #expect(AppSettings(defaults: off).unlockMode == .off)
        #expect(AppSettings(defaults: fresh()).unlockMode == .off)

        // Already migrated: the old key no longer matters.
        let done = fresh()
        done.set(true, forKey: "autoUnlock")
        done.set("wake", forKey: "unlockMode")
        let settings = AppSettings(defaults: done)
        #expect(settings.unlockMode == .wake)
        #expect(settings.activityGuard)
        #expect(settings.proximity.unlockWindow == .seconds(30 * 60))
    }
}

// MARK: - Journal and labelling

struct EpisodeLabelerTests {
    @Test func manualUnlockWithDeviceNearIsLikelyFalse() {
        var l = EpisodeLabeler()
        l.locked(at: .seconds(100), byApp: true)
        #expect(l.unlocked(at: .seconds(108), byApp: false) == nil)
        let o = l.reading(at: .seconds(110), smoothed: -50, backRSSI: -67)
        #expect(o?.verdict == .likelyFalse)
        #expect(o?.afterSeconds == 8)
        #expect(o?.nearAfter == true)
    }

    @Test func lateManualUnlockIsLikelyGood() {
        var l = EpisodeLabeler()
        l.locked(at: .seconds(100), byApp: true)
        #expect(l.unlocked(at: .seconds(125), byApp: false)?.verdict == .likelyGood)
    }

    @Test func appUnlockIsNeverLikelyFalse() {
        var l = EpisodeLabeler()
        l.locked(at: .seconds(100), byApp: true)
        #expect(l.unlocked(at: .seconds(105), byApp: true)?.verdict == .likelyGood)
        #expect(l.reading(at: .seconds(106), smoothed: -40, backRSSI: -67) == nil)
    }

    @Test func farOrSilentAfterUnlock() {
        var l = EpisodeLabeler()
        l.locked(at: .seconds(0), byApp: true)
        _ = l.unlocked(at: .seconds(5), byApp: false)
        #expect(l.reading(at: .seconds(6), smoothed: -85, backRSSI: -67) == nil)
        #expect(l.tick(at: .seconds(11))?.verdict == .likelyGood)

        l.locked(at: .seconds(100), byApp: true)
        _ = l.unlocked(at: .seconds(105), byApp: false)
        #expect(l.tick(at: .seconds(108)) == nil)
        #expect(l.tick(at: .seconds(111))?.verdict == .unknown)
    }

    @Test func manualLockIsNotLabelled() {
        var l = EpisodeLabeler()
        l.locked(at: .seconds(0), byApp: false)
        #expect(l.unlocked(at: .seconds(5), byApp: false) == nil)
        #expect(l.tick(at: .seconds(20)) == nil)
    }

    @Test func journalRoundTripAndRotation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("awaylock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = Journal(directory: dir)
        var r = JournalRecord(t: Date(timeIntervalSince1970: 1_700_000_000), kind: .lock)
        r.reason = .abrupt
        r.trace = [[0, -55], [1, nil]]
        await journal.append(r)
        #expect(await journal.records() == [r])
        let line = try String(contentsOf: journal.url, encoding: .utf8)
        #expect(line.contains("\"trace\":[[0,-55],[1,null]]"))
        #expect(!line.contains("verdict"))   // nil fields are left out

        let big = JournalRecord(t: .now, kind: .held)
        for _ in 0..<(Journal.maxBytes / 40 + 10) { await journal.append(big) }
        let size = try #require(try FileManager.default.attributesOfItem(atPath: journal.url.path)[.size] as? Int)
        #expect(size <= Journal.maxBytes)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(Set(files) == ["journal.jsonl", "journal.1.jsonl"])

        await journal.clear()
        #expect(await journal.records().isEmpty)
    }
}

// MARK: - Calibration and suggestions

struct CalibrationTests {
    @Test func percentiles() {
        #expect(Calibration.percentile([], 10) == nil)
        #expect(Calibration.percentile([-60], 10) == -60)
        #expect(Calibration.percentile([-50, -60, -70, -80, -90], 50) == -70)
        #expect(Calibration.percentile([-90, -50], 10) == -86)
        #expect(Calibration.percentile([-90, -50], 90) == -54)
    }

    @Test func nearOnly() throws {
        let r = try #require(Calibration.result(near: Array(repeating: -55, count: 30), far: []))
        #expect(r.lockRSSI == -67)   // "near again" at −59, below every desk reading
        #expect(!r.warning)
    }

    @Test func midpoint() throws {
        let r = try #require(Calibration.result(near: Array(repeating: -55, count: 30), far: Array(repeating: -85, count: 10)))
        #expect(r.lockRSSI == -70)
        #expect(!r.warning)
    }

    @Test func nearAndFarAlike() throws {
        let r = try #require(Calibration.result(near: Array(repeating: -70, count: 30), far: Array(repeating: -75, count: 10)))
        #expect(r.warning)
    }

    @Test func clampsAndNeedsNear() throws {
        #expect(Calibration.result(near: [], far: [-80]) == nil)
        #expect(try #require(Calibration.result(near: [-30], far: [])).lockRSSI == AppSettings.rssiRange.upperBound)
    }

    static func falseLock(_ day: Double, reason: LeaveReason, smoothed: Double) -> [JournalRecord] {
        let t = Date(timeIntervalSince1970: 1_700_000_000 + day * 86_400)
        var lock = JournalRecord(t: t, kind: .lock)
        lock.reason = reason
        lock.smoothed = smoothed
        var label = JournalRecord(t: t.addingTimeInterval(10), kind: .label)
        label.lock = t
        label.verdict = .likelyFalse
        return [lock, label]
    }

    static let now = Date(timeIntervalSince1970: 1_700_000_000 + 7 * 86_400)

    @Test func suggestsLowerLockLevel() {
        let j = [1.0, 2, 3].flatMap { Self.falseLock($0, reason: .belowLevel, smoothed: -76 - $0) }
        #expect(Suggestions.evaluate(j, lockRSSI: -75, awaySeconds: 10, now: Self.now) == .init(change: .lockRSSI(-83), falseLocks: 3))
        // Two aren't enough.
        #expect(Suggestions.evaluate(Array(j.dropFirst(2)), lockRSSI: -75, awaySeconds: 10, now: Self.now) == nil)
    }

    @Test func suggestsLongerDelay() {
        let j = [1.0, 2, 3].flatMap { Self.falseLock($0, reason: $0 == 1 ? .abrupt : .lost, smoothed: -60) }
        #expect(Suggestions.evaluate(j, lockRSSI: -75, awaySeconds: 10, now: Self.now) == .init(change: .awaySeconds(30), falseLocks: 3))
        #expect(Suggestions.evaluate(j, lockRSSI: -75, awaySeconds: 60, now: Self.now) == nil)
    }

    @Test func ignoresOldAndGoodLocks() {
        let old = [-10.0, -9, -8].flatMap { Self.falseLock($0, reason: .lost, smoothed: -60) }
        #expect(Suggestions.evaluate(old, lockRSSI: -75, awaySeconds: 10, now: Self.now) == nil)
        var good = [1.0, 2, 3].flatMap { Self.falseLock($0, reason: .lost, smoothed: -60) }
        for i in good.indices where good[i].kind == .label { good[i].verdict = .likelyGood }
        #expect(Suggestions.evaluate(good, lockRSSI: -75, awaySeconds: 10, now: Self.now) == nil)
    }
}

// MARK: - Nearby Info parser

struct ContinuityParserTests {
    // ponytail: synthetic fixtures built from the published TLV layout. Replace with captures from `spike continuity`.
    static func hex(_ s: String) -> Data {
        let clean = s.filter(\.isHexDigit)
        return Data(stride(from: 0, to: clean.count, by: 2).map {
            let i = clean.index(clean.startIndex, offsetBy: $0)
            return UInt8(clean[i ... clean.index(after: i)], radix: 16)!
        })
    }

    @Test func nearbyInfoAlone() {
        #expect(ContinuityParser.nearbyInfo(Self.hex("4c00 1005 1b1c2d3e4f")) == NearbyInfo(activity: 0x0B, flags: 0x1))
    }

    @Test func nearbyInfoAfterOtherTLVs() {
        let data = Self.hex("4c00 0c0e 00112233445566778899aabbccdd 1005 071c2d3e4f")
        #expect(ContinuityParser.parse(data).map(\.type) == [0x0C, 0x10])
        #expect(ContinuityParser.nearbyInfo(data)?.activity == 0x07)
    }

    @Test func malformed() {
        #expect(ContinuityParser.parse(Self.hex("0600 1005 1b1c2d3e4f")).isEmpty)       // not Apple
        #expect(ContinuityParser.nearbyInfo(Self.hex("4c00 1005 1b1c")) == nil)         // truncated value
        #expect(ContinuityParser.nearbyInfo(Self.hex("4c00 10")) == nil)                // truncated header
        #expect(ContinuityParser.nearbyInfo(Self.hex("4c00 1000")) == nil)              // empty value
        #expect(ContinuityParser.nearbyInfo(Self.hex("4c")) == nil)
        #expect(ContinuityParser.nearbyInfo(Data()) == nil)
    }
}

// MARK: - History tab

struct HistoryTests {
    @Test func entriesAndStats() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var good = JournalRecord(t: t0, kind: .lock); good.reason = .belowLevel
        var goodLabel = JournalRecord(t: t0 + 30, kind: .label); goodLabel.lock = t0; goodLabel.verdict = .likelyGood
        var wrong = JournalRecord(t: t0 + 100, kind: .lock); wrong.reason = .abrupt
        var wrongLabel = JournalRecord(t: t0 + 108, kind: .label); wrongLabel.lock = t0 + 100; wrongLabel.verdict = .likelyFalse
        var userUnlock = JournalRecord(t: t0 + 108, kind: .unlock); userUnlock.by = "user"
        var appUnlock = JournalRecord(t: t0 + 200, kind: .unlock); appUnlock.by = "app"
        var held = JournalRecord(t: t0 + 300, kind: .held); held.seconds = 184
        var radio = JournalRecord(t: t0 + 400, kind: .radio); radio.healthy = false

        let e = History.entries([good, goodLabel, wrong, wrongLabel, userUnlock, appUnlock, held, radio])
        #expect(e.map(\.kind) == [.radio(healthy: false), .held(seconds: 184), .autoUnlock, .lock(.abrupt), .lock(.belowLevel)])
        #expect(e.map(\.chip) == [.bluetooth, .held, .autoUnlock, .probablyWrong, .good])
        #expect(History.stats(e, now: t0 + 500) == .init(locks: 2, probablyWrong: 1, held: 1))
        #expect(History.stats(e, now: t0 + 30 * 86_400) == .init())
    }
}
