import LocalAuthentication
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let model: ProximityModel
    let controller: ProximityController
    @Bindable var updater: UpdaterController

    @State private var showPicker = false
    @State private var askPassword = false
    @State private var loginStatus = SMAppService.mainApp.status
    /// Not observable, so re-read on appear and whenever the user comes back from System Settings.
    @State private var axTrusted = UnlockService.isTrusted

    var body: some View {
        Form {
            deviceCard
            lockSection
            nearbySection
            generalSection
            updatesSection
        }
        .formStyle(.grouped)
        // An always-visible scroller sits over the form's right margin; widen that margin by its width to stay centered.
        .contentMargins(.trailing, NSScroller.preferredScrollerStyle == .legacy
                        ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0, for: .scrollContent)
        .frame(width: 680)
        .frame(minHeight: 640, idealHeight: 900)
        .sheet(isPresented: $showPicker) {
            DevicePickerView(settings: settings) { controller.choose($0) }
        }
        .sheet(isPresented: $askPassword) {
            PasswordSheet { password in
                guard UnlockService.savePassword(password) else { return }
                UnlockService.requestTrust()
                settings.autoUnlock = true
            }
        }
        .alert("This device can't be tracked",
               isPresented: Binding(get: { model.untrackableName != nil }, set: { if !$0 { model.untrackableName = nil } })) {
            Button("OK") {}
        } message: {
            Text("\(model.untrackableName ?? "") stopped broadcasting or changed its Bluetooth address. Your previous device is still in use.")
        }
    }

    // MARK: device

    private var deviceCard: some View {
        Section {
            HStack(spacing: 16) {
                Icon(name: settings.deviceUUID == nil ? .antennaOff : deviceIcon(for: settings.deviceName), size: 28)
                    .foregroundStyle(.tint)
                    .frame(width: 56, height: 56)
                    .background(.tint.opacity(0.12), in: .rect(cornerRadius: 16))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    (settings.deviceUUID == nil ? Text("No device chosen") : Text(settings.deviceName))
                        .font(.system(size: 17, weight: .semibold))
                    HStack(spacing: 8) {
                        Circle().fill(statusColor).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(statusText).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(settings.deviceUUID == nil ? LocalizedStringKey("Choose…") : LocalizedStringKey("Change…")) {
                    // First pick has nothing to protect; swapping the key needs the owner (Touch ID or password).
                    guard settings.deviceUUID != nil else { showPicker = true; return }
                    // The system prompt hands focus back to the previous app, burying this window; restore it.
                    let window = NSApp.keyWindow
                    Task {
                        let reason = String(localized: "change the device that locks your Mac")
                        let ok = (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
                        window?.bringToFront()
                        if ok { showPicker = true }
                    }
                }
                    .controlSize(.large)
            }
            .padding(.vertical, 6)
        }
    }

    // LocalizedStringKey, not String: a String handed to Text is shown verbatim, untranslated.
    private var statusText: LocalizedStringKey {
        guard settings.deviceUUID != nil else { return "Choose the device you carry" }
        if model.pausedUntil != nil { return "Paused" }
        if model.bluetoothOff { return "Bluetooth is off" }
        let dbm = model.rssi.map { "\(Int($0.rounded())) dBm" } ?? String(localized: "no signal")
        return switch model.state {
        case .near(armed: true): "Near, \(dbm)"
        case .near(armed: false): "Not near yet, \(dbm)"
        case .leaving: "Away, locking in \(model.remaining ?? 0) s"
        case .locked: "Locked"
        case .unknown: "Checking…"
        case .idle: "Off"
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .near(armed: true): .green
        case .leaving: .orange
        default: .secondary
        }
    }

    // MARK: lock

    private var lockSection: some View {
        Section("Lock") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Lock when farther than") {
                    Text("\(Int(settings.lockRSSI)) dBm").monospacedDigit().foregroundStyle(.tint).fontWeight(.semibold)
                }
                ThresholdSlider(lockRSSI: $settings.lockRSSI, current: model.rssi)
                HStack {
                    Text("Far (-95)")
                    Spacer()
                    Text("Near again above \(Int(settings.lockRSSI + ProximitySettings.hysteresis)) dBm")
                    Spacer()
                    Text("Near (-50)")
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button {
                        if let now = model.rssi { settings.lockRSSI = Self.lockLevel(from: now) }
                    } label: {
                        Label("Use current signal", systemImage: "location")
                    }
                    .disabled(model.rssi == nil)
                    .help("Sets the lock level \(Int(Self.calibrationMargin)) dB below your device's current signal")
                }
            }
            LabeledContent("Lock after away for") {
                FitSegments(choices: AppSettings.awayChoices, selection: $settings.awaySeconds) {
                    $0 == 0 ? String(localized: "Immediately") : String(localized: "\($0) s")
                }
                .fixedSize()
                .accessibilityLabel(Text("Lock after away for"))
            }
            Toggle(isOn: $settings.lockOnSignalLost) {
                Text("Lock when signal is lost")
                Text("Treat Bluetooth off or no signal as away")
            }
        }
    }

    static let languageSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!

    // ponytail: fixed 15 dB margin below "here"; make it a setting if users calibrate from across the room.
    static let calibrationMargin = 15.0
    static func lockLevel(from current: Double) -> Double {
        min(AppSettings.rssiRange.upperBound, max(AppSettings.rssiRange.lowerBound, (current - calibrationMargin).rounded()))
    }

    // MARK: while nearby

    private var nearbySection: some View {
        Section {
            Toggle(isOn: $settings.keepAwakeWhileNear) {
                Text("Keep Mac awake")
                Text("Keeps the display on while your device is near")
            }
            Toggle(isOn: Binding(get: { settings.autoUnlock }, set: setAutoUnlock)) {
                Text("Unlock when I come back")
                Text("Enters your login password after your device is back in range for 3 seconds. Requires Accessibility access.")
            }
            if settings.autoUnlock, !axTrusted {
                Button("Open Accessibility Settings…") { UnlockService.requestTrust() }
            }
        } header: {
            Text("While nearby")
                .onAppear { axTrusted = UnlockService.isTrusted }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    axTrusted = UnlockService.isTrusted
                }
        } footer: {
            Label("Off by default. Someone could relay your device's Bluetooth signal to make it seem near.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setAutoUnlock(_ on: Bool) {
        if on {
            askPassword = true
        } else {
            UnlockService.deletePassword()
            settings.autoUnlock = false
        }
    }

    // MARK: general

    private var generalSection: some View {
        Section("General") {
            Toggle("Start at login", isOn: Binding(get: { settings.isAutoStart }, set: { on in
                settings.isAutoStart = on
                loginStatus = LoginItem.apply(on)
            }))
            if loginStatus == .requiresApproval {
                LabeledContent("Login item needs your approval") {
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                .foregroundStyle(.orange)
            }
            Picker("Signal mode", selection: $settings.signalMode) {
                Text("Auto").tag(SignalMode.auto)
                Text("Connected").tag(SignalMode.connected)
                Text("Passive").tag(SignalMode.passive)
            }
            // macOS already has a per-app language setting; link to it instead of duplicating it.
            LabeledContent {
                Button("Language & Region…") { NSWorkspace.shared.open(Self.languageSettingsURL) }
            } label: {
                Text("Language")
                Text("Choose AwayLock's language under Applications")
            }
        }
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    // MARK: updates

    private var updatesSection: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                .disabled(!updater.isConfigured)
            Toggle(isOn: $updater.automaticallyDownloads) {
                Text("Automatically download and install")
                Text("Only installs while your device is near")
            }
            .disabled(!updater.isConfigured || !updater.automaticallyChecks)
            LabeledContent {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.isConfigured)
            } label: {
                Text("AwayLock \(updater.version)")
                Text(lastCheckedText)
            }
        }
    }

    private var lastCheckedText: LocalizedStringKey {
        guard updater.isConfigured else { return "Updates aren't set up in this build" }
        guard let date = updater.lastChecked else { return "Never checked" }
        let when = date.formatted(.relative(presentation: .named))
        if let version = updater.availableVersion { return "Last checked \(when). Version \(version) is available." }
        return "Last checked \(when). You're up to date."
    }
}

