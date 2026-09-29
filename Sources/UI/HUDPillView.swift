import SwiftUI

@MainActor
final class HUDAmplitudeModel: ObservableObject {
    enum Phase: Equatable { case listening, processing, done }

    /// One thin bar per sample, ~1.5 s of history at `sampleStep`.
    static let sampleCount = 26
    private static let sampleStep: Double = 0.06

    /// Level history for the waveform, 0...1, oldest first.
    @Published private(set) var samples = [CGFloat](repeating: 0, count: sampleCount)
    /// How far (0...1 of one sample) the waveform has scrolled since the last
    /// sample, so it glides left instead of jumping.
    @Published private(set) var scroll: CGFloat = 0
    /// Overall smoothed speech level, 0...1 — drives the pill's slight width swell.
    @Published private(set) var level: CGFloat = 0
    @Published private(set) var phase: Phase = .listening

    static let shared = HUDAmplitudeModel()

    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var sinceSample: Double = 0
    /// Light EMA of the normalised mic level; smooths buffer-to-buffer jitter.
    private var smoothed: Double = 0
    /// Fast attack, slower release: the waveform swells with a word and eases off.
    private var follower = LevelEnvelope(attack: 0.03, release: 0.12)
    private var overall = LevelEnvelope(attack: 0.08, release: 0.3)

    private init() {}

    /// Runs the 60 Hz animation timer; only needed while the HUD is listening.
    /// Starts from a flat line, as if the model had decayed while hidden.
    func start() {
        phase = .listening
        guard timer == nil else { return }
        smoothed = 0
        sinceSample = 0
        scroll = 0
        follower.reset()
        overall.reset()
        samples = samples.map { _ in 0 }
        lastTick = CACurrentMediaTime()
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
        let value = CGFloat(follower.step(toward: smoothed, dt: dt))
        level = CGFloat(overall.step(toward: smoothed, dt: dt))
        sinceSample += dt
        if sinceSample >= Self.sampleStep {
            sinceSample -= Self.sampleStep
            samples = Array(samples.dropFirst()) + [value]
        } else {
            samples[samples.count - 1] = value
        }
        scroll = CGFloat(sinceSample / Self.sampleStep)
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
                waveform
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

    private var waveform: some View {
        Waveform(samples: model.samples, scroll: model.scroll)
            .fill(text)
            .clipped()
            // Older audio fades out on the left, like a scrolling editor view.
            .mask(LinearGradient(colors: [.clear, .white, .white],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: 90, height: 24)
    }
}

/// Dense mirrored level bars, newest at the right edge, scrolling left.
private struct Waveform: Shape {
    var samples: [CGFloat]
    var scroll: CGFloat

    private let barWidth: CGFloat = 2
    private let gap: CGFloat = 1.5

    func path(in rect: CGRect) -> Path {
        let pitch = barWidth + gap
        let right = rect.maxX - barWidth
        var path = Path()
        for (i, v) in samples.enumerated() {
            let age = CGFloat(samples.count - 1 - i) + scroll
            let x = right - age * pitch
            guard x > rect.minX - barWidth else { continue }
            // A 2 px stub at silence, full height at the top of the level range.
            let h = max(2, v * rect.height)
            path.addRoundedRect(in: CGRect(x: x, y: rect.midY - h / 2, width: barWidth, height: h),
                                cornerSize: CGSize(width: 1, height: 1))
        }
        return path
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
