import SwiftUI

struct OnboardingView: View {
    @ObservedObject var modelsVM: ModelsViewModel
    @ObservedObject private var prefs = PreferencesStore.shared
    @State private var perms = PermissionsManager.shared.current()
    @State private var step: Step
    @State private var choice: TranscriptionEngineKind = .whisper
    /// Called when the user confirms an engine (a cloud engine's key is already saved by then).
    var onEngineChosen: (TranscriptionEngineKind) -> Void
    var onDone: () -> Void

    private enum Step { case engine, permissions }

    init(modelsVM: ModelsViewModel,
         needsEngine: Bool,
         onEngineChosen: @escaping (TranscriptionEngineKind) -> Void,
         onDone: @escaping () -> Void) {
        self.modelsVM = modelsVM
        self.onEngineChosen = onEngineChosen
        self.onDone = onDone
        _step = State(initialValue: needsEngine ? .engine : .permissions)
    }

    var body: some View {
        Group {
            switch step {
            case .engine:      engineStep
            case .permissions: permissionsStep
            }
        }
        .padding(20)
        .frame(width: 480, height: 520)
    }

    // MARK: - Engine

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How should HoldSpeak recognize speech?")
                .font(.title2).bold()
            engineCard(.whisper,
                       title: "\(prefs.modelID.shortLabel) — on this Mac",
                       detail: "Free and private, works offline. Downloads a \(prefs.modelID.downloadSize) model now.")
            engineCard(.gemini,
                       title: "Gemini — Google cloud",
                       detail: "Usually more accurate with mixed languages and jargon. Needs your own Google AI Studio API key with billing.")
            engineCard(.openai,
                       title: "OpenAI — cloud",
                       detail: "Dedicated speech-to-text models, good with jargon. Needs your own OpenAI API key with credits.")
            if let provider = choice.cloudProvider {
                APIKeyEditor(provider: provider, width: 420)
                    .padding(.leading, 4)
            }
            Text("You can switch later in Preferences → Audio.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Continue") {
                    onEngineChosen(choice)
                    perms = PermissionsManager.shared.current()
                    if perms.allGranted { onDone() } else { step = .permissions }
                }
                .disabled(choice.cloudProvider.map { !prefs.hasAPIKey($0) } ?? false)
                .keyboardShortcut(.defaultAction)
                .modifier(PrimaryOnGlass())
            }
        }
    }

    private func engineCard(_ kind: TranscriptionEngineKind, title: String, detail: String) -> some View {
        let selected = choice == kind
        return Button { choice = kind } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? .accentColor : .secondary)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(Rectangle())
            .pttSurface(glass: RoundedRectangle(cornerRadius: 16),
                        fallback: RoundedRectangle(cornerRadius: 8),
                        fill: Color.secondary.opacity(selected ? 0.12 : 0.05),
                        border: selected ? Color.accentColor : .clear,
                        tint: selected ? Color.accentColor.opacity(0.35) : nil,
                        interactive: true)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("HoldSpeak needs a few permissions")
                .font(.title2).bold()
            row("Microphone", ok: perms.microphone) {
                Task {
                    _ = await PermissionsManager.shared.requestMicrophone()
                    refresh()
                }
            }
            row("Accessibility (global hotkey and text insertion)", ok: perms.accessibility) {
                PermissionsManager.shared.openAccessibilitySettings()
            }
            row("Input Monitoring", ok: perms.inputMonitoring) {
                PermissionsManager.shared.openInputMonitoringSettings()
            }
            if prefs.engine == .whisper {
                row("Documents folder (reuse existing WhisperKit models)",
                    ok: perms.documentsAccess,
                    optional: true) {
                    if PermissionsManager.shared.requestDocumentsAccess() {
                        refresh()
                    } else {
                        PermissionsManager.shared.openDocumentsSettings()
                    }
                }
                Text("The Documents permission is optional — without it, HoldSpeak still works and just downloads models into its own folder on first use.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if modelsVM.downloading {
                HStack(spacing: 10) {
                    Text("Downloading \(prefs.modelID.shortLabel)…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ProgressView(value: modelsVM.progress)
                }
            }
            HStack {
                Button("Re-check") { refresh() }
                Spacer()
                Button("Done") { onDone() }
                    .disabled(!perms.allGranted)
                    .keyboardShortcut(.defaultAction)
                    .modifier(PrimaryOnGlass())
            }
        }
    }

    private func row(_ title: String, ok: Bool, optional: Bool = false, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundColor(ok ? .green : .secondary)
            Text(title)
            if optional {
                Text("Optional")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
            Button("Open…", action: action)
                .opacity(ok ? 0 : 1)
                .disabled(ok)
        }
        .frame(height: 28)
    }

    private func refresh() {
        perms = PermissionsManager.shared.current()
    }
}

/// The default button is already blue below macOS 26; there it becomes prominent glass.
private struct PrimaryOnGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content
        }
    }
}
