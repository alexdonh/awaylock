import Foundation
import Observation

nonisolated enum SignalMode: String, CaseIterable, Identifiable, Sendable {
    case auto, connected, passive
    var id: Self { self }
}

/// One observable source for AppKit and SwiftUI; every write lands in UserDefaults.
@Observable
final class AppSettings {
    typealias Key = UserDefaults.Key
    static let awayChoices = [5, 10, 30, 60]
    nonisolated static let rssiRange: ClosedRange<Double> = -95 ... -50

    @ObservationIgnored private let defaults: UserDefaults

    var deviceUUID: UUID? { didSet { defaults.set(deviceUUID?.uuidString, forKey: Key.deviceUUID) } }
    var deviceName: String { didSet { defaults.set(deviceName, forKey: Key.deviceName) } }
    var deviceIsApple: Bool { didSet { defaults.set(deviceIsApple, forKey: Key.deviceIsApple) } }
    var lockRSSI: Double { didSet { defaults.set(lockRSSI, forKey: Key.lockRSSI) } }
    var awaySeconds: Int { didSet { defaults.set(awaySeconds, forKey: Key.awaySeconds) } }
    var lockOnSignalLost: Bool { didSet { defaults.set(lockOnSignalLost, forKey: Key.lockOnSignalLost) } }
    var keepAwakeWhileNear: Bool { didSet { defaults.set(keepAwakeWhileNear, forKey: Key.keepAwakeWhileNear) } }
    /// The password itself lives in the Keychain (UnlockService), never here.
    var autoUnlock: Bool { didSet { defaults.set(autoUnlock, forKey: Key.autoUnlock) } }
    var isAutoStart: Bool { didSet { defaults.set(isAutoStart, forKey: Key.isAutoStart) } }
    var signalMode: SignalMode { didSet { defaults.set(signalMode.rawValue, forKey: Key.signalMode) } }
    var untrackableUUIDs: Set<UUID> {
        didSet { defaults.set(untrackableUUIDs.map(\.uuidString), forKey: Key.untrackableUUIDs) }
    }

    init(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Key.lockRSSI: -75.0, Key.awaySeconds: 10, Key.lockOnSignalLost: true,
            Key.keepAwakeWhileNear: true, Key.autoUnlock: false, Key.isAutoStart: true,
            Key.signalMode: SignalMode.auto.rawValue,
        ])
        self.defaults = defaults
        deviceUUID = defaults.string(forKey: Key.deviceUUID).flatMap(UUID.init(uuidString:))
        deviceName = defaults.string(forKey: Key.deviceName) ?? ""
        deviceIsApple = defaults.bool(forKey: Key.deviceIsApple)
        lockRSSI = defaults.double(forKey: Key.lockRSSI)
        awaySeconds = defaults.integer(forKey: Key.awaySeconds)
        lockOnSignalLost = defaults.bool(forKey: Key.lockOnSignalLost)
        keepAwakeWhileNear = defaults.bool(forKey: Key.keepAwakeWhileNear)
        autoUnlock = defaults.bool(forKey: Key.autoUnlock)
        isAutoStart = defaults.bool(forKey: Key.isAutoStart)
        signalMode = SignalMode(rawValue: defaults.string(forKey: Key.signalMode) ?? "") ?? .auto
        untrackableUUIDs = Set((defaults.stringArray(forKey: Key.untrackableUUIDs) ?? []).compactMap(UUID.init(uuidString:)))
    }

    var proximity: ProximitySettings {
        ProximitySettings(lockRSSI: lockRSSI, awaySeconds: awaySeconds, lockOnSignalLost: lockOnSignalLost,
                          keepAwakeWhileNear: keepAwakeWhileNear, autoUnlock: autoUnlock)
    }
}

/// SF Symbol for a device, from its advertised name.
nonisolated func deviceSymbol(for name: String) -> String {
    let n = name.lowercased()
    if n.contains("watch") { return "applewatch" }
    if n.contains("iphone") { return "iphone" }
    if n.contains("airpods") { return "airpods" }
    if n.contains("ipad") { return "ipad" }
    return "dot.radiowaves.left.and.right"
}

/// Signal as 0…1 across the slider range, for bars and needles.
nonisolated func signalFraction(_ rssi: Double) -> Double {
    let r = AppSettings.rssiRange
    return min(1, max(0, (rssi - r.lowerBound) / (r.upperBound - r.lowerBound)))
}
