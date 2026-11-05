import SwiftUI

/// "Choose your key" sheet. Scans only while open.
struct DevicePickerView: View {
    let settings: AppSettings
    let onChoose: (DiscoveredDevice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var snapshot = ScanSnapshot()
    @State private var selection: UUID?

    private var devices: [DiscoveredDevice] {
        snapshot.devices.filter { !settings.untrackableUUIDs.contains($0.id) }
    }

    private var hiddenCount: Int {
        snapshot.rotating + snapshot.devices.count - devices.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose your key").font(.title2.weight(.semibold))
                Text("Keep this device with you. When it walks away, your Mac locks.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("Nearby devices").font(.headline)
                ProgressView().controlSize(.small)
                Text("Scanning").font(.caption).foregroundStyle(.secondary)
            }
            List(devices) { device in
                DeviceRow(device: device,
                          inUse: device.id == (selection ?? settings.deviceUUID)) { selection = device.id }
            }
            .listStyle(.inset)
            .frame(minHeight: 260)
            .overlay {
                if devices.isEmpty {
                    ContentUnavailableView("Listening…", systemImage: "dot.radiowaves.left.and.right",
                                           description: Text("Devices show up after they’ve been heard for 10 seconds."))
                }
            }
            if hiddenCount > 0 {
                Label("\(hiddenCount) devices hidden because their Bluetooth address keeps changing.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    if let selection, let device = snapshot.devices.first(where: { $0.id == selection }) { onChoose(device) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
        .task {
            let scanner = DeviceScanner()
            for await next in await scanner.scan() { snapshot = next }
        }
    }
}

private struct DeviceRow: View {
    let device: DiscoveredDevice
    let inUse: Bool
    let use: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: deviceSymbol(for: device.name))
                .font(.system(size: 20))
                .frame(width: 40, height: 40)
                .background(.quaternary, in: .rect(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name).font(.system(size: 14, weight: .semibold))
                    if device.isApple, device.name.localizedCaseInsensitiveContains("watch") {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: .capsule)
                            .foregroundStyle(.tint)
                    }
                }
                Text(Self.tag(for: device)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                SignalBar(rssi: device.rssi, lockRSSI: -200).frame(width: 60)
                Text("\(Int(device.rssi.rounded())) dBm").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            if inUse {
                Text("In use").font(.callout.weight(.medium)).foregroundStyle(.secondary).frame(width: 64)
            } else {
                Button("Use", action: use).frame(width: 64)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    static func tag(for d: DiscoveredDevice) -> String {
        let n = d.name.lowercased()
        if d.isApple {
            if n.contains("watch") { return String(localized: "Same iCloud · Best key — always on your wrist") }
            if n.contains("iphone") { return String(localized: "Same iCloud · Weaker in a pocket or bag") }
            if n.contains("airpods") { return String(localized: "Locks whenever the case is closed") }
            return String(localized: "Apple, same iCloud")
        }
        return d.seconds >= 60 ? String(localized: "Stable address · Passive mode")
                               : String(localized: "Unverified · Passive mode")
    }
}
