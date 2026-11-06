import SwiftUI

/// Device picker sheet. Scans only while open.
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

    private static let rowHeight = 62.0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Icon(name: "antenna", size: 32)
                    .foregroundStyle(.tint)
                    .frame(width: 64, height: 64)
                    .background(Color.accentSoft, in: .rect(cornerRadius: 20))
                    .accessibilityHidden(true)
                Text("Choose a device")
                    .font(.system(size: 22, weight: .bold))
                    .padding(.top, 6)
                Text("Pick a device you keep with you. Your Mac locks when it goes out of range.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(.top, 30)
            .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Nearby devices").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(.tint).frame(width: 6, height: 6)
                        Text("Scanning")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)

                ScrollView {
                    Card(dividerInset: 68) {
                        if devices.isEmpty {
                            Text("Looking for devices. A device shows up after it has been detected for 10 seconds.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
                        }
                        ForEach(devices) { device in
                            DeviceRow(device: device,
                                      inUse: device.id == (selection ?? settings.deviceUUID)) { selection = device.id }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                // Grow with the list up to five rows, then scroll.
                .frame(height: Double(min(max(devices.count, 1), 5)) * (Self.rowHeight + 1))

                if hiddenCount > 0 {
                    Text("\(hiddenCount) devices hidden because their Bluetooth address keeps changing.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    if let selection, let device = snapshot.devices.first(where: { $0.id == selection }) { onChoose(device) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .padding(.top, 36)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 600)
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
        HStack(spacing: 12) {
            Icon(name: deviceIcon(for: device.name), size: 22)
                .frame(width: 38, height: 38)
                .background(.primary.opacity(inUse ? 0.12 : 0.08), in: .rect(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.system(size: 13, weight: .semibold))
                Text(Self.tag(for: device))
                    .font(.system(size: 12))
                    .foregroundStyle(Self.isWarning(device) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            SignalBars(rssi: device.rssi)
            Text("\(Int(device.rssi.rounded())) dBm")
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
            if inUse {
                Label("In use", systemImage: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 76, minHeight: 28)
                    .background(.tint, in: .capsule)
            } else {
                Button(action: use) { Text("Use").frame(minWidth: 52) }
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
        .background(inUse ? Color.accentSoft : .clear)
        .accessibilityElement(children: .combine)
    }

    static func isWarning(_ d: DiscoveredDevice) -> Bool {
        d.isApple && d.name.localizedCaseInsensitiveContains("airpods")
    }

    static func tag(for d: DiscoveredDevice) -> String {
        let n = d.name.lowercased()
        if d.isApple {
            if n.contains("watch") { return String(localized: "Same iCloud account, recommended") }
            if n.contains("iphone") { return String(localized: "Same iCloud account, weaker in a pocket or bag") }
            if n.contains("airpods") { return String(localized: "Locks whenever the case is closed") }
            return String(localized: "Same iCloud account")
        }
        return d.seconds >= 60 ? String(localized: "Stable address, passive mode")
                               : String(localized: "Not verified, passive mode")
    }
}

/// Four-bar signal glyph: −50, −65, −75 and −85 dBm light one more bar each.
private struct SignalBars: View {
    let rssi: Double

    var body: some View {
        let lit = [-85.0, -75, -65, -50].filter { rssi >= $0 }.count
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < lit ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.2)))
                    .frame(width: 3, height: 5 + Double(i) * 3)
            }
        }
        .accessibilityHidden(true)
    }
}
