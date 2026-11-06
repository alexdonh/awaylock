import AppKit
import Observation
import SwiftUI

/// Status item + menu. Actions never read `NSApp.currentEvent` (VoiceOver-safe).
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: ProximityModel
    private let settings: AppSettings
    private let controller: ProximityController
    private let updater: UpdaterController
    private let openSettings: () -> Void
    private let openAbout: () -> Void

    private let header = NSMenuItem()
    private let hosting: NSHostingView<MenuHeaderView>
    private let pauseItem = NSMenuItem()
    private let updateItem = NSMenuItem()
    private let badge = NSView()

    init(model: ProximityModel, settings: AppSettings, controller: ProximityController, updater: UpdaterController,
         openSettings: @escaping () -> Void, openAbout: @escaping () -> Void) {
        self.model = model
        self.settings = settings
        self.controller = controller
        self.updater = updater
        self.openSettings = openSettings
        self.openAbout = openAbout
        hosting = NSHostingView(rootView: MenuHeaderView(model: model, settings: settings))
        super.init()
        buildMenu()
        buildBadge()
        Task { [weak self, model, settings, updater] in
            let icons = Observations { IconState(model: model, settings: settings, updateAvailable: updater.availableVersion != nil) }
            for await icon in icons { self?.apply(icon) }
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        hosting.frame.size = NSSize(width: 300, height: hosting.fittingSize.height)
        header.view = hosting
        menu.addItem(header)
        menu.addItem(.separator())

        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        menu.addItem(pauseItem)
        let lock = NSMenuItem(title: String(localized: "Lock Now"), action: #selector(lockNow), keyEquivalent: "q")
        lock.keyEquivalentModifierMask = [.control, .command]
        lock.target = self
        menu.addItem(lock)
        menu.addItem(.separator())

        menu.addItem(item(String(localized: "About"), #selector(showAbout)))
        updateItem.target = self
        updateItem.action = #selector(checkForUpdates)
        menu.addItem(updateItem)
        menu.addItem(item(String(localized: "Settings…"), #selector(showSettings), key: ","))
        menu.addItem(item(String(localized: "Quit"), #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        self.item.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target ?? self
        return i
    }

    private func buildBadge() {
        guard let button = item.button else { return }
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemOrange.cgColor
        badge.layer?.cornerRadius = 3.5
        badge.isHidden = true
        button.addSubview(badge)
    }

    private func apply(_ icon: IconState) {
        guard let button = item.button else { return }
        // Status glyphs from the icon kit (template assets), 18 pt.
        let image = NSImage(resource: icon.symbol)
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = icon.label
        button.image = image
        button.setAccessibilityLabel(icon.label)
        badge.isHidden = !icon.badge
        let b = button.bounds   // laid out by now; top-right corner (button isn't flipped)
        badge.frame = NSRect(x: b.maxX - 9, y: b.maxY - 9, width: 7, height: 7)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem.title = model.pausedUntil == nil ? String(localized: "Pause for 1 Hour") : String(localized: "Resume")
        pauseItem.isEnabled = settings.deviceUUID != nil
        if let version = updater.availableVersion {
            updateItem.title = String(localized: "Update Available: AwayLock \(version)…")
            updateItem.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .regular).applying(.init(paletteColors: [.systemOrange])))
        } else {
            updateItem.title = String(localized: "Check for Updates…")
            updateItem.image = nil
        }
        updateItem.isEnabled = updater.isConfigured
        hosting.frame.size.height = hosting.fittingSize.height
    }

    // MARK: actions

    @objc private func togglePause() {
        model.pausedUntil == nil ? controller.pause() : controller.resume()
    }

    @objc private func lockNow() { controller.lockNow() }
    @objc private func showAbout() { openAbout() }
    @objc private func showSettings() { openSettings() }
    @objc private func checkForUpdates() { updater.checkForUpdates() }
}

private nonisolated struct IconState: Equatable, Sendable {
    var symbol: ImageResource
    var label: String
    var badge: Bool

    @MainActor
    init(model: ProximityModel, settings: AppSettings, updateAvailable: Bool) {
        badge = updateAvailable
        let off = ImageResource.statusOff
        if settings.deviceUUID == nil {
            (symbol, label) = (off, String(localized: "AwayLock: no device chosen"))
        } else if model.pausedUntil != nil {
            (symbol, label) = (off, String(localized: "AwayLock: paused"))
        } else if model.bluetoothOff {
            (symbol, label) = (off, String(localized: "AwayLock: Bluetooth is off"))
        } else {
            switch model.state {
            case .leaving:
                (symbol, label) = (.statusLeaving, String(localized: "AwayLock: device leaving, locking soon"))
            case .locked(byApp: true):
                (symbol, label) = (.statusLocked, String(localized: "AwayLock: locked"))
            case .idle:
                (symbol, label) = (off, String(localized: "AwayLock: off"))
            default:
                (symbol, label) = (.statusNear, String(localized: "AwayLock: device near"))
            }
        }
    }
}

// MARK: - Menu header

struct MenuHeaderView: View {
    let model: ProximityModel
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if settings.deviceUUID == nil {
                row(Icon(name: .antennaOff, size: 20), title: Text("No device chosen"),
                    detail: Text("Choose a device in Settings"), color: .secondary)
            } else if let until = model.pausedUntil {
                row(Image(systemName: "pause").font(.system(size: 17)), title: Text("Paused"),
                    detail: Text("Won't lock until \(until.formatted(date: .omitted, time: .shortened))"), color: .secondary)
            } else if model.bluetoothOff {
                row(Icon(name: .antennaOff, size: 20), title: Text(settings.deviceName),
                    detail: Text("Bluetooth is off"), color: .secondary)
            } else if case .leaving = model.state, let left = model.remaining {
                HStack(spacing: 10) {
                    tile(Icon(name: deviceIcon(for: settings.deviceName), size: 20))
                    titles(Text(settings.deviceName), Text("Away, \(dbm)"), .orange)
                    Spacer()
                    Text("\(left) s").font(.system(size: 20, weight: .semibold)).monospacedDigit().foregroundStyle(.orange)
                }
                // A capsule, not ProgressView: its tint isn't honored everywhere a menu draws.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(.orange)
                            .frame(width: geo.size.width * Double(left) / Double(max(1, settings.awaySeconds)))
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
                Text("Locking in \(left) seconds. Come back to cancel.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    tile(Icon(name: deviceIcon(for: settings.deviceName), size: 20))
                    titles(Text(settings.deviceName), Text(statusLine), statusColor)
                }
                SignalBar(rssi: model.rssi, lockRSSI: settings.lockRSSI)
            }
            if model.lockFailed {
                Label("Couldn't lock. In Lock Screen settings, set Require password to Immediately.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 300, alignment: .leading)
    }

    private var dbm: String { model.rssi.map { "\(Int($0.rounded())) dBm" } ?? String(localized: "no signal") }

    private var statusLine: LocalizedStringKey {
        switch model.state {
        case .near(armed: false): "Not near yet, \(dbm)"
        case .locked(byApp: true): "Locked by AwayLock"
        case .locked(byApp: false): "Locked"
        case .unknown: "Checking…"
        default: "Near, \(dbm)"
        }
    }

    private var statusColor: Color {
        model.state == .near(armed: true) ? .green : .secondary
    }

    private func row(_ icon: some View, title: Text, detail: Text, color: Color) -> some View {
        HStack(spacing: 10) {
            tile(icon)
            titles(title, detail, color)
        }
    }

    private func tile(_ icon: some View) -> some View {
        icon
            .frame(width: 34, height: 34)
            .background(.quaternary, in: .rect(cornerRadius: 10))
            .accessibilityHidden(true)
    }

    /// Takes Text so callers choose: a literal is localized, a device name is shown as is.
    private func titles(_ title: Text, _ detail: Text, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            title.font(.system(size: 13, weight: .semibold))
            detail.font(.system(size: 12, weight: .medium)).foregroundStyle(color)
        }
    }
}

/// Live signal with the lock threshold marked.
struct SignalBar: View {
    let rssi: Double?
    let lockRSSI: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.green).frame(width: geo.size.width * signalFraction(rssi ?? -100))
            }
            // Overlay, not a ZStack child: a 10 pt child would stretch the 4 pt bar to 10 pt.
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(.secondary).frame(width: 2, height: 10)
                    .offset(x: geo.size.width * signalFraction(lockRSSI) - 1)
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Signal \(rssi.map { "\(Int($0)) dBm" } ?? String(localized: "unknown")), locks below \(Int(lockRSSI)) dBm")
    }
}
