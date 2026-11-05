import Foundation

enum ProximityEngineFactory {
    static func make(for settings: AppSettings) -> any ProximityEngine {
        switch resolve(settings.signalMode, isApple: settings.deviceIsApple, name: settings.deviceName) {
        case .passive: PassiveScanEngine()
        default: ConnectedRSSIEngine()
        }
    }

    // ponytail: Auto = connected for Apple phones/tablets, passive for watches and bands (spec support
    // table). Upgrade to "try connect, fall back to passive" if M0 data shows mixed results.
    static func resolve(_ mode: SignalMode, isApple: Bool, name: String) -> SignalMode {
        guard mode == .auto else { return mode }
        return isApple && !name.localizedCaseInsensitiveContains("watch") ? .connected : .passive
    }
}
