import CoreGraphics
import Foundation

protocol ScreenLocking {
    var isLocked: Bool { get }
    /// Locks, then reports what the system says afterwards (not just "no error").
    func lock() async -> Bool
}

struct SystemScreenLock: ScreenLocking {
    private typealias SACLock = @convention(c) () -> Int32

    /// Private, same call BLEUnlock uses. Loaded once; nil if Apple removes it.
    private nonisolated static let sacLock: SACLock? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let sym = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(sym, to: SACLock.self)
    }()

    var isLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    func lock() async -> Bool {
        if let sac = Self.sacLock { _ = sac() }
        if await lockedSoon() { return true }
        // Fallback: display sleep locks only with "Require password immediately" on.
        Log.session.error("SACLockScreenImmediate did not lock; sleeping the display")
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["displaysleepnow"]
        try? pmset.run()
        let ok = await lockedSoon()
        if !ok { Log.session.error("display sleep did not lock: is 'Require password immediately' on?") }
        return ok
    }

    private func lockedSoon() async -> Bool {
        for _ in 0..<10 {
            if isLocked { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return isLocked
    }
}
