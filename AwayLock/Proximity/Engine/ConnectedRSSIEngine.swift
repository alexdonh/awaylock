import CoreBluetooth

/// Connect once, then `readRSSI()` per sample. A pending `connect` waits in the
/// Bluetooth controller at no CPU cost, so "wait for the phone to come back" is free.
///
/// iOS drops an idle connection from an unpaired Mac every minute or two. A disconnect only
/// counts as lost once it has lasted a grace, checked on the next sample. The grace depends on
/// who ended the link: a hang-up (HCI 0x13) means the phone was in range to send it, and its
/// reconnect took up to 35 s with the phone on the desk (logs, 2026-11-06); a supervision
/// timeout is the radio losing the phone, so the short grace applies.
///
/// A hang-up's long grace is confirmed by adverts: while the link is down the engine scans for the
/// phone, and once it has heard the phone advertise, silence of `advertSilence` counts as lost.
/// `lastAdvert` survives outages, so a phone known to advertise is lost fast even if it left at once.
///
/// Every outage scan also counts adverts from anyone (`RadioHealth`): silence from everyone means
/// the Mac's radio stalled. The scan runs up to `hangUpGrace` into the outage, so a stall can still
/// be seen while a lost countdown runs. A link that stays "connected" but stops answering `readRSSI`
/// is dropped and reconnected (watchdog).
@BluetoothActor
final class ConnectedRSSIEngine: NSObject, ProximityEngine {
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var target: UUID?
    private var continuation: AsyncStream<ProximityReading>.Continuation?
    private var disconnectedAt: ContinuousClock.Instant?
    private var lostSent = false
    private var grace = ConnectedRSSIEngine.reconnectGrace
    private var lastAdvert: ContinuousClock.Instant?
    private var connectedAt: ContinuousClock.Instant?
    private var adverts = 0
    private var radio = RadioHealth()
    private var healthy = true
    private var missedRSSI = 0
    private let nearbyInfo: Bool
    private var listening = false
    private var lastListen: ContinuousClock.Instant?
    nonisolated static let reconnectGrace: Duration = .seconds(3)
    /// Cap: a phone that keeps advertising but never reconnects still counts as lost after this.
    nonisolated static let hangUpGrace: Duration = .seconds(60)
    // ponytail: guess at a locked iPhone's advert gap. Tune from the "reconnected" log lines.
    nonisolated static let advertSilence: Duration = .seconds(10)
    nonisolated static let watchdogMisses = 3
    /// Experimental Nearby Info: a 1 s listen every 5 s while connected.
    nonisolated static let listenEvery: Duration = .seconds(5)

    /// `readRSSI` went unanswered this many samples in a row on a "connected" link.
    nonisolated static func watchdogTripped(missed: Int) -> Bool { missed >= watchdogMisses }

    nonisolated static func grace(after error: Error?) -> Duration {
        (error as? CBError)?.code == .peripheralDisconnected ? hangUpGrace : reconnectGrace
    }

    /// When an outage that began at `since` counts as lost.
    nonisolated static func lostAt(since: ContinuousClock.Instant, grace: Duration,
                                   lastAdvert: ContinuousClock.Instant?) -> ContinuousClock.Instant {
        let cap = since + grace
        guard grace == hangUpGrace, let lastAdvert else { return cap }
        return min(cap, max(since, lastAdvert) + advertSilence)
    }

    nonisolated init(nearbyInfo: Bool = false) {
        self.nearbyInfo = nearbyInfo
        super.init()
    }

    nonisolated func interval(for cadence: Cadence) -> Duration? {
        switch cadence {
        case .fast: .seconds(1)
        case .stable: .seconds(5)
        case .away, .off: nil
        }
    }

    func readings(for device: UUID) -> AsyncStream<ProximityReading> {
        stop()
        target = device
        let (stream, continuation) = AsyncStream.makeStream(of: ProximityReading.self, bufferingPolicy: .bufferingNewest(8))
        self.continuation = continuation
        if let central { start(central) } else { central = CBCentralManager(delegate: self, queue: BluetoothActor.queue) }
        return stream
    }

    func setCadence(_ cadence: Cadence) {
        // No more samples coming: end an outage scan now (the first-connect scan has no peripheral yet).
        if interval(for: cadence) == nil, peripheral != nil { central?.stopScan() }
    }

    func listenForActivity(_ on: Bool) {
        listening = on && nearbyInfo
    }

