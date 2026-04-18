import SwiftUI

struct HUDPillView: View {
    let amplitude: Float
    @State private var bars: [Float] = Array(repeating: 0, count: 20)
    private let timer = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(0.85)
                .overlay(Circle().stroke(.red.opacity(0.25), lineWidth: 4))
            HStack(spacing: 2) {
                ForEach(0..<bars.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .frame(width: 3, height: CGFloat(max(2, bars[i] * 30)))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
            Text("Recording")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.08)))
        )
        .onReceive(timer) { _ in
            bars.removeFirst()
            bars.append(min(1, amplitude * 6))
        }
    }
}
