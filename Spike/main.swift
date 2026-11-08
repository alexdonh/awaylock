// Spike: command-line experiments for the risky parts (tracking, locking, unlocking, idle detection).
//
//   spike scan    [--minutes 30]          CSV of every LE advert (1 row / device / s) + per-UUID summary
//   spike connect <uuid> [--minutes 30]   connected-mode readRSSI every 1 s, logs disconnects/reconnects
//   spike lock                            SACLockScreenImmediate via dlopen
//   spike awake   [--minutes 30]          hold PreventUserIdleDisplaySleep, log lock/unlock notifications
//   spike typetest                        lock, wait 5 s, wake display, type "abc" (dots in the password field?)
//   spike idle    [--minutes 5]           HID and session idle seconds every 0.5 s; declares user activity at 30 s
//   spike wake                            lock, wait 10 s, declare user activity: does Watch Auto Unlock fire?
//   spike continuity <uuid> [--minutes 10] the device's Nearby Info (0x10) payloads, one row per change
//
// `spike scan` also prints ambient adverts per 5 s in its summary.
//
// Pipe to a file: `spike scan --minutes 30 > iphone.csv`. Summary goes to stderr.

import CoreBluetooth
import Foundation
import IOKit.pwr_mgt
import CoreGraphics

let args = CommandLine.arguments.dropFirst()
let minutes = args.firstIndex(of: "--minutes").flatMap { Double(args[$0 + 1]) } ?? 30
func now() -> String { Date().ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true)) }
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func finish(after minutes: Double, _ summary: @escaping @MainActor () -> Void = {}) {
    DispatchQueue.main.asyncAfter(deadline: .now() + minutes * 60) {
        MainActor.assumeIsolated { summary() }
        exit(0)
    }
}

