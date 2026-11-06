import SwiftUI

struct AboutView: View {
    let updater: UpdaterController
    static let releaseNotesURL = URL(string: "https://github.com/alexdonh/awaylock/releases")!

    var body: some View {
        VStack(spacing: 0) {
            AppIconView()
            Text("AwayLock")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 16)
            Text("Version \(updater.version)")
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text("Your Mac locks itself when you walk away, and stays unlocked while you’re close.")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            Card(dividerInset: 62) {
                feature("device.watch", "One key", "Your Apple Watch, iPhone or a Bluetooth band.")
                feature("lock", "Walk away, it locks", "After a few seconds out of range, or the moment the signal is lost.")
                feature("display", "Stay close, stay unlocked", "No idle lock or sleep while your key is nearby.")
                feature("shield.check", "Private by design", "Everything stays on this Mac. The only network call is a daily update check.")
            }
            .padding(.top, 22)

            HStack(spacing: 10) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!updater.isConfigured)
                Link("Release Notes", destination: Self.releaseNotesURL)
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .padding(.top, 20)

            Text("© 2026 · Open source on GitHub")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 22)
        .frame(width: 460)
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            Icon(name: symbol, size: 18)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(Color.accentSoft, in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

/// Stand-in for the app icon (the asset catalog's AppIcon is still empty).
// ponytail: drawn in SwiftUI; swap for NSApp.applicationIconImage once a real icon ships.
private struct AppIconView: View {
    var body: some View {
        ZStack {
            ForEach([(150.0, 0.12), (110, 0.18), (72, 0.26)], id: \.0) { size, alpha in
                Circle().stroke(.white.opacity(alpha), lineWidth: 1.5).frame(width: size, height: size)
            }
            Icon(name: "lock.open", size: 40)
                .foregroundStyle(.white)
        }
        .frame(width: 96, height: 96)
        .background(Color(red: 0x12 / 255, green: 0x3F / 255, blue: 0x73 / 255))
        .clipShape(.rect(cornerRadius: 26))
        .shadow(color: Color(red: 10 / 255, green: 30 / 255, blue: 60 / 255).opacity(0.35), radius: 12, y: 10)
        .accessibilityLabel("AwayLock app icon")
    }
}
