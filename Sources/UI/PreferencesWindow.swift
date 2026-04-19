import SwiftUI
import AppKit

@MainActor
final class ModelsViewModel: ObservableObject {
    @Published var downloading = false
    @Published var progress: Double = 0

    func isLocated(_ id: WhisperModelID) -> Bool { ModelManager.shared.locateModel(id) != nil }

    func status(for id: WhisperModelID) -> String {
        isLocated(id) ? "Downloaded." : "Not downloaded."
    }

    func download(_ id: WhisperModelID) async {
        downloading = true
        progress = 0
        defer { downloading = false }
        do {
            _ = try await ModelManager.shared.download(id) { [weak self] p in
                Task { @MainActor in self?.progress = p }
            }
        } catch {
            NSLog("Model download failed: \(error)")
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var prefs = PreferencesStore.shared
    @ObservedObject var modelsVM: ModelsViewModel
    var onClearHistory: () -> Void

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            audioTab.tabItem { Label("Audio", systemImage: "waveform") }
            historyTab.tabItem { Label("History", systemImage: "clock") }
        }
        .padding(16)
        .frame(width: 460, height: 340)
    }

    private var generalTab: some View {
        Form {
            Picker("Hotkey", selection: $prefs.hotkey) {
                ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) }
            }
            HStack {
                Text("Hold threshold")
                Slider(value: .init(get: { Double(prefs.holdThresholdMs) },
                                    set: { prefs.holdThresholdMs = Int($0) }),
                       in: 50...800, step: 10)
                Text("\(prefs.holdThresholdMs) ms")
                    .frame(width: 70, alignment: .trailing)
                    .monospacedDigit()
            }
            Text("Short taps pass through. Holds longer than this start recording.")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("HUD content", selection: $prefs.hudContentMode) {
                ForEach(HUDContentMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("HUD position", selection: $prefs.hudPosition) {
                ForEach(HUDPosition.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Launch at login", isOn: $prefs.launchAtLogin)
        }
    }

    private var audioTab: some View {
        Form {
            Picker("Primary language", selection: $prefs.primaryLanguage) {
                ForEach(PrimaryLanguage.allCases) { Text($0.label).tag($0) }
            }
            Text("Forcing a language helps on short utterances where auto-detect drifts to English.")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("Whisper model", selection: $prefs.modelID) {
                ForEach(WhisperModelID.allCases) { Text($0.label).tag($0) }
            }
            Text(modelsVM.status(for: prefs.modelID))
                .font(.caption)
                .foregroundColor(.secondary)
            if modelsVM.downloading {
                ProgressView(value: modelsVM.progress)
            } else {
                Button("Download selected model") {
                    Task { await modelsVM.download(prefs.modelID) }
                }
                .disabled(modelsVM.isLocated(prefs.modelID))
            }
        }
    }

    private var historyTab: some View {
        Form {
            Button("Clear history…", role: .destructive) {
                let alert = NSAlert()
                alert.messageText = "Clear all transcription history?"
                alert.informativeText = "This cannot be undone and resets metrics."
                alert.addButton(withTitle: "Clear")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { onClearHistory() }
            }
        }
    }
}

final class PreferencesWindowController: NSWindowController {
    convenience init() {
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        let win = NSWindow(contentViewController: host)
        win.title = "Push-to-Talk Preferences"
        win.styleMask = [.titled, .closable]
        self.init(window: win)
    }

    func present<V: View>(_ view: V) {
        if let host = window?.contentViewController as? NSHostingController<AnyView> {
            host.rootView = AnyView(view)
        }
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }
}
