import CoreBluetooth

/// Connect once, then `readRSSI()` per sample. A pending `connect` waits in the
/// Bluetooth controller at no CPU cost, so "wait for the phone to come back" is free.
///
/// iOS drops an idle connection from an unpaired Mac about every 67 s and accepts the
/// reconnect within ~1.3 s (M0 spike, macOS 27.2). A disconnect therefore only
/// counts as lost once it has lasted `reconnectGrace`, checked on the next sample.
@BluetoothActor
final class ConnectedRSSIEngine: NSObject, ProximityEngine {
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var target: UUID?
    private var continuation: AsyncStream<ProximityReading>.Continuation?
    private var disconnectedAt: ContinuousClock.Instant?
    private var lostSent = false
    static let reconnectGrace: Duration = .seconds(3)

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
        } else if let since = disconnectedAt, !lostSent, ContinuousClock.now - since >= Self.reconnectGrace {
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
        Log.bluetooth.debug("disconnected: \(error?.localizedDescription ?? "-")")
        disconnectedAt = disconnectedAt ?? .now
        manager.connect(p)
    }

    func centralManager(_ manager: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p.identifier == target else { return }
        disconnectedAt = disconnectedAt ?? .now
        manager.connect(p)
    }

    func peripheral(_ p: CBPeripheral, didReadRSSI rssi: NSNumber, error: Error?) {
        guard error == nil, let value = validRSSI(rssi) else { return }
        continuation?.yield(.rssi(value))
    }
}
