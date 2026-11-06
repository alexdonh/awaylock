import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var controller = ProximityController(settings: settings)
    private lazy var updater = UpdaterController { [weak self] install in
        self?.controller.whenSafeToRelaunch(install) ?? install()
    }
    private var statusItem: StatusItemController?
    private var windows: [String: NSWindow] = [:]

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests, ensureSingleInstance() else { return }
        LoginItem.apply(settings.isAutoStart)
        controller.start()
        statusItem = StatusItemController(
            model: controller.model, settings: settings, controller: controller, updater: updater,
            openSettings: { [weak self] in self?.showSettings() },
            openAbout: { [weak self] in self?.showAbout() })
        if settings.deviceUUID == nil { showSettings() }
    }

    /// Launching a menu bar app twice looks like a no-op while spawning a duplicate.
    /// Copied from Hidden Bar (hidden/AppDelegate.swift, develop).
    private func ensureSingleInstance() -> Bool {
        let current = ProcessInfo.processInfo.processIdentifier
        let existing = NSWorkspace.shared.runningApplications.first {
            guard $0.bundleIdentifier == Bundle.main.bundleIdentifier,
                  $0.processIdentifier != current else { return false }
            #if DEBUG
            // Let a dev build run next to the installed copy; only dedupe relaunches of the same bundle path.
            return $0.bundleURL == Bundle.main.bundleURL
            #else
            return true
            #endif
        }
        guard let existing else { return true }
        existing.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
        return false
    }

    private func showSettings() {
        show("settings", title: String(localized: "AwayLock")) {
            SettingsView(settings: settings, model: controller.model, controller: controller, updater: updater)
        }
    }

    private func showAbout() {
        show("about", title: String(localized: "About AwayLock")) { AboutView(updater: updater) }
    }

    private func show(_ key: String, title: String, @ViewBuilder content: () -> some View) {
        let window = windows[key] ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: content()))
            w.title = title
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.isReleasedWhenClosed = false
            // Follow the user to the current Space instead of staying on the one it was opened on.
            w.collectionBehavior.insert(.moveToActiveSpace)
            w.center()
            windows[key] = w
            return w
        }()
        // activate() is only a request on macOS 14+ and can be declined while another app is
        // frontmost; orderFrontRegardless() still brings the window above that app's windows.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
