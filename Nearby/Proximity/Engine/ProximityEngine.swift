import Foundation

nonisolated enum ProximityReading: Sendable, Equatable {
    case rssi(Double)
    case lost          // disconnect, or no advert for 2× the cadence
    case bluetoothOff
}

/// Engines only report. The controller's single loop calls `sample()` at `interval(for:)`.
nonisolated protocol ProximityEngine: AnyObject, Sendable {
    /// Sampling period for a cadence; nil = no timer, wait for callbacks.
    func interval(for cadence: Cadence) -> Duration?
    func readings(for device: UUID) async -> AsyncStream<ProximityReading>
    func setCadence(_ cadence: Cadence) async
    func sample() async
    func stop() async
}

/// RSSI 127 means "not available"; anything ≥ 0 is junk.
nonisolated func validRSSI(_ n: NSNumber) -> Double? {
    let v = n.doubleValue
    return v < 0 ? v : nil
}
