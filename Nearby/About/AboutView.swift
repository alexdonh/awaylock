import SwiftUI

struct AboutView: View {
    let updater: UpdaterController
    static let releaseNotesURL = URL(string: "https://github.com/OWNER/nearby/releases")!

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Nearby").font(.title.weight(.semibold))
                Text("Version \(updater.version)").foregroundStyle(.secondary)
            }
            Text("Your Mac locks itself when you walk away, and stays unlocked while you’re close.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                feature("key", "One key", "Your Apple Watch, iPhone or a Bluetooth band.")
                feature("figure.walk.departure", "Walk away, it locks", "After a few seconds out of range, or the moment the signal is lost.")
                feature("lock.open", "Stay close, stay unlocked", "No idle lock or sleep while your key is nearby.")
                feature("hand.raised", "Private by design", "Everything stays on this Mac. The only network call is a daily update check.")
            }
            HStack {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.isConfigured)
                Link("Release Notes", destination: Self.releaseNotesURL)
            }
            Text("© 2026 · Open source on GitHub").font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 440)
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        GridRow(alignment: .top) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
