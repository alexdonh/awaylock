import Foundation
import Observation
import Sparkle

/// Sparkle 2 behind a small observable facade. Sparkle owns its own defaults keys
/// (SUEnableAutomaticChecks, SUAutomaticallyUpdate); the toggles here proxy to it.
@Observable
final class UpdaterController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// False while Info.plist still has the placeholder key (dev builds): updater never starts.
    let isConfigured: Bool
    var availableVersion: String?
    var lastChecked: Date?
    var automaticallyChecks = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    var automaticallyDownloads = false {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloads }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let whenSafeToRelaunch: (@escaping () -> Void) -> Void

    init(whenSafeToRelaunch: @escaping (@escaping () -> Void) -> Void) {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = !key.isEmpty && !key.hasPrefix("REPLACE")
        self.whenSafeToRelaunch = whenSafeToRelaunch
        super.init()
        guard isConfigured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloads = controller.updater.automaticallyDownloadsUpdates
        lastChecked = controller.updater.lastUpdateCheckDate
    }

    var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastChecked = updater.lastUpdateCheckDate
    }

    /// Auto-install: wait until the device is near and no countdown runs. Relaunch re-enters
    /// the 5 s unknown window, so it never causes a lock.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock install: @escaping () -> Void) -> Bool {
        whenSafeToRelaunch(install)
        return true
    }

    // MARK: gentle reminders (background app: badge, don't pop windows)

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}
