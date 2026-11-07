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
    private var adverts = 0
    nonisolated static let reconnectGrace: Duration = .seconds(3)
    /// Cap: a phone that keeps advertising but never reconnects still counts as lost after this.
    nonisolated static let hangUpGrace: Duration = .seconds(60)
    // ponytail: guess at a locked iPhone's advert gap. Tune from the "reconnected" log lines.
    nonisolated static let advertSilence: Duration = .seconds(10)

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

    nonisolated override init() { super.init() }

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

    func setCadence(_ cadence: Cadence) {}

    func sample() {
        guard let peripheral else { return }
        if peripheral.state == .connected {
            peripheral.readRSSI()
        } else if let since = disconnectedAt, !lostSent,
                  ContinuousClock.now >= Self.lostAt(since: since, grace: grace, lastAdvert: lastAdvert) {
            Log.bluetooth.notice("lost: no reconnect, \(self.adverts) adverts during outage")
            central?.stopScan()   // gone: only the pending connect waits, at no CPU cost
            lostSent = true
            continuation?.yield(.lost)
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
        guard p.identifier == target else { return }
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
        p.readRSSI()
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == target else { return }
        Log.bluetooth.notice("disconnected: \((error as? CBError)?.code.rawValue ?? -1)")
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
        if grace == Self.hangUpGrace {
            central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI rssi: NSNumber, error: Error?) {
        guard error == nil, let value = validRSSI(rssi) else { return }
        continuation?.yield(.rssi(value))
    }
}
