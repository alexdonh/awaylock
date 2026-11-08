import SwiftUI

/// One row of the History tab, built from journal records.
nonisolated struct HistoryEntry: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        case lock(LeaveReason?)
        case held(seconds: Int)
        case autoUnlock
        case radio(healthy: Bool)
    }

    enum Chip: Sendable, Equatable {
        case good, probablyWrong, held, autoUnlock, bluetooth
    }

    var id: Int
    var t: Date
    var kind: Kind
    var chip: Chip?
}

nonisolated enum History {
    static let week: TimeInterval = 7 * 24 * 3600

    /// Newest first. Labels fold into their lock's chip; manual unlocks aren't shown.
    static func entries(_ records: [JournalRecord]) -> [HistoryEntry] {
        var verdicts: [Date: LockVerdict] = [:]
        for r in records where r.kind == .label {
            if let lock = r.lock, let v = r.verdict { verdicts[lock] = v }
        }
        var out: [HistoryEntry] = []
        for (i, r) in records.enumerated() {
            switch r.kind {
            case .lock:
                let chip: HistoryEntry.Chip? = switch verdicts[r.t] {
                case .likelyFalse: .probablyWrong
                case .likelyGood: .good
                case .unknown, nil: nil
                }
                out.append(HistoryEntry(id: i, t: r.t, kind: .lock(r.reason), chip: chip))
            case .held:
                out.append(HistoryEntry(id: i, t: r.t, kind: .held(seconds: Int(r.seconds ?? 0)), chip: .held))
            case .unlock where r.by == "app":
                out.append(HistoryEntry(id: i, t: r.t, kind: .autoUnlock, chip: .autoUnlock))
            case .radio:
                out.append(HistoryEntry(id: i, t: r.t, kind: .radio(healthy: r.healthy ?? true), chip: .bluetooth))
            case .unlock, .label:
                break
            }
        }
        return out.sorted { $0.t > $1.t }
    }

    struct Stats: Equatable {
        var locks = 0, probablyWrong = 0, held = 0
    }

    static func stats(_ entries: [HistoryEntry], now: Date = .now) -> Stats {
        var s = Stats()
        for e in entries where now.timeIntervalSince(e.t) <= week {
            if case .lock = e.kind { s.locks += 1 }
            if e.chip == .probablyWrong { s.probablyWrong += 1 }
            if e.chip == .held { s.held += 1 }
        }
        return s
    }
}

/// Settings › History: what AwayLock decided and whether it looked right.
struct HistoryView: View {
    let controller: ProximityController

    private enum Filter: Hashable { case all, locks, probablyWrong }

    @State private var entries: [HistoryEntry] = []
    @State private var filter = Filter.all
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                let stats = History.stats(entries)
                HStack(spacing: 12) {
                    tile("\(stats.locks)", Text("Locks this week"))
                    tile("\(stats.probablyWrong)", Text("Probably wrong"), color: stats.probablyWrong > 0 ? .orange : .primary)
                    tile("\(stats.held)", Text("Held while you worked"))
                }
            }
            Section {
                Picker("Show", selection: $filter) {
                    Text("All").tag(Filter.all)
                    Text("Locks").tag(Filter.locks)
                    Text("Probably wrong").tag(Filter.probablyWrong)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.t) }
            if days.isEmpty {
                Section {
                    Text("Nothing yet. Each lock AwayLock makes shows up here.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                Section(day.formatted(.relative(presentation: .named, unitsStyle: .wide)).capitalized(with: .current)) {
                    ForEach(days[day] ?? []) { row($0) }
                }
            }
            Section {
                LabeledContent {
                    HStack {
                        Button("Show in Finder", action: showInFinder)
                        Button("Clear History…") { confirmClear = true }
                    }
                } label: {
                    Label("Kept on this Mac only. No device names, IDs or passwords.", systemImage: "lock.shield")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 680)
        .frame(minHeight: 640, idealHeight: 760)
        .onAppear { Task { await reload() } }
        .confirmationDialog("Clear lock history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                controller.clearHistory()
                entries = []
            }
        } message: {
            Text("This also resets tuning suggestions.")
        }
    }

    private var shown: [HistoryEntry] {
        switch filter {
        case .all: entries
        case .locks: entries.filter { if case .lock = $0.kind { true } else { false } }
        case .probablyWrong: entries.filter { $0.chip == .probablyWrong }
        }
    }

    private func reload() async {
        entries = History.entries(await controller.journal.records())
    }

    private func showInFinder() {
        let url = controller.journal.url
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(dir)
        }
    }

    private func tile(_ value: String, _ label: Text, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            label.font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func row(_ e: HistoryEntry) -> some View {
        HStack(spacing: 10) {
            Icon(name: icon(e.kind), size: 18).foregroundStyle(.secondary).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                title(e.kind)
                Text(e.t.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let chip = e.chip { chipView(chip) }
        }
        .accessibilityElement(children: .combine)
    }

    private func icon(_ kind: HistoryEntry.Kind) -> ImageResource {
        switch kind {
        case .lock: .lock
        case .held: .keyboard
        case .autoUnlock: .lockOpen
        case .radio(let healthy): healthy ? .antenna : .antennaOff
        }
    }

    private func title(_ kind: HistoryEntry.Kind) -> Text {
        switch kind {
        case .lock(.abrupt): Text("Locked: signal vanished suddenly")
        case .lock(.lost): Text("Locked: signal lost")
        case .lock: Text("Locked: device moved away")
        case .held(let seconds): Text("Didn't lock for \(seconds) s while you were using this Mac")
        case .autoUnlock: Text("Unlocked when you came back")
        case .radio(true): Text("Bluetooth recovered")
        case .radio(false): Text("Bluetooth stopped responding")
        }
    }

    private func chipView(_ chip: HistoryEntry.Chip) -> some View {
        let (text, color): (Text, Color) = switch chip {
        case .good: (Text("Good"), .green)
        case .probablyWrong: (Text("Probably wrong"), .orange)
        case .held: (Text("Held"), .orange)
        case .autoUnlock: (Text("Auto-unlock"), .accentColor)
        case .bluetooth: (Text("Bluetooth"), .secondary)
        }
        return text.font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}
