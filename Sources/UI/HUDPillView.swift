import SwiftUI

@MainActor
final class HUDAmplitudeModel: ObservableObject {
    @Published var bars: [Float] = Array(repeating: 0, count: 24)
    static let shared = HUDAmplitudeModel()
    private var timer: Timer?
    private var target: Float = 0
    private var displayed: Float = 0
    private init() {}

    /// Runs the 30 Hz smoothing timer; only needed while the HUD is on screen.
    /// Starts from flat bars, as if the model had decayed while hidden.
    func start() {
        guard timer == nil else { return }
        target = 0
        displayed = 0
        bars = Array(repeating: 0, count: bars.count)
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let alpha: Float = self.target > self.displayed ? 0.5 : 0.15
                self.displayed += (self.target - self.displayed) * alpha
                self.bars.removeFirst()
                self.bars.append(self.displayed)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func push(_ amp: Float) {
        let db = 20 * log10(max(amp, 1e-6))
        let norm = (db + 55) / 32
        target = min(1, max(0, norm))
    }
}

struct HUDPillView: View {
    @ObservedObject private var model = HUDAmplitudeModel.shared

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(0.85)
                .overlay(Circle().stroke(.red.opacity(0.25), lineWidth: 4))
            HStack(spacing: 2) {
                ForEach(0..<model.bars.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .frame(width: 3, height: CGFloat(max(2, model.bars[i] * 18)))
                        .foregroundColor(.white)
                }
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(height: 30)
        .modifier(HUDChrome())
    }
}

/// Shown in place of the recording pill when a dictation failed, so the reason
/// is visible where the user is looking.
struct HUDMessageView: View {
    let title: String
    let detail: String
    var symbol = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.75))
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        // Report the full text width so the panel grows to fit instead of truncating.
        .fixedSize()
        .modifier(HUDChrome())
    }
}

/// Dark capsule behind the HUD content: smoked Liquid Glass on macOS 26+, solid
/// black elsewhere. The glass is darkened so white bars and text stay readable over
/// light windows; the margin leaves room for the glass shadow inside the panel.
struct HUDChrome: ViewModifier {
    static let margin: CGFloat = 10

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26, *) {
                // A tint alone barely darkens the glass over bright windows.
                content
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .glassEffect(.regular, in: Capsule())
            } else {
                content.background(Capsule().fill(Color.black))
            }
        }
        .padding(Self.margin)
    }
}