@MainActor
final class Scanner: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    struct Seen { var name: String?; var first: Date; var last: Date; var count: Int; var mfg: String }

    let target: UUID?
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var seen: [UUID: Seen] = [:]
    var lastPrinted: [UUID: Date] = [:]
    var continuity = false
    var lastNearby: String?
    /// Adverts from anyone per 5 s bucket, for the scan summary.
    var buckets: [Int] = []
    var bucketStart = Date()
    var inBucket = 0

    init(target: UUID?) {
        self.target = target
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        err("bluetooth state: \(central.state.rawValue) (5 = poweredOn)")
        guard central.state == .poweredOn else { return }
        if continuity {
            print("timestamp,mfg,nearbyInfo")
            err("lock, unlock, use and idle the phone; put the Watch on and off the wrist. Note the times.")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else if let target, let p = central.retrievePeripherals(withIdentifiers: [target]).first {
            connect(p)
        } else {
            if target == nil { print("timestamp,uuid,name,mfg,rssi,connectable,services") }
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        if continuity {
            guard p.identifier == target, let mfg = ad[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
            let hex = mfg.map { String(format: "%02x", $0) }.joined()
            let nearby = nearbyInfo(mfg)
            guard nearby != lastNearby else { return }
            lastNearby = nearby
            print("\(now()),\(hex),\(nearby ?? "")")
            return
        }
        if let target {
            guard p.identifier == target else { return }
            central.stopScan()
            connect(p)
            return
        }
        let id = p.identifier, t = Date()
        if t.timeIntervalSince(bucketStart) >= 5 {
            buckets.append(inBucket)
            inBucket = 0
            bucketStart = t
        }
        inBucket += 1
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        let mfg = (ad[CBAdvertisementDataManufacturerDataKey] as? Data)?.prefix(4).map { String(format: "%02x", $0) }.joined() ?? ""
        let connectable = (ad[CBAdvertisementDataIsConnectable] as? Bool) ?? false
        // Advertised service UUIDs plus service-data keys (e.g. FE95 = Xiaomi MiBeacon), space-separated.
        let uuids = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + ((ad[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?.keys.map { $0 } ?? [])
        let services = uuids.map(\.uuidString).joined(separator: " ")
        seen[id, default: Seen(name: name, first: t, last: t, count: 0, mfg: mfg)].last = t
        seen[id]!.count += 1
        if seen[id]!.name == nil { seen[id]!.name = name }
        if seen[id]!.mfg.isEmpty { seen[id]!.mfg = mfg }
        if let last = lastPrinted[id], t.timeIntervalSince(last) < 1 { return }
        lastPrinted[id] = t
        let safeName = (name ?? "").replacingOccurrences(of: ",", with: " ")
        print("\(now()),\(id),\(safeName),\(mfg),\(rssi),\(connectable),\(services)")
    }

    func summary() {
        err("\n== per-UUID summary (sorted by seconds visible) ==")
        err("uuid,name,mfg,first,last,seconds,adverts")
        for (id, s) in seen.sorted(by: { $0.value.last.timeIntervalSince($0.value.first) > $1.value.last.timeIntervalSince($1.value.first) }) {
            err("\(id),\(s.name ?? ""),\(s.mfg),\(s.first.ISO8601Format()),\(s.last.ISO8601Format()),\(Int(s.last.timeIntervalSince(s.first))),\(s.count)")
        }
        let sorted = buckets.sorted()
        if !sorted.isEmpty {
            err("\n== ambient adverts per 5 s ==")
            err("buckets \(sorted.count), min \(sorted[0]), p10 \(sorted[sorted.count / 10]), median \(sorted[sorted.count / 2]), max \(sorted.last!)")
            err("AwayLock infers a radio stall only where the median is >= 5")
        }
    }

    /// "type,len,hex value" of the Nearby Info TLV, with the activity nibble; nil if absent.
    func nearbyInfo(_ mfg: Data) -> String? {
        let b = [UInt8](mfg)
        guard b.count >= 2, b[0] == 0x4C, b[1] == 0x00 else { return nil }
        var i = 2
        while i + 2 <= b.count {
            let type = b[i], len = Int(b[i + 1])
            i += 2
            guard i + len <= b.count else { return nil }
            if type == 0x10, len > 0 {
                let value = b[i ..< i + len].map { String(format: "%02x", $0) }.joined()
                return "10,\(len),\(value),activity 0x\(String(format: "%02x", b[i] & 0x0F))"
            }
            i += len
        }
        return nil
    }

    // MARK: connected mode

    func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        err("\(now()) connecting \(p.identifier) \(p.name ?? "")")
        central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        print("\(now()),connected")
        tick()
    }

    func tick() {
        guard let p = peripheral, p.state == .connected else { return }
        p.readRSSI()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self.tick() } }
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI rssi: NSNumber, error: Error?) {
        print("\(now()),\(error.map { "error \($0.localizedDescription)" } ?? rssi.stringValue)")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        print("\(now()),disconnected,\(error?.localizedDescription ?? "")")
        central.connect(p) // pending connect: no timeout, fires didConnect when back
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        print("\(now()),failed,\(error?.localizedDescription ?? "")")
        central.connect(p)
    }
}

func lockNow() -> Never {
    let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
    guard let h = dlopen(path, RTLD_LAZY), let sym = dlsym(h, "SACLockScreenImmediate") else {
        err("SACLockScreenImmediate not found: \(String(cString: dlerror()))"); exit(1)
    }
    typealias Fn = @convention(c) () -> Int32
    let r = unsafeBitCast(sym, to: Fn.self)()
    err("SACLockScreenImmediate returned \(r)")
    exit(r == 0 ? 0 : 1)
}

func typeTest() -> Never {
    let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
    guard let h = dlopen(path, RTLD_LAZY), let sym = dlsym(h, "SACLockScreenImmediate") else { err("no SAC"); exit(1) }
    typealias Fn = @convention(c) () -> Int32
    _ = unsafeBitCast(sym, to: Fn.self)()
    sleep(5)
    var id: IOPMAssertionID = 0
    IOPMAssertionDeclareUserActivity("spike" as CFString, kIOPMUserActiveLocal, &id)
    usleep(800_000)
    let src = CGEventSource(stateID: .hidSystemState)
    for ch in "abc".utf16 {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
            e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [ch])
            e?.post(tap: .cghidEventTap)
        }
    }
    err("typed abc: did 3 dots appear in the password field? (host app needs Accessibility)")
    exit(0)
}

