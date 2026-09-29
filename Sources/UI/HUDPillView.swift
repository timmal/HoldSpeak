import SwiftUI

@MainActor
final class HUDAmplitudeModel: ObservableObject {
    enum Phase: Equatable { case listening, processing, done }

    static let barCount = 7

    /// Bar heights, 0...1, including the idle "breathing" floor.
    @Published private(set) var bars: [CGFloat] = Array(repeating: 0, count: barCount)
    /// Overall smoothed speech level, 0...1 — drives the pill's slight width swell.
    @Published private(set) var level: CGFloat = 0
    @Published private(set) var phase: Phase = .listening

    static let shared = HUDAmplitudeModel()

    /// Centre bars reach higher than the edges, so speech reads as a soft hump.
    private static let weights: [Double] = [0.5, 0.72, 0.9, 1.0, 0.88, 0.7, 0.52]
    /// Per-bar inertia spread: attack 50–80 ms, release 180–250 ms.
    private static let inertia: [Double] = [0.3, 0.8, 0.1, 0.5, 0.9, 0.2, 0.6]

    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var clock: Double = 0
    /// EMA of the normalised mic level; the per-bar envelopes follow this.
    private var smoothed: Double = 0
    private var overall = LevelEnvelope(attack: 0.08, release: 0.3)
    private var envelopes: [LevelEnvelope] = inertia.map {
        LevelEnvelope(attack: 0.05 + 0.03 * $0, release: 0.18 + 0.07 * $0)
    }

    private init() {}

    /// Runs the 60 Hz animation timer; only needed while the HUD is listening.
    /// Starts from flat bars, as if the model had decayed while hidden.
    func start() {
        phase = .listening
        guard timer == nil else { return }
        smoothed = 0
        clock = 0
        overall.reset()
        for i in envelopes.indices { envelopes[i].reset() }
        lastTick = CACurrentMediaTime()
        tick(dt: 0)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.tick(dt: min(now - self.lastTick, 0.1))
                self.lastTick = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setPhase(_ phase: Phase) {
        if phase != .listening { stop() }
        self.phase = phase
    }

    func push(_ amp: Float) {
        smoothed += (LevelEnvelope.normalize(rms: amp) - smoothed) * 0.35
    }

    private func tick(dt: Double) {
        clock += dt
        level = CGFloat(overall.step(toward: smoothed, dt: dt))
        bars = (0..<Self.barCount).map { i in
            let offset = Double(i) * 0.9
            // Slow independent wobble so loud speech isn't a frozen hump.
            let wobble = 0.8 + 0.2 * sin(clock * (5 + Double(i) * 0.7) + offset)
            let speech = envelopes[i].step(toward: smoothed * Self.weights[i] * wobble, dt: dt)
            // Silence: a slow ~2.6 s breath travelling across the bars.
            let breath = 0.14 + 0.07 * (0.5 + 0.5 * sin(clock * 2 * .pi / 2.6 - offset * 0.5))
            return CGFloat(breath + (1 - breath) * speech)
        }
    }
}

struct HUDPillView: View {
    @ObservedObject private var model = HUDAmplitudeModel.shared

    private let text = PTT.textPrimary(.dark)
    private let muted = PTT.textMuted(.dark)

    var body: some View {
        HStack(spacing: 8) {
            indicator
                .frame(width: 12, height: 12)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(model.phase == .listening ? text : muted)
                .fixedSize()
            if model.phase == .listening {
                bars
                    .transition(.scale(scale: 0.1, anchor: .leading).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12 + (model.phase == .listening ? model.level * 2 : 0))
        .frame(height: 30)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.9))
                .overlay(Capsule().stroke(PTT.surfaceBorder(.dark), lineWidth: 1))
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: model.phase)
    }

    private var label: String {
        switch model.phase {
        case .listening: return "Listening"
        case .processing: return "Transcribing"
        case .done: return "Done"
        }
    }

    @ViewBuilder private var indicator: some View {
        switch model.phase {
        case .listening:
            Circle()
                .fill(PTT.recordingRed)
                .frame(width: 7, height: 7)
                .background(
                    Circle()
                        .fill(PTT.recordingRed.opacity(0.25))
                        .scaleEffect(1.3 + model.level * 0.6)
                )
                .transition(.opacity)
        case .processing:
            Spinner(color: muted)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(PTT.statusGreen)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }

    private var bars: some View {
        HStack(spacing: 3) {
            ForEach(0..<model.bars.count, id: \.self) { i in
                Capsule()
                    .fill(text.opacity(0.55 + 0.45 * Double(model.bars[i])))
                    .frame(width: 3, height: 3 + model.bars[i] * 13)
            }
        }
        .frame(height: 16)
    }
}

/// Thin rotating arc; driven by the display clock, so it needs no state.
private struct Spinner: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
        }
        .frame(width: 11, height: 11)
    }
}
