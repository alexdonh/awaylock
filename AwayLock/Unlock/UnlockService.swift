import AppKit
import ApplicationServices
import IOKit.pwr_mgt
import OpenDirectory
import Security

/// Opt-in unlock on return. `wake` mode only wakes the display (an Apple Watch with Mac unlock then
/// unlocks through macOS). `password` mode also types the login password from the Keychain.
/// The machine only asks after a lock *the app* made, a 3 s sustained return and the unlock gates.
final class UnlockService {
    private static let service = Bundle.main.bundleIdentifier ?? "app.awaylock.mac"

    // MARK: password (Keychain only, never UserDefaults)

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: NSUserName()]
    }

    static var hasPassword: Bool { readPassword() != nil }

    /// Checks against this user's login record, so a typo never gets typed on the lock screen.
    /// A wrong try counts toward the account's failed-login limit, like a wrong lock-screen entry.
    static func verifyPassword(_ password: String) -> Bool {
        do {
            let node = try ODNode(session: .default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            Log.session.notice("password check failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    static func savePassword(_ password: String) -> Bool {
        deletePassword()
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func deletePassword() {
        SecItemDelete(query as CFDictionary)
    }

    private static func readPassword() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Accessibility

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: unlock

    /// Reused across calls: passing the previous ID updates that assertion instead of adding one.
    private static var activityID = IOPMAssertionID(0)

    /// Wakes the display as if the user touched the Mac. Needs no permission.
    static func wakeDisplay() {
        IOPMAssertionDeclareUserActivity("AwayLock unlock" as CFString, kIOPMUserActiveLocal, &activityID)
    }

    /// True if the screen reports unlocked within 5 s of typing.
    func unlock(using screen: any ScreenLocking) async -> Bool {
        guard screen.isLocked else { return true }
        guard Self.isTrusted else { Log.session.error("unlock skipped: no Accessibility permission"); return false }
        guard let password = Self.readPassword() else { Log.session.error("unlock skipped: no password in Keychain"); return false }

        Self.wakeDisplay()
        try? await Task.sleep(for: .milliseconds(800))

        // Verified lock screen immediately before typing, so the password never lands in another app.
        guard screen.isLocked else { return true }
        let source = CGEventSource(stateID: .hidSystemState)
        for character in password {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event?.post(tap: .cghidEventTap)
            }
        }
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap) // Return
        }
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(200))
            if !screen.isLocked { return true }
        }
        return false
    }
}
