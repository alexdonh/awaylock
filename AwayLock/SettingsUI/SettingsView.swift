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
    @State private var calibrating = false
    /// After applying a suggestion: what was applied, and the change that reverts it.
    @State private var undo: (applied: Suggestions.Change, revert: Suggestions.Change)?
    @State private var loginStatus = SMAppService.mainApp.status
    /// Not observable, so re-read on appear and whenever the user comes back from System Settings.
    @State private var axTrusted = UnlockService.isTrusted

    var body: some View {
        Form {
            suggestionSection
            deviceCard
            lockSection
            unlockSection
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
                settings.unlockMode = .password
            }
        }
        .sheet(isPresented: $calibrating) {
            CalibrationSheet(controller: controller) { settings.lockRSSI = $0 }
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
        case .held: "Away, not locking while you're using this Mac"
        case .locked: "Locked"
        case .unknown: "Checking…"
        case .idle: "Off"
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .near(armed: true): .green
        case .leaving, .held: .orange
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
                        calibrating = true
                    } label: {
                        Label { Text("Calibrate…") } icon: { Icon(name: .scope, size: 14) }
                    }
                    .disabled(settings.deviceUUID == nil || model.pausedUntil != nil)
                    .help("Measures your device's signal where you sit, and optionally where AwayLock should lock")
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
                Text("Treat Bluetooth off or no signal as away. A signal that vanishes suddenly gets 15 s longer, in case it's a Bluetooth hiccup.")
            }
            Toggle(isOn: $settings.activityGuard) {
                Label {
                    Text("Don't lock while I'm using this Mac")
                    Text("Locks as soon as you stop typing or using the mouse for 5 seconds.")
                } icon: {
                    Icon(name: .keyboard, size: 16).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: suggestion

    @ViewBuilder private var suggestionSection: some View {
        if let undo {
            Section {
                HStack(spacing: 10) {
                    Icon(name: .lightbulb, size: 18).foregroundStyle(.green).accessibilityHidden(true)
                    Text(changeText(undo.applied, done: true)).font(.callout)
                    Spacer()
                    Button("Undo") {
                        controller.apply(undo.revert)
                        self.undo = nil
                    }
                    Button("Done") { self.undo = nil }
                }
            }
        } else if let suggestion = model.suggestion {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Icon(name: .lightbulb, size: 18).foregroundStyle(.orange).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AwayLock locked \(suggestion.falseLocks) times this week while you were at your desk")
                            .font(.callout.weight(.semibold))
                        Text(changeText(suggestion.change, done: false)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Not Now") { controller.dismissSuggestion() }
                    Button("Apply") {
                        if let revert = controller.applySuggestion() { undo = (suggestion.change, revert) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func changeText(_ change: Suggestions.Change, done: Bool) -> LocalizedStringKey {
        switch (change, done) {
        case (.lockRSSI(let level), false): "Try locking when farther than \(Int(level)) dBm."
        case (.lockRSSI(let level), true): "Lock level set to \(Int(level)) dBm."
        case (.awaySeconds(let n), false): "Try a \(n) s away delay."
        case (.awaySeconds(let n), true): "Away delay set to \(n) s."
        }
    }

    static let languageSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!

    // MARK: while nearby

    private var nearbySection: some View {
        Section("While nearby") {
            Toggle(isOn: $settings.keepAwakeWhileNear) {
                Text("Keep Mac awake")
                Text("Keeps the display on while your device is near")
            }
        }
    }

    // MARK: when I come back

    private var unlockSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                unlockCard(.off, icon: .shieldCheck, title: "Off", detail: "You unlock yourself")
                unlockCard(.wake, icon: .displayWake, title: "Wake the screen",
                           detail: "Your Apple Watch unlocks, if it's set to unlock this Mac", badge: "Safer with Apple Watch")
                unlockCard(.password, icon: .key, title: "Type my password",
                           detail: "Enters your login password after 3 seconds back in range")
            }
            .fixedSize(horizontal: false, vertical: true)   // cards share the tallest card's height
            if settings.unlockMode != .off {
                LabeledContent {
                    FitSegments(choices: AppSettings.unlockWindowChoices, selection: $settings.unlockWindowMinutes) {
                        $0 < 60 ? String(localized: "\($0) min") : String(localized: "\($0 / 60) hours")
                    }
                    .fixedSize()
                    .accessibilityLabel(Text("Only within"))
                } label: {
                    Text("Only within")
                    Text("After that, unlock yourself. One try per lock.")
                }
            }
            if settings.unlockMode == .password {
                LabeledContent {
                    Button("Change…") { askPassword = true }
                } label: {
                    Label { Text("Login password"); Text("Saved in the Keychain on this Mac") } icon: { Icon(name: .key, size: 16) }
                }
                LabeledContent {
                    if axTrusted {
                        Text("Allowed").foregroundStyle(.secondary)
                    } else {
                        Button("Open Accessibility Settings…") { UnlockService.requestTrust() }
                    }
                } label: {
                    Label { Text("Accessibility"); Text("Needed to type on the lock screen") } icon: { Icon(name: .shieldCheck, size: 16) }
                }
            }
        } header: {
            Text("When I come back")
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

    private func unlockCard(_ mode: UnlockMode, icon: ImageResource, title: LocalizedStringKey, detail: LocalizedStringKey,
                            badge: LocalizedStringKey? = nil) -> some View {
        let selected = settings.unlockMode == mode
        return Button { setUnlockMode(mode) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Icon(name: icon, size: 20).foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Spacer()
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let badge {
                    Text(badge).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(.green)
                        .background(.green.opacity(0.15), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            .background(selected ? Color.accentColor.opacity(0.08) : .clear, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The password sheet sets `password` once it has a verified password; leaving `password` deletes it.
    private func setUnlockMode(_ mode: UnlockMode) {
        if mode == .password {
            if settings.unlockMode != .password { askPassword = true }
            return
        }
        if settings.unlockMode == .password { UnlockService.deletePassword() }
        settings.unlockMode = mode
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
    @State private var wrong = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unlock when I come back").font(.headline)
            Text("AwayLock enters your login password on the lock screen after your device has been back in range for 3 seconds. The password is stored in the Keychain on this Mac only. Someone could relay your device's Bluetooth signal to make it seem near. Don't turn this on for shared Macs or Macs with sensitive data.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Login password", text: $password)
                .onSubmit(save)
                .onChange(of: password) { wrong = false }
            if wrong {
                Text("That isn't your login password.")
                    .font(.callout).foregroundStyle(.red)
            }
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
        guard UnlockService.verifyPassword(password) else { wrong = true; return }
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
