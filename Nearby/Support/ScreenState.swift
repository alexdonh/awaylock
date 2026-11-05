import AppKit

nonisolated enum ScreenEvent: Sendable {
    case locked, unlocked, willSleep, didWake
}

enum ScreenState {
    /// Lives for the whole app, so observers are never removed.
    static func events() -> AsyncStream<ScreenEvent> {
        AsyncStream { continuation in
            let dnc = DistributedNotificationCenter.default()
            let ws = NSWorkspace.shared.notificationCenter
            let pairs: [(NotificationCenter, Notification.Name, ScreenEvent)] = [
                (dnc, .init("com.apple.screenIsLocked"), .locked),
                (dnc, .init("com.apple.screenIsUnlocked"), .unlocked),
                (ws, NSWorkspace.willSleepNotification, .willSleep),
                (ws, NSWorkspace.didWakeNotification, .didWake),
            ]
            for (center, name, event) in pairs {
                center.addObserver(forName: name, object: nil, queue: .main) { _ in continuation.yield(event) }
            }
        }
    }
}
