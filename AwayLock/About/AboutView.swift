import SwiftUI

struct AboutView: View {
    let updater: UpdaterController
    static let repoURL = URL(string: "https://github.com/alexdonh/awaylock")!
    static let releaseNotesURL = repoURL.appending(path: "releases")

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
            Text("Locks your Mac when you walk away and keeps it unlocked while you're nearby.")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            Card(dividerInset: 62) {
                feature(.deviceWatch, "Uses a device you carry", "Apple Watch, iPhone, or a Bluetooth band.")
                feature(.lock, "Locks when you leave", "After a few seconds out of range, or as soon as the signal is lost.")
                feature(.display, "Stays awake while you're near", "No idle lock or display sleep while your device is in range.")
                feature(.shieldCheck, "Private", "Your data stays on this Mac. The only network request is a daily update check.")
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

            Link("© 2026 Alex Do. Open source on GitHub.", destination: Self.repoURL)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 22)
        .frame(width: 460)
    }

    private func feature(_ symbol: ImageResource, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
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

private struct AppIconView: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 96, height: 96)
            .accessibilityLabel("AwayLock app icon")
    }
}
