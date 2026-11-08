import Foundation

enum ProximityEngineFactory {
    static func make(for settings: AppSettings) -> any ProximityEngine {
        switch resolve(settings.signalMode, isApple: settings.deviceIsApple, name: settings.deviceName) {
        case .passive: PassiveScanEngine(nearbyInfo: settings.experimentalNearbyInfo)
        default: ConnectedRSSIEngine(nearbyInfo: settings.experimentalNearbyInfo)
        }
    }

    // ponytail: Auto = connected for Apple phones/tablets, passive for watches and bands. Upgrade to
    // "try connect, fall back to passive" if some devices work either way.
    static func resolve(_ mode: SignalMode, isApple: Bool, name: String) -> SignalMode {
        guard mode == .auto else { return mode }
        return isApple && !name.localizedCaseInsensitiveContains("watch") ? .connected : .passive
    }
}