/// kCGAnyInputEventType
let anyInput = CGEventType(rawValue: ~0)!

let idleTimer = DispatchSource.makeTimerSource(queue: .main)

/// Does idle time reset on keyboard, trackpad, mouse, Screen Sharing — and not on DeclareUserActivity?
func idle() {
    print("timestamp,hidIdle,combinedIdle,note")
    err("touch each input in turn and note the time; at 30 s the spike declares user activity (should NOT reset)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("spike idle" as CFString, kIOPMUserActiveLocal, &id)
        print("\(now()),,,declared user activity")
    }
    // GCD, not Timer: dispatchMain() never runs the main run loop, so a Timer would never fire.
    idleTimer.schedule(deadline: .now(), repeating: 0.5)
    idleTimer.setEventHandler {
        let hid = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
        let combined = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        print("\(now()),\(String(format: "%.2f", hid)),\(String(format: "%.2f", combined)),")
    }
    idleTimer.resume()
}

/// Does waking the display alone let Apple Watch Auto Unlock fire?
func wake() {
    let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
    guard let h = dlopen(path, RTLD_LAZY), let sym = dlsym(h, "SACLockScreenImmediate") else { err("no SAC"); exit(1) }
    typealias Fn = @convention(c) () -> Int32
    _ = unsafeBitCast(sym, to: Fn.self)()
    err("\(now()) locked; waking in 10 s. Wear the Watch, unlocked, and don't touch the Mac.")
    func isLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("spike wake" as CFString, kIOPMUserActiveLocal, &id)
        err("\(now()) declared user activity")
        for s in 1...15 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(s)) {
                if !isLocked() { err("\(now()) UNLOCKED \(s) s after wake: Watch unlock works"); exit(0) }
                if s == 15 { err("\(now()) still locked after 15 s: needs a fallback (Shift key-up?)"); exit(1) }
            }
        }
    }
}

func holdAwake() {
    var id: IOPMAssertionID = 0
    let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "AwayLock spike" as CFString, &id)
    err("assertion \(r == kIOReturnSuccess ? "held" : "FAILED \(r)") for \(minutes) min — leave the Mac idle and watch for locks")
    print("timestamp,event")
    let dnc = DistributedNotificationCenter.default()
    for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked", "com.apple.screensaver.didstart", "com.apple.screensaver.didstop"] {
        dnc.addObserver(forName: .init(name), object: nil, queue: .main) { _ in print("\(now()),\(name)"); fflush(stdout) }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
var scanner: Scanner?
switch args.first {
case "scan":
    scanner = Scanner(target: nil)
    finish(after: minutes) { scanner?.summary() }
case "connect":
    guard let s = args.dropFirst().first, let uuid = UUID(uuidString: s) else { err("usage: spike connect <uuid>"); exit(2) }
    print("timestamp,rssi")
    scanner = Scanner(target: uuid)
    finish(after: minutes)
case "lock":
    lockNow()
case "typetest":
    typeTest()
case "idle":
    idle()
    finish(after: args.contains("--minutes") ? minutes : 5)
case "wake":
    wake()
case "continuity":
    guard let s = args.dropFirst().first, let uuid = UUID(uuidString: s) else { err("usage: spike continuity <uuid>"); exit(2) }
    scanner = Scanner(target: uuid)
    scanner?.continuity = true
    finish(after: args.contains("--minutes") ? minutes : 10)
case "awake":
    holdAwake()
    finish(after: minutes)
default:
    err("usage: spike scan|connect <uuid>|lock|awake|typetest|idle|wake|continuity <uuid> [--minutes N]")
    exit(2)
}
dispatchMain()
