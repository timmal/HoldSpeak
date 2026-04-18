import SwiftUI

struct HUDTranscriptView: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
            Text(text.isEmpty ? "Listening…" : text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 460, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
        )
    }
}
