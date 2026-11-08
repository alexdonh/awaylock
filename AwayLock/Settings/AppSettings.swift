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
    nonisolated static let awayChoices = [0, 5, 10, 30, 60]
    static let unlockWindowChoices = [5, 30, 120]
    nonisolated static let rssiRange: ClosedRange<Double> = -95 ... -50

    @ObservationIgnored private let defaults: UserDefaults

    var deviceUUID: UUID? { didSet { defaults.set(deviceUUID?.uuidString, forKey: Key.deviceUUID) } }
    var deviceName: String { didSet { defaults.set(deviceName, forKey: Key.deviceName) } }
    var deviceIsApple: Bool { didSet { defaults.set(deviceIsApple, forKey: Key.deviceIsApple) } }
    var lockRSSI: Double { didSet { defaults.set(lockRSSI, forKey: Key.lockRSSI) } }
    var awaySeconds: Int { didSet { defaults.set(awaySeconds, forKey: Key.awaySeconds) } }
    var lockOnSignalLost: Bool { didSet { defaults.set(lockOnSignalLost, forKey: Key.lockOnSignalLost) } }
    var keepAwakeWhileNear: Bool { didSet { defaults.set(keepAwakeWhileNear, forKey: Key.keepAwakeWhileNear) } }
    var activityGuard: Bool { didSet { defaults.set(activityGuard, forKey: Key.activityGuard) } }
    /// For `password`, the password itself lives in the Keychain (UnlockService), never here.
    var unlockMode: UnlockMode { didSet { defaults.set(unlockMode.rawValue, forKey: Key.unlockMode) } }
    var unlockWindowMinutes: Int { didSet { defaults.set(unlockWindowMinutes, forKey: Key.unlockWindowMinutes) } }
    var suggestionDismissedAt: Date? { didSet { defaults.set(suggestionDismissedAt, forKey: Key.suggestionDismissedAt) } }
    /// Hidden flag, no UI. Read at launch.
    let experimentalNearbyInfo: Bool
    var isAutoStart: Bool { didSet { defaults.set(isAutoStart, forKey: Key.isAutoStart) } }
    var signalMode: SignalMode { didSet { defaults.set(signalMode.rawValue, forKey: Key.signalMode) } }
    var untrackableUUIDs: Set<UUID> {
        didSet { defaults.set(untrackableUUIDs.map(\.uuidString), forKey: Key.untrackableUUIDs) }
    }

    init(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Key.lockRSSI: -75.0, Key.awaySeconds: 10, Key.lockOnSignalLost: true,
            Key.keepAwakeWhileNear: true, Key.isAutoStart: true,
            Key.signalMode: SignalMode.auto.rawValue, Key.activityGuard: true, Key.unlockWindowMinutes: 30,
        ])
        self.defaults = defaults
        deviceUUID = defaults.string(forKey: Key.deviceUUID).flatMap(UUID.init(uuidString:))
        deviceName = defaults.string(forKey: Key.deviceName) ?? ""
        deviceIsApple = defaults.bool(forKey: Key.deviceIsApple)
        lockRSSI = defaults.double(forKey: Key.lockRSSI)
        awaySeconds = defaults.integer(forKey: Key.awaySeconds)
        lockOnSignalLost = defaults.bool(forKey: Key.lockOnSignalLost)
        keepAwakeWhileNear = defaults.bool(forKey: Key.keepAwakeWhileNear)
        activityGuard = defaults.bool(forKey: Key.activityGuard)
        // No default registered for unlockMode, so "absent" means "not migrated yet".
        // ponytail: drop the autoUnlock read once 1.0.x installs have had a release to migrate.
        let mode = defaults.string(forKey: Key.unlockMode).flatMap(UnlockMode.init(rawValue:))
            ?? (defaults.bool(forKey: Key.autoUnlock) ? .password : .off)
        defaults.set(mode.rawValue, forKey: Key.unlockMode)
        unlockMode = mode
        unlockWindowMinutes = defaults.integer(forKey: Key.unlockWindowMinutes)
        suggestionDismissedAt = defaults.object(forKey: Key.suggestionDismissedAt) as? Date
        experimentalNearbyInfo = defaults.bool(forKey: Key.experimentalNearbyInfo)
        isAutoStart = defaults.bool(forKey: Key.isAutoStart)
        signalMode = SignalMode(rawValue: defaults.string(forKey: Key.signalMode) ?? "") ?? .auto
        untrackableUUIDs = Set((defaults.stringArray(forKey: Key.untrackableUUIDs) ?? []).compactMap(UUID.init(uuidString:)))
    }

    var proximity: ProximitySettings {
        ProximitySettings(lockRSSI: lockRSSI, awaySeconds: awaySeconds, lockOnSignalLost: lockOnSignalLost,
                          keepAwakeWhileNear: keepAwakeWhileNear, activityGuard: activityGuard, unlockMode: unlockMode,
                          unlockWindow: .seconds(unlockWindowMinutes * 60), nearbyInfoGate: experimentalNearbyInfo)
    }
}

/// Signal as 0…1 across the slider range, for bars and needles.
nonisolated func signalFraction(_ rssi: Double) -> Double {
    let r = AppSettings.rssiRange
    return min(1, max(0, (rssi - r.lowerBound) / (r.upperBound - r.lowerBound)))
}
