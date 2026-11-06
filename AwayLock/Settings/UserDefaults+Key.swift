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
        static let autoUnlock = "autoUnlock"
        static let isAutoStart = "isAutoStart"
        static let signalMode = "signalMode"
        static let untrackableUUIDs = "untrackableUUIDs"
    }
}
