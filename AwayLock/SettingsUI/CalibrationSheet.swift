import SwiftUI

/// Two-step lock level: 30 s where you sit, then (skippable) 10 s to walk away and 20 s where
/// it should lock. Locking stays off while the sheet is open.
struct CalibrationSheet: View {
    let controller: ProximityController
    let onApply: (Double) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case nearIntro, near(Date), farIntro, far(Date), done(Double, warning: Bool), failed
    }

    @State private var step = Step.nearIntro
    @State private var near: [Double] = []
    @State private var far: [Double] = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Icon(name: .scope, size: 18).foregroundStyle(.tint).accessibilityHidden(true)
                Text("Calibrate").font(.headline)
            }
            content
                .frame(maxWidth: .infinity, minHeight: 150)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { task?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                actions
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { controller.beginCalibration() }
        .onDisappear {
            task?.cancel()
            controller.endCalibration()
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .nearIntro:
            prompt(Text("Step 1 of 2 · Sit normally"),
                   Text("Sit the way you normally work. Keep your device where it usually is."))
        case .near(let start):
            VStack(spacing: 10) {
                CountdownRing(start: start, seconds: Calibration.nearSeconds)
                Text("Measuring where you sit…").foregroundStyle(.secondary)
            }
        case .farIntro:
            prompt(Text("Step 2 of 2 · Walk away (optional)"),
                   Text("Press Start, then walk to where AwayLock should lock and wait there. You have 10 seconds to get there, then it measures for 20. AwayLock won't lock meanwhile."))
        case .far(let start):
            VStack(spacing: 10) {
                CountdownRing(start: start, seconds: Calibration.walkSeconds + Calibration.farSeconds)
                TimelineView(.periodic(from: start, by: 1)) { context in
                    context.date.timeIntervalSince(start) < Double(Calibration.walkSeconds)
                        ? Text("Walk there now…").foregroundStyle(.secondary)
                        : Text("Measuring where it should lock…").foregroundStyle(.secondary)
                }
            }
        case .done(let level, let warning):
            VStack(alignment: .leading, spacing: 12) {
                Text("Lock when farther than \(Int(level)) dBm").font(.title3.weight(.semibold)).monospacedDigit()
                CalibrationBands(near: near, far: far, lockRSSI: level)
                if warning {
                    Label("Near and far look alike here. Try a longer away delay, or use an Apple Watch.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .failed:
            prompt(Text("No signal"), Text("No signal from your device. Check that it's nearby and try again."))
        }
    }

    private func prompt(_ title: Text, _ detail: Text) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title.font(.callout.weight(.semibold))
            detail.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var actions: some View {
        switch step {
        case .nearIntro, .failed:
            Button("Start") { measure(near: true) }.keyboardShortcut(.defaultAction)
        case .farIntro:
            Button("Skip") { finish() }
            Button("Start") { measure(near: false) }.keyboardShortcut(.defaultAction)
        case .done(let level, _):
            Button("Apply") { onApply(level); dismiss() }.keyboardShortcut(.defaultAction)
        case .near, .far:
            EmptyView()
        }
    }

    private func measure(near isNear: Bool) {
        let seconds = isNear ? Calibration.nearSeconds : Calibration.farSeconds
        let skip = isNear ? 0 : Calibration.walkSeconds
        step = isNear ? .near(.now) : .far(.now)
        task = Task {
            let readings = await controller.collectReadings(for: .seconds(seconds), skip: .seconds(skip))
            guard !Task.isCancelled else { return }
            if isNear {
                near = readings
                far = []
                step = readings.isEmpty ? .failed : .farIntro
            } else {
                far = readings
                finish()
            }
        }
    }

    private func finish() {
        guard let r = Calibration.result(near: near, far: far) else { step = .failed; return }
        step = .done(r.lockRSSI, warning: r.warning)
    }
}

/// Progress ring with the seconds left in the middle.
private struct CountdownRing: View {
    let start: Date
    let seconds: Int

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            let progress = min(1, elapsed / Double(seconds))
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 6)
                Circle().trim(from: 0, to: progress)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(max(0, seconds - Int(elapsed))) s")
                    .font(.system(size: 20, weight: .semibold)).monospacedDigit()
            }
        }
        .frame(width: 96, height: 96)
        .accessibilityLabel(Text("Measuring"))
    }
}

/// Near and far signal bands on the slider's scale, with the chosen lock line.
private struct CalibrationBands: View {
    let near: [Double]
    let far: [Double]
    let lockRSSI: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let x = { (rssi: Double) in geo.size.width * signalFraction(rssi) }
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 8)
                    band(Calibration.percentile(near, 10), near.max(), color: .green, x: x)
                    band(far.min(), Calibration.percentile(far, 90), color: .orange, x: x)
                    Capsule().fill(Color.accentColor).frame(width: 3, height: 22).offset(x: x(lockRSSI) - 1.5)
                }
                .frame(height: 22)
            }
            .frame(height: 22)
            HStack(spacing: 12) {
                legend(.green, Text("Where you sit"))
                if !far.isEmpty { legend(.orange, Text("Where it should lock")) }
                legend(.accentColor, Text("Lock level"))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func band(_ lo: Double?, _ hi: Double?, color: Color, x: (Double) -> Double) -> some View {
        if let lo, let hi {
            Capsule().fill(color.opacity(0.6))
                .frame(width: max(6, x(hi) - x(lo)), height: 8)
                .offset(x: x(lo))
        }
    }

    private func legend(_ color: Color, _ label: Text) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            label
        }
    }
}