/// Full-width slider for the lock level: a tick at the "back" level and a live
/// "Now" needle for the device's current signal, both crossing the track.
struct ThresholdSlider: View {
    @Binding var lockRSSI: Double
    let current: Double?

    /// Native knob half-width: the track's ends sit this far in from the edges.
    private let inset = 10.0
    private let trackY = 29.0

    var body: some View {
        GeometryReader { geo in
            let x = { (rssi: Double) in inset + (geo.size.width - 2 * inset) * signalFraction(rssi) }
            ZStack(alignment: .topLeading) {
                // No `step`: it draws a tick per dBm. Round in the binding instead.
                Slider(value: Binding(get: { lockRSSI }, set: { lockRSSI = $0.rounded() }), in: AppSettings.rssiRange)
                    .labelsHidden()
                    .frame(width: geo.size.width)
                    .position(x: geo.size.width / 2, y: trackY)
                    .accessibilityLabel("Lock threshold")
                    .accessibilityValue("\(Int(lockRSSI)) dBm")
                Group {
                    Capsule().fill(.secondary).frame(width: 2, height: 12)
                        .position(x: x(lockRSSI + ProximitySettings.hysteresis), y: trackY)
                    if let current {
                        Text("Now").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                            .position(x: x(current), y: 10)
                        Capsule().fill(.green).frame(width: 3, height: 18)
                            .position(x: x(current), y: trackY)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(height: 46)
    }
}

/// Asks for the login password once; it goes straight to the Keychain.
struct PasswordSheet: View {
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unlock when I come back").font(.headline)
            Text("AwayLock enters your login password on the lock screen after your device has been back in range for 3 seconds. The password is stored in the Keychain on this Mac only. Someone could relay your device's Bluetooth signal to make it seem near. Don't turn this on for shared Macs or Macs with sensitive data.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Login password", text: $password)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        guard !password.isEmpty else { return }
        onSave(password)
        dismiss()
    }
}

/// Segmented control sized per label. SwiftUI's segmented Picker forces equal widths.
private struct FitSegments: NSViewRepresentable {
    let choices: [Int]
    @Binding var selection: Int
    let label: (Int) -> String

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: choices.map(label), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fit
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = choices.firstIndex(of: selection) ?? -1
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: FitSegments
        init(_ parent: FitSegments) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) { parent.selection = parent.choices[sender.selectedSegment] }
    }
}
