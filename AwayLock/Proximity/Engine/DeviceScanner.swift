import CoreBluetooth

nonisolated struct DiscoveredDevice: Sendable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Double
    var isApple: Bool
    var firstSeen: Date
    var lastSeen: Date
    var seconds: TimeInterval { lastSeen.timeIntervalSince(firstSeen) }
}

nonisolated struct ScanSnapshot: Sendable, Equatable {
    var devices: [DiscoveredDevice] = []
    /// Unnamed Apple devices: other people's, rotating addresses, can't be tracked.
    var rotating = 0
}

/// Picker scan: 1 Hz snapshots while the sheet is open, stops when the stream ends.
@BluetoothActor
final class DeviceScanner: NSObject {
    static let heardFor: TimeInterval = 10
    static let staleAfter: TimeInterval = 5

    private var central: CBCentralManager?
    private var named: [UUID: DiscoveredDevice] = [:]
    private var rotating: [UUID: Date] = [:]
    private var ticker: Task<Void, Never>?

    nonisolated override init() { super.init() }

    func scan() -> AsyncStream<ScanSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: ScanSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        central = CBCentralManager(delegate: self, queue: BluetoothActor.queue)
        ticker = Task {
            while !Task.isCancelled {
                continuation.yield(snapshot())
                try? await Task.sleep(for: .seconds(1))
            }
        }
        continuation.onTermination = { _ in Task { @BluetoothActor in self.stop() } }
        return stream
    }

    private func stop() {
        ticker?.cancel()
        central?.stopScan()
        central = nil
    }

    private func snapshot() -> ScanSnapshot {
        let now = Date()
        let devices = named.values
            .filter { now.timeIntervalSince($0.lastSeen) < Self.staleAfter && $0.seconds >= Self.heardFor }
            .sorted { $0.rssi > $1.rssi }
        let rotatingCount = rotating.values.filter { now.timeIntervalSince($0) < Self.staleAfter }.count
        return ScanSnapshot(devices: devices, rotating: rotatingCount)
    }
}

extension DeviceScanner: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        guard manager.state == .poweredOn else { return }
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ manager: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        guard let value = validRSSI(rssi) else { return }
        let mfg = ad[CBAdvertisementDataManufacturerDataKey] as? Data
        let isApple = mfg.map { $0.count >= 2 && $0[$0.startIndex] == 0x4C && $0[$0.startIndex + 1] == 0x00 } ?? false
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        let now = Date()
        guard let name, !name.isEmpty else {
            if isApple { rotating[p.identifier] = now }
            return
        }
        if var d = named[p.identifier] {
            d.rssi = d.rssi + 0.3 * (value - d.rssi)   // light smoothing for the live bar
            d.lastSeen = now
            d.name = name
            named[p.identifier] = d
        } else {
            named[p.identifier] = DiscoveredDevice(id: p.identifier, name: name, rssi: value, isApple: isApple,
                                                   firstSeen: now, lastSeen: now)
        }
    }
}
