import SwiftUI

/// API key field for the Gemini engine: checks the key with Google before saving
/// it to the Keychain. Used in onboarding and in Preferences → Audio.
struct GeminiKeyEditor: View {
    @ObservedObject private var prefs = PreferencesStore.shared
    var width: CGFloat = 280

    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""
    @State private var check: Check = .idle

    private enum Check { case idle, checking, invalid, unreachable }

    static let keyPageURL = URL(string: "https://aistudio.google.com/apikey")!

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField(prefs.hasGeminiKey ? "Paste a new key to replace" : "Paste your Gemini API key", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: width - 72)
                    .onSubmit(save)
                Button(action: save) {
                    Text(check == .checking ? "Checking…" : "Save")
                        .frame(minWidth: 36)
                }
                .pttButton()
                .disabled(trimmedDraft.isEmpty || check == .checking)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(PTT.textMuted(scheme))
                if prefs.hasGeminiKey, check == .idle {
                    Button("Remove") { prefs.geminiAPIKey = nil }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }

            Link("Get an API key in Google AI Studio ↗", destination: Self.keyPageURL)
                .font(.system(size: 11))

            Text("Audio is sent to Google for transcription. Set up billing for the key in AI Studio — with \(prefs.geminiModel.shortLabel) Google charges about \(prefs.geminiModel.costPerHour) per hour of speech; without billing the key stops after a couple dozen dictations a day.")
                .font(.system(size: 11))
                .foregroundColor(PTT.textSoft(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width, alignment: .leading)
        }
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var statusText: String {
        switch check {
        case .checking:    return "Checking the key with Google…"
        case .invalid:     return "Google rejected this key."
        case .unreachable: return "Couldn't reach Google — check your connection."
        case .idle:        return prefs.hasGeminiKey ? "API key saved in Keychain" : "No API key"
        }
    }

    private var statusColor: Color {
        switch check {
        case .invalid, .unreachable: return PTT.recordingRed
        case .checking:              return PTT.textSoft(scheme)
        case .idle:                  return prefs.hasGeminiKey ? PTT.statusGreen : PTT.textSoft(scheme)
        }
    }

    private func save() {
        let key = trimmedDraft
        guard !key.isEmpty, check != .checking else { return }
        check = .checking
        Task { @MainActor in
            switch await GeminiClient().check(apiKey: key) {
            case .valid:
                prefs.geminiAPIKey = key
                draft = ""
                check = .idle
            case .invalid:
                check = .invalid
            case .unreachable:
                check = .unreachable
            }
        }
    }
}
