import Foundation

extension UserDefaults {
    enum Key {
        static let deviceUUID = "deviceUUID"
        static let deviceName = "deviceName"
        static let deviceIsApple = "deviceIsApple"
        static let lockRSSI = "lockRSSI"
        static let awaySeconds = "awaySeconds"
        static let lockOnSignalLost = "lockOnSignalLost"
        static let keepAwakeWhileNear = "keepAwakeWhileNear"
        /// 1.0.x on/off auto-unlock. Read once to migrate into `unlockMode`.
        static let autoUnlock = "autoUnlock"
        static let unlockMode = "unlockMode"
        static let unlockWindowMinutes = "unlockWindowMinutes"
        static let activityGuard = "activityGuard"
        /// Hidden: `defaults write app.awaylock.mac experimentalNearbyInfo -bool true`.
        static let experimentalNearbyInfo = "experimentalNearbyInfo"
        static let suggestionDismissedAt = "suggestionDismissedAt"
        static let isAutoStart = "isAutoStart"
        static let signalMode = "signalMode"
        static let untrackableUUIDs = "untrackableUUIDs"
    }
}
