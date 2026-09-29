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

    /// Newest level sits in the centre bar and moves outward, one bar per step,
    /// so height reads as loudness and the spread as the rhythm of speech.
    private static let historyStep: Double = 0.08
    /// Per-bar inertia spread: attack 50–80 ms, release 180–250 ms.
    private static let inertia: [Double] = [0.3, 0.8, 0.1, 0.5, 0.9, 0.2, 0.6]

    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var clock: Double = 0
    private var sinceStep: Double = 0
    /// Light EMA of the normalised mic level; smooths buffer-to-buffer jitter.
    private var smoothed: Double = 0
    /// history[0] is the current level, history[k] the level k steps ago.
    private var history = [Double](repeating: 0, count: barCount / 2 + 1)
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
        sinceStep = 0
        history = history.map { _ in 0 }
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
        smoothed += (LevelEnvelope.normalize(rms: amp) - smoothed) * 0.6
    }

    private func tick(dt: Double) {
        clock += dt
        sinceStep += dt
        history[0] = smoothed
        if sinceStep >= Self.historyStep {
            sinceStep = 0
            history = [smoothed] + history.dropLast()
        }
        level = CGFloat(overall.step(toward: smoothed, dt: dt))
        let centre = Self.barCount / 2
        bars = (0..<Self.barCount).map { i in
            let distance = abs(i - centre)
            let speech = envelopes[i].step(toward: history[distance], dt: dt)
            // Silence: a faint ~2.6 s breath; speech takes over from it.
            let breath = 0.06 + 0.05 * (0.5 + 0.5 * sin(clock * 2 * .pi / 2.6 - Double(distance) * 0.6))
            return CGFloat(max(breath, speech))
        }
    }
}

struct HUDPillView: View {
    @ObservedObject private var model = HUDAmplitudeModel.shared

    private let text = PTT.textPrimary(.dark)
    private let muted = PTT.textMuted(.dark)

    var body: some View {
        HStack(spacing: 10) {
            indicator
                .frame(width: 14, height: 14)
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(model.phase == .listening ? text : muted)
                .fixedSize()
            if model.phase == .listening {
                bars
                    .transition(.scale(scale: 0.1, anchor: .leading).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 18 + (model.phase == .listening ? model.level * 2 : 0))
        .frame(height: 43)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.9))
                .overlay(Capsule().stroke(PTT.surfaceBorder(.dark), lineWidth: 1))
                // Two-layer shadow: a tight contact edge plus a wide soft ambient.
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
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
                .frame(width: 8, height: 8)
                .background(Circle().fill(PTT.recordingRed.opacity(0.22)).frame(width: 13, height: 13))
                .transition(.opacity)
        case .processing:
            Spinner(color: muted)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(PTT.statusGreen)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }

    private var bars: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<model.bars.count, id: \.self) { i in
                Capsule()
                    .fill(text.opacity(0.55 + 0.45 * Double(model.bars[i])))
                    .frame(width: 3.5, height: 3 + model.bars[i] * 21)
            }
        }
        .frame(height: 24)
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
        .frame(width: 13, height: 13)
    }
}
