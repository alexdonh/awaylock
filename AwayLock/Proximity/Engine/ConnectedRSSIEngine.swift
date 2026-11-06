import CoreBluetooth

/// Connect once, then `readRSSI()` per sample. A pending `connect` waits in the
/// Bluetooth controller at no CPU cost, so "wait for the phone to come back" is free.
///
/// iOS drops an idle connection from an unpaired Mac every minute or two. A disconnect only
/// counts as lost once it has lasted a grace, checked on the next sample. The grace depends on
/// who ended the link: a hang-up (HCI 0x13) means the phone was in range to send it, and its
/// reconnect took up to 35 s with the phone on the desk (logs, 2026-11-06); a supervision
/// timeout is the radio losing the phone, so the short grace applies.
@BluetoothActor
final class ConnectedRSSIEngine: NSObject, ProximityEngine {
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var target: UUID?
    private var continuation: AsyncStream<ProximityReading>.Continuation?
    private var disconnectedAt: ContinuousClock.Instant?
    private var lostSent = false
    private var grace = ConnectedRSSIEngine.reconnectGrace
    nonisolated static let reconnectGrace: Duration = .seconds(3)
    // ponytail: a walk-away that starts with a hang-up locks after 60 s + away delay.
    // Upgrade: scan for the phone's adverts during the outage and lose it when they stop.
    nonisolated static let hangUpGrace: Duration = .seconds(60)

    nonisolated static func grace(after error: Error?) -> Duration {
        (error as? CBError)?.code == .peripheralDisconnected ? hangUpGrace : reconnectGrace
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
        } else if let since = disconnectedAt, !lostSent, ContinuousClock.now - since >= grace {
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
        manager.stopScan()
        connect(p)
    }

    func centralManager(_ manager: CBCentralManager, didConnect p: CBPeripheral) {
        Log.bluetooth.debug("connected")
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
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI rssi: NSNumber, error: Error?) {
        guard error == nil, let value = validRSSI(rssi) else { return }
        continuation?.yield(.rssi(value))
    }
}
