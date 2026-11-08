import CoreGraphics

protocol ActivityReading {
    /// Seconds since the last keyboard, mouse, trackpad or scroll event.
    func idleSeconds() -> Double
}

struct SystemActivity: ActivityReading {
    /// kCGAnyInputEventType
    private static let anyInput = CGEventType(rawValue: ~0)!

    func idleSeconds() -> Double {
        // Not .hidSystemState: on macOS 27 it reports time since boot for every event type.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInput)
    }
}
