import CoreBluetooth

/// Listens to adverts from the chosen UUID; for bands and anything that refuses connections.
/// Reports the strongest advert per sample so the filter sees one reading per tick.
@BluetoothActor
final class PassiveScanEngine: NSObject, ProximityEngine {
    // ponytail: 1 s listen window per stable sample (spec). Raise if a band advertises slower
    // than once a second while connected to its phone (M0 CSV shows the advert rate).
    static let stableWindow: Duration = .seconds(1)

    private var central: CBCentralManager?
    private var target: UUID?
    private var continuation: AsyncStream<ProximityReading>.Continuation?
    private var cadence: Cadence = .fast
    private var best: Double?
    private var lastHeard = ContinuousClock.now
    private var lostSent = false
    private var window: Task<Void, Never>?

    nonisolated override init() { super.init() }

    nonisolated func interval(for cadence: Cadence) -> Duration? {
        switch cadence {
        case .fast: .seconds(1)
        case .stable: .seconds(10)
        case .away: .seconds(30)
        case .off: nil
        }
    }

    func readings(for device: UUID) -> AsyncStream<ProximityReading> {
        stop()
        target = device
        lastHeard = .now
        lostSent = false
        let (stream, continuation) = AsyncStream.makeStream(of: ProximityReading.self, bufferingPolicy: .bufferingNewest(8))
        self.continuation = continuation
        if central == nil { central = CBCentralManager(delegate: self, queue: BluetoothActor.queue) }
        return stream
    }

    func setCadence(_ cadence: Cadence) {
        self.cadence = cadence
        window?.cancel()
        switch cadence {
        case .fast: scan(duplicates: true)
        case .off, .stable: central?.stopScan()
        case .away: scan(duplicates: false)
        }
    }

    func sample() {
        if let iv = interval(for: cadence), !lostSent, ContinuousClock.now - lastHeard > iv * 2 {
            lostSent = true
            continuation?.yield(.lost)
        }
        switch cadence {
        case .fast:
            flush()
        case .stable:
            scan(duplicates: true)
            window?.cancel()
            window = Task {
                try? await Task.sleep(for: Self.stableWindow)
                guard !Task.isCancelled else { return }
                central?.stopScan()
                flush()
            }
        case .away:
            central?.stopScan()   // restart to resample: no-duplicates scans report a device once
            scan(duplicates: false)
        case .off:
            break
        }
    }

    func stop() {
        window?.cancel()
        central?.stopScan()
        target = nil
        best = nil
        continuation?.finish()
        continuation = nil
    }

    private func flush() {
        if let best { continuation?.yield(.rssi(best)) }
        best = nil
    }

    private func scan(duplicates: Bool) {
        guard let central, central.state == .poweredOn, target != nil else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: duplicates])
    }
}

extension PassiveScanEngine: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        switch manager.state {
        case .poweredOn: setCadence(cadence)
        case .poweredOff, .unauthorized, .unsupported: continuation?.yield(.bluetoothOff)
        default: break
        }
    }

    func centralManager(_ manager: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        // Filter first: drop every other device before touching anything.
        guard p.identifier == target, let value = validRSSI(rssi) else { return }
        lastHeard = .now
        lostSent = false
        if cadence == .away {
            continuation?.yield(.rssi(value))   // device is back: report at once
        } else {
            best = max(best ?? -.infinity, value)
        }
    }
}
