import SwiftUI

/// API key field for a cloud engine: checks the key with the provider before saving
/// it to the Keychain. Used in onboarding and in Preferences → Audio.
struct APIKeyEditor: View {
    let provider: CloudProvider
    @ObservedObject private var prefs = PreferencesStore.shared
    var width: CGFloat = 280

    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""
    @State private var check: Check = .idle

    private enum Check { case idle, checking, invalid, unreachable }

    init(provider: CloudProvider, width: CGFloat = 280) {
        self.provider = provider
        self.width = width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField(hasKey ? "Paste a new key to replace" : "Paste your \(provider.name) API key", text: $draft)
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
                if hasKey, check == .idle {
                    Button("Remove") { prefs.setAPIKey(nil, for: provider) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }

            Link(keyPageTitle, destination: keyPageURL)
                .font(.system(size: 11))

            Text(pricingNote)
                .font(.system(size: 11))
                .foregroundColor(PTT.textSoft(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width, alignment: .leading)
        }
        // Switching the model between providers reuses this view for the other one.
        .onChange(of: provider) { _ in
            draft = ""
            check = .idle
        }
    }

    private var hasKey: Bool { prefs.hasAPIKey(provider) }

    private var keyPageTitle: String {
        switch provider {
        case .gemini: return "Get an API key in Google AI Studio ↗"
        case .openai: return "Get an API key on the OpenAI Platform ↗"
        }
    }

    private var keyPageURL: URL {
        switch provider {
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    private var pricingNote: String {
        switch provider {
        case .gemini:
            let model = prefs.geminiModel
            return "Audio is sent to Google for transcription. Set up billing for the key in AI Studio — \(model.shortLabel) costs about \(model.costPerHour) per hour of speech; without billing the key stops after a couple dozen dictations a day."
        case .openai:
            let model = prefs.openAIModel
            return "Audio is sent to OpenAI for transcription. \(model.shortLabel) costs about \(model.costPerHour) per hour of speech; the key needs prepaid credits in OpenAI Billing."
        }
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var statusText: String {
        switch check {
        case .checking:    return "Checking the key with \(provider.company)…"
        case .invalid:     return "\(provider.company) rejected this key."
        case .unreachable: return "Couldn't reach \(provider.company) — check your connection."
        case .idle:        return hasKey ? "API key saved in Keychain" : "No API key"
        }
    }

    private var statusColor: Color {
        switch check {
        case .invalid, .unreachable: return PTT.recordingRed
        case .checking:              return PTT.textSoft(scheme)
        case .idle:                  return hasKey ? PTT.statusGreen : PTT.textSoft(scheme)
        }
    }

    private func save() {
        let key = trimmedDraft
        guard !key.isEmpty, check != .checking else { return }
        check = .checking
        let provider = provider
        Task { @MainActor in
            let result: APIKeyCheck
            switch provider {
            case .gemini: result = await GeminiClient().check(apiKey: key)
            case .openai: result = await OpenAIClient().check(apiKey: key)
            }
            // The user switched providers while the check was running.
            guard provider == self.provider else { return }
            switch result {
            case .valid:
                prefs.setAPIKey(key, for: provider)
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