    func sample() {
        guard let peripheral else { return }
        let now = ContinuousClock.now
        checkRadio(now)
        if peripheral.state == .connected {
            if Self.watchdogTripped(missed: missedRSSI) {
                Log.bluetooth.notice("rssi watchdog: reconnect")
                missedRSSI = 0
                central?.cancelPeripheralConnection(peripheral)   // → didDisconnect(nil): short grace, reconnect
                return
            }
            missedRSSI += 1
            peripheral.readRSSI()
            listenIfDue(now)
        } else if let since = disconnectedAt {
            if !lostSent, now >= Self.lostAt(since: since, grace: grace, lastAdvert: lastAdvert) {
                Log.bluetooth.notice("lost: no reconnect, \(self.adverts) adverts during outage")
                lostSent = true
                continuation?.yield(.lost)
            }
            // Gone and past the radio-check window: only the pending connect waits, at no CPU cost.
            if lostSent, now - since >= Self.hangUpGrace { central?.stopScan() }
        }
    }

    private func checkRadio(_ now: ContinuousClock.Instant) {
        radio.sample(at: now, scanning: central?.isScanning == true)
        let h = radio.isHealthy(at: now)
        guard h != healthy else { return }
        healthy = h
        Log.bluetooth.notice("radio \(h ? "healthy" : "stalled", privacy: .public), baseline \(self.radio.baseline ?? -1)")
        continuation?.yield(.radio(healthy: h))
    }

    private func listenIfDue(_ now: ContinuousClock.Instant) {
        guard listening, let central, !central.isScanning,
              lastListen.map({ now - $0 >= Self.listenEvery }) ?? true else { return }
        lastListen = now
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        Task {
            try? await Task.sleep(for: .seconds(1))
            if disconnectedAt == nil { self.central?.stopScan() }   // an outage scan keeps running
        }
    }

    func stop() {
        if let central, let peripheral { central.cancelPeripheralConnection(peripheral) }
        central?.stopScan()
        peripheral = nil
        target = nil
        disconnectedAt = nil
        lostSent = false
        lastAdvert = nil
        missedRSSI = 0
        listening = false
        continuation?.finish()
        continuation = nil
    }

    private func start(_ manager: CBCentralManager) {
        guard manager.state == .poweredOn, let target else { return }
        if let known = manager.retrievePeripherals(withIdentifiers: [target]).first {
            connect(known)
        } else {
            Log.bluetooth.debug("device not cached, scanning for it once")
            manager.scanForPeripherals(withServices: nil)
        }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        central?.connect(p)
    }
}

extension ConnectedRSSIEngine: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        Log.bluetooth.debug("central state \(manager.state.rawValue)")
        switch manager.state {
        case .poweredOn: start(manager)
        case .poweredOff, .unauthorized, .unsupported:
            peripheral = nil
            continuation?.yield(.bluetoothOff)
        default: break
        }
    }

    func centralManager(_ manager: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        radio.heard(at: .now)   // anyone counts, before the target filter
        guard p.identifier == target else { return }
        if nearbyInfo, let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           let info = ContinuityParser.nearbyInfo(mfg) {
            continuation?.yield(.activity(info))
        }
        if peripheral != nil {   // outage scan: the phone is still around
            lastAdvert = .now
            adverts += 1
            return
        }
        manager.stopScan()
        connect(p)
    }

    func centralManager(_ manager: CBCentralManager, didConnect p: CBPeripheral) {
        if let since = disconnectedAt {
            Log.bluetooth.notice("reconnected after \(ContinuousClock.now - since, privacy: .public), \(self.adverts) adverts")
        } else {
            Log.bluetooth.debug("connected")
        }
        manager.stopScan()
        disconnectedAt = nil
        lostSent = false
        missedRSSI = 0
        connectedAt = .now
        p.readRSSI()
        // Experiment: does GATT activity keep iOS from hanging up every ~67 s? Compare "up" in the logs.
        p.discoverServices(nil)
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == target else { return }
        let up = connectedAt.map { ContinuousClock.now - $0 }?.description ?? "-"
        Log.bluetooth.notice("disconnected: \((error as? CBError)?.code.rawValue ?? -1), up \(up, privacy: .public)")
        connectedAt = nil
        markDown(error)
        manager.connect(p)
    }

    func centralManager(_ manager: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p.identifier == target else { return }
        markDown(error)
        manager.connect(p)
    }

    /// The first failure of an outage picks its grace; retries inside it don't.
    private func markDown(_ error: Error?) {
        guard disconnectedAt == nil else { return }
        disconnectedAt = .now
        grace = Self.grace(after: error)
        adverts = 0
        // ponytail: duplicates scan wakes us for every nearby advert during the outage (≤ 60 s).
        // Every outage scans: adverts confirm a hang-up, and ambient adverts tell a radio stall from a loss.
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI rssi: NSNumber, error: Error?) {
        guard error == nil, let value = validRSSI(rssi) else { return }
        missedRSSI = 0
        continuation?.yield(.rssi(value))
    }
}
