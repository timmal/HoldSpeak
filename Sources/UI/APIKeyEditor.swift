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
    /// Identifies the key check in flight; cleared when the provider changes, so a
    /// result that arrives afterwards is dropped instead of landing on the other provider.
    @State private var checkToken: UUID?

    private enum Check { case idle, checking, invalid, unreachable, saveFailed }

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
                .disabled(trimmedDraft.isEmpty || check == .checking || keysLoading)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(PTT.textMuted(scheme))
                if keysUnavailable, check == .idle {
                    Button("Try again") { prefs.reloadAPIKeys() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                } else if hasKey, check == .idle || check == .saveFailed {
                    Button("Remove") { store(nil) }
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
        .onAppear { prefs.warmAPIKeys() }
        // Switching the model between providers reuses this view for the other one.
        .onChange(of: provider) { _ in
            draft = ""
            check = .idle
            checkToken = nil
        }
    }

    /// Never reads the Keychain on main: until `warmAPIKeys` is done the view says so.
    private var hasKey: Bool { prefs.hasLoadedAPIKey(provider) }
    private var keysLoading: Bool {
        let availability = prefs.apiKeyAvailability
        return availability == .notLoaded || availability == .loading
    }
    /// The Keychain prompt was denied: the keys may be there, this session can't read them.
    private var keysUnavailable: Bool { prefs.apiKeysUnavailable }

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
        case .saveFailed:  return "Couldn't save to Keychain"
        case .idle:
            if keysLoading { return "Reading Keychain…" }
            if keysUnavailable { return "Keychain access was denied" }
            return hasKey ? "API key saved in Keychain" : "No API key"
        }
    }

    private var statusColor: Color {
        switch check {
        case .invalid, .unreachable, .saveFailed: return PTT.recordingRed
        case .checking:              return PTT.textSoft(scheme)
        case .idle:
            if keysUnavailable { return PTT.recordingRed }
            return hasKey ? PTT.statusGreen : PTT.textSoft(scheme)
        }
    }

    private func save() {
        let key = trimmedDraft
        guard !key.isEmpty, check != .checking, !keysLoading else { return }
        check = .checking
        let token = UUID()
        checkToken = token
        let provider = provider
        Task { @MainActor in
            let result: APIKeyCheck
            switch provider {
            case .gemini: result = await GeminiClient().check(apiKey: key)
            case .openai: result = await OpenAIClient().check(apiKey: key)
            }
            // `self` is the copy captured at Save, so `self.provider` can't tell; the
            // token is @State and reads the live value. Nil or newer: the user switched
            // providers while the check ran, so this result is dropped, key included.
            guard checkToken == token else { return }
            checkToken = nil
            switch result {
            case .valid:
                if store(key) { draft = "" }
            case .invalid:
                check = .invalid
            case .unreachable:
                check = .unreachable
            }
        }
    }

    /// Saves (nil removes) the key and shows the outcome. While Keychain access is
    /// denied nothing is written and the status line says so; the draft stays.
    @discardableResult
    private func store(_ key: String?) -> Bool {
        // Unless the keys are loaded, saving would read the Keychain again here on main
        // and block it on the password prompt: "Try again" asks off main instead.
        guard prefs.apiKeyAvailability == .loaded else {
            check = .idle
            return false
        }
        let saved = prefs.setAPIKey(key, for: provider)
        check = saved || prefs.apiKeysUnavailable ? .idle : .saveFailed
        return saved
    }
}
