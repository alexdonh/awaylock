import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
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

    /// General and History as toolbar tabs.
    private func showSettings() {
        show("settings", title: String(localized: "AwayLock")) {
            Self.settingsTabs([
                (String(localized: "General"), .settingsGeneral, Self.fixed(
                    SettingsView(settings: settings, model: controller.model, controller: controller, updater: updater))),
                (String(localized: "History"), .clockHistory, Self.fixed(HistoryView(controller: controller))),
            ])
        }
    }

    static let settingsSize = NSSize(width: 680, height: 760)

    /// A hosting controller that keeps `settingsSize` instead of following SwiftUI's ideal size,
    /// which made the tab controller pick its own (narrower) size and clip the 680 pt form.
    static func fixed(_ view: some View) -> NSViewController {
        let vc = NSHostingController(rootView: view)
        vc.sizingOptions = []
        vc.preferredContentSize = settingsSize
        return vc
    }

    static func settingsTabs(_ items: [(String, ImageResource, NSViewController)]) -> NSTabViewController {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for (label, image, vc) in items {
            let item = NSTabViewItem(viewController: vc)
            item.label = label
            item.image = NSImage(resource: image)
            tabs.addTabViewItem(item)
        }
        tabs.view.setFrameSize(settingsSize)
        tabs.preferredContentSize = settingsSize
        return tabs
    }

    private func showAbout() {
        show("about", title: String(localized: "About AwayLock")) { NSHostingController(rootView: AboutView(updater: updater)) }
    }

    private func show(_ key: String, title: String, content: () -> NSViewController) {
        let window = windows[key] ?? {
            let w = Self.makeWindow(title: title, content: content())
            w.delegate = self
            windows[key] = w
            return w
        }()
        window.bringToFront()
    }

    /// Closed windows are dropped and rebuilt on next open: a hidden window's SwiftUI views would
    /// otherwise keep re-rendering on every signal reading for as long as the app runs.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }

    /// Content sits below the title bar, never under it: under it, SwiftUI's size depended on the
    /// title bar's safe-area inset, which isn't settled until the window becomes key, so the About
    /// window opened 32 pt short and clipped top and bottom.
    static func makeWindow(title: String, content: NSViewController) -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.contentViewController = content
        w.title = title
        w.isReleasedWhenClosed = false
        // Follow the user to the current Space instead of staying on the one it was opened on.
        w.collectionBehavior.insert(.moveToActiveSpace)
        w.layoutIfNeeded()
        w.center()
        return w
    }
}
