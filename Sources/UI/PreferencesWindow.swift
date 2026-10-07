import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class ModelsViewModel: ObservableObject {
    @Published var downloading = false
    @Published var progress: Double = 0
    /// Disk used by models HoldSpeak downloaded itself (not other apps' copies).
    @Published var managedBytes: Int64 = 0
    /// Called on main after a successful download, so the engine can load the model.
    var onDownloaded: ((WhisperModelID) -> Void)?
    /// Called on main after the downloaded models were deleted.
    var onDeleted: (() -> Void)?

    func isLocated(_ id: WhisperModelID) -> Bool { ModelManager.shared.locateModel(id) != nil }

    func status(for id: WhisperModelID) -> String {
        isLocated(id) ? "Downloaded" : "Not downloaded"
    }

    func download(_ id: WhisperModelID) async {
        downloading = true
        progress = 0
        defer { downloading = false }
        do {
            _ = try await ModelManager.shared.download(id) { [weak self] p in
                Task { @MainActor in self?.progress = p }
            }
            onDownloaded?(id)
        } catch {
            NSLog("Model download failed: \(error)")
        }
        refreshManagedSize()
    }

    func refreshManagedSize() {
        DispatchQueue.global(qos: .utility).async {
            let bytes = ModelManager.shared.managedBytes()
            DispatchQueue.main.async { self.managedBytes = bytes }
        }
    }

    func deleteManagedModels() {
        do {
            try ModelManager.shared.deleteManagedModels()
            pttLog("Deleted downloaded Whisper models")
        } catch {
            pttLog("Deleting models failed: \(error)")
        }
        objectWillChange.send() // isLocated(_:) answers differently now
        onDeleted?()
        refreshManagedSize()
    }
}

enum PrefsTab: String, CaseIterable, Identifiable {
    case general, audio, terminology, history, support
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general:     return "General"
        case .audio:       return "Audio"
        case .terminology: return "Terms"
        case .history:     return "History"
        case .support:     return "Support"
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var prefs = PreferencesStore.shared
    @ObservedObject var modelsVM: ModelsViewModel
    var historyStore: HistoryStoring
    var onClearHistory: () -> Void
    var onResetMetrics: () -> Void
    var initialTab: PrefsTab = .general

    @Environment(\.colorScheme) private var scheme
    @State private var tab: PrefsTab = .general
    @Namespace private var tabNamespace
    @State private var updateStatus: String?
    @State private var history: [TranscriptionRecord] = []
    @State private var inputDevices: [InputDevice.Info] = []

    private static let historyLimit = HistoryStore.maxEntries

    private func loadHistory() {
        history = (try? historyStore.recent(limit: Self.historyLimit)) ?? []
    }

    var body: some View {
        // The tab bar sits above the content rather than over it, so nothing
        // scrolls under the bar or the transparent title bar.
        VStack(spacing: 0) {
            tabBar
            tabContent
        }
        .frame(width: 560, height: 428)
        .modifier(PrefsWindowBackground())
        .preferredColorScheme(colorSchemeOverride)
        .onAppear {
            tab = initialTab
            if tab == .history { loadHistory() }
        }
        .onChange(of: tab) { newTab in if newTab == .history { loadHistory() } }
        .onReceive(NotificationCenter.default.publisher(for: .historyDidChange)) { _ in
            if tab == .history { loadHistory() }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        Group {
            if tab == .terminology {
                TerminologyPreferencesView()
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    Group {
                        switch tab {
                        case .general:     generalTab
                        case .audio:       audioTab
                        case .terminology: EmptyView()
                        case .history:     historyTab
                        case .support:     supportTab
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// `.requiresApproval` counts as on: the item is registered, the user just has
    /// to allow it in System Settings → Login Items.
    private func syncLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        let on = status == .enabled || status == .requiresApproval
        if prefs.launchAtLogin != on { prefs.launchAtLogin = on }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        let registered = service.status == .enabled || service.status == .requiresApproval
        do {
            if enabled, !registered {
                try service.register()
            } else if !enabled, registered {
                try service.unregister()
            }
        } catch {
            pttLog("Launch at login \(enabled ? "register" : "unregister") failed: \(error)")
        }
        syncLaunchAtLogin()
    }

    private var colorSchemeOverride: ColorScheme? {
        switch prefs.appTheme {
        case .auto:  return nil
        case .light: return .light
        case .dark:  return .dark
        }
    }

    // MARK: - Tab bar (pill segmented)

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(PrefsTab.allCases) { t in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { tab = t }
                } label: {
                    Text(t.title)
                        .font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                        .foregroundColor(tab == t ? PTT.textPrimary(scheme) : PTT.textMuted(scheme))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background {
                            if tab == t {
                                Capsule()
                                    .fill(PTT.segmentSelected(scheme))
                                    .matchedGeometryEffect(id: "selectedTab", in: tabNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .pttSurface(glass: Capsule(), fallback: Capsule(), fill: PTT.segmentBG(scheme))
        .padding(.vertical, 14)
    }

    // MARK: - Rows

    private func labeledRow<Content: View>(
        _ label: String,
        alignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignment, spacing: 16) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(PTT.textMuted(scheme))
                .frame(width: 140, height: 28, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    // MARK: - General

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            labeledRow("Hotkey") { HotkeyRecorderView() }

            labeledRow("Hold threshold", alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        // Rounded in the setter rather than with `step:`, which draws
                        // a tick for every 10 ms on macOS 26+.
                        Slider(value: .init(get: { Double(prefs.holdThresholdMs) },
                                            set: { prefs.holdThresholdMs = Int(($0 / 10).rounded()) * 10 }),
                               in: 50...800)
                            .frame(width: 260)
                        Text("\(prefs.holdThresholdMs) ms")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(PTT.textPrimary(scheme))
                            .monospacedDigit()
                            .fixedSize()
                    }
                    Text("Short taps pass through. Holds longer start recording.")
                        .font(.system(size: 11))
                        .foregroundColor(PTT.textSoft(scheme))
                }
            }

            labeledRow("HUD position") {
                StyledDropdown(selection: $prefs.hudPosition, width: 240, current: prefs.hudPosition.label) {
                    ForEach(HUDPosition.allCases) { Text($0.label).tag($0) }
                }
            }

            labeledRow("Theme") {
                StyledDropdown(selection: $prefs.appTheme, width: 240, current: prefs.appTheme.label) {
                    ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: prefs.appTheme) { _ in prefs.applyAppearance() }
            }

            labeledRow("") {
                Toggle(isOn: $prefs.launchAtLogin) {
                    Text("Launch at login")
                        .font(.system(size: 13))
                        .foregroundColor(PTT.textBody(scheme))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .onAppear(perform: syncLaunchAtLogin)
                .onChange(of: prefs.launchAtLogin, perform: applyLaunchAtLogin)
            }

            labeledRow("Updates", alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        Task {
                            updateStatus = "Checking…"
                            if let info = await UpdateChecker.shared.latest() {
                                if UpdateChecker.isNewer(info.version, than: UpdateChecker.currentVersion) {
                                    updateStatus = "v\(info.version) available"
                                    NSWorkspace.shared.open(info.url)
                                } else {
                                    updateStatus = "You're on the latest version (v\(UpdateChecker.currentVersion))."
                                }
                            } else {
                                updateStatus = "Could not reach GitHub."
                            }
                        }
                    } label: {
                        Text("Check for updates")
                    }
                    .pttButton()

                    Text(updateStatus ?? "You're on v\(UpdateChecker.currentVersion)")
                        .font(.system(size: 11))
                        .foregroundColor(PTT.textSoft(scheme))
                }
            }
        }
    }

    // MARK: - Audio

    private func loadInputDevices() {
        DispatchQueue.global(qos: .userInitiated).async {
            let devices = InputDevice.inputDevices()
            DispatchQueue.main.async { inputDevices = devices }
        }
    }

    private func inputLabel(_ selection: InputSelection) -> String {
        switch selection {
        case .systemDefault: return "System default"
        case .avoidBluetooth: return "Built-in if default is Bluetooth"
        case .device(let uid):
            guard let d = inputDevices.first(where: { $0.uid == uid }) else { return "Disconnected device" }
            return d.isContinuity ? "\(d.name) (slow to start)" : d.name
        }
    }

    private func confirmDeleteModels() {
        let size = ByteCountFormatter.string(fromByteCount: modelsVM.managedBytes, countStyle: .file)
        let alert = NSAlert()
        alert.messageText = "Delete downloaded Whisper models?"
        alert.informativeText = "Frees \(size). Only models HoldSpeak downloaded are removed — copies from MacWhisper or other apps stay. You can download a model again at any time."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            modelsVM.deleteManagedModels()
        }
    }

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            labeledRow("Microphone", alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    StyledDropdown(selection: $prefs.inputSelection, width: 280,
                                   current: inputLabel(prefs.inputSelection)) {
                        Text(inputLabel(.avoidBluetooth)).tag(InputSelection.avoidBluetooth)
                        Text(inputLabel(.systemDefault)).tag(InputSelection.systemDefault)
                        Divider()
                        ForEach(inputDevices) { d in
                            Text(d.isContinuity ? "\(d.name) (slow to start)" : d.name)
                                .tag(InputSelection.device(uid: d.uid))
                        }
                    }
                    Text("Recording through a Bluetooth mic makes headphone audio stutter and drop in quality.")
                        .font(.system(size: 11))
                        .foregroundColor(PTT.textSoft(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 280, alignment: .leading)
                }
            }
            .onAppear {
                loadInputDevices()
                modelsVM.refreshManagedSize()
            }

            labeledRow("Primary language", alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    StyledDropdown(selection: $prefs.primaryLanguage, width: 280, current: prefs.primaryLanguage.label) {
                        ForEach(PrimaryLanguage.allCases) { Text($0.label).tag($0) }
                    }
                    Text("Forcing a language helps on short utterances.")
                        .font(.system(size: 11))
                        .foregroundColor(PTT.textSoft(scheme))
                }
            }

            labeledRow("Model", alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    StyledDropdown(selection: $prefs.modelChoice, width: 280, current: prefs.modelChoice.label) {
                        Section("Whisper — on this Mac, free") {
                            ForEach(WhisperModelID.allCases) { Text($0.label).tag(ModelChoice.whisper($0)) }
                        }
                        Section("Gemini — Google cloud, your API key") {
                            ForEach(GeminiModelID.allCases) { Text($0.label).tag(ModelChoice.gemini($0)) }
                        }
                    }
                    if prefs.engine == .whisper {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(modelsVM.isLocated(prefs.modelID) ? PTT.statusGreen : PTT.textSoft(scheme))
                                .frame(width: 8, height: 8)
                            Text(modelsVM.status(for: prefs.modelID))
                                .font(.system(size: 11))
                                .foregroundColor(PTT.textMuted(scheme))
                        }
                    }
                }
            }

            if prefs.engine == .whisper {
                labeledRow("") {
                    if modelsVM.downloading {
                        ProgressView(value: modelsVM.progress).frame(width: 240)
                    } else {
                        Button {
                            Task { await modelsVM.download(prefs.modelID) }
                        } label: {
                            Text("Download selected model")
                        }
                        .pttButton()
                        .disabled(modelsVM.isLocated(prefs.modelID))
                    }
                }
            } else {
                labeledRow("API key", alignment: .top) {
                    GeminiKeyEditor()
                }
            }

            if modelsVM.managedBytes > 0, !modelsVM.downloading {
                labeledRow("Downloaded models") {
                    HStack(spacing: 12) {
                        Text(ByteCountFormatter.string(fromByteCount: modelsVM.managedBytes, countStyle: .file))
                            .font(.system(size: 13))
                            .foregroundColor(PTT.textBody(scheme))
                            .monospacedDigit()
                        Button(action: confirmDeleteModels) {
                            Text("Delete…")
                                .foregroundColor(PTT.recordingRed)
                        }
                        .pttButton()
                    }
                }
            }

            labeledRow("") {
                Toggle(isOn: $prefs.autoPunctuation) {
                    Text("Add period at end of sentence")
                        .font(.system(size: 13))
                        .foregroundColor(PTT.textBody(scheme))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }

            labeledRow("") {
                Toggle(isOn: $prefs.autoCapitalize) {
                    Text("Capitalize first letter")
                        .font(.system(size: 13))
                        .foregroundColor(PTT.textBody(scheme))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }

            labeledRow("", alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $prefs.removeFillers) {
                        Text("Remove filler words")
                            .font(.system(size: 13))
                            .foregroundColor(PTT.textBody(scheme))
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)

                    if prefs.removeFillers {
                        if prefs.engine == .whisper {
                            TextField("ну, короче, um", text: $prefs.fillerWords, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(2...4)
                                .frame(width: 280)
                            Text("Comma-separated. Whole words only, any case.")
                                .font(.system(size: 11))
                                .foregroundColor(PTT.textSoft(scheme))
                        } else {
                            Text("Gemini drops them by context and keeps the ones that carry meaning.")
                                .font(.system(size: 11))
                                .foregroundColor(PTT.textSoft(scheme))
                        }
                    }
                }
            }
        }
    }

    // MARK: - History

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("Recent transcriptions")
                    .font(.system(size: 13))
                    .foregroundColor(PTT.textBody(scheme))
                Spacer()
                Button {
                    let alert = NSAlert()
                    alert.messageText = "Reset metrics?"
                    alert.informativeText = "Dictation counts and WPM in the popover will start from zero. History is kept."
                    alert.addButton(withTitle: "Reset")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        onResetMetrics()
                    }
                } label: {
                    Text("Reset metrics")
                }
                .pttButton()

                Button {
                    let alert = NSAlert()
                    alert.messageText = "Clear all transcription history?"
                    alert.informativeText = "This cannot be undone. Dictation counts and WPM are kept."
                    alert.addButton(withTitle: "Clear")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        onClearHistory()
                        history = []
                    }
                } label: {
                    Text("Clear history…")
                        .foregroundColor(PTT.recordingRed)
                }
                .pttButton()
                .disabled(history.isEmpty)
            }

            if history.isEmpty {
                Text("No transcriptions yet.")
                    .font(.system(size: 13))
                    .foregroundColor(PTT.textMuted(scheme))
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(history) { r in
                        HistoryRow(text: r.cleanedText)
                    }
                }
            }
        }
    }

    // MARK: - Support

    private var supportTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You can buy me a coffee ☕")
                .font(.system(size: 13))
                .foregroundColor(PTT.textBody(scheme))

            AddressRow(label: "USDT (TRC-20)", value: "TJYkdABdvB587bsWbyCLQ25g8JmTqiXs5h")
        }
    }
}

// MARK: - Window chrome

/// macOS 26+ uses the standard window background, which Liquid Glass controls are
/// designed against; older systems keep the blurred dark panel.
private struct PrefsWindowBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.background(Color(nsColor: .windowBackgroundColor))
        } else {
            content
                .background(VisualEffectBackground(material: .windowBackground))
                .background(PTT.prefsBG(scheme))
        }
    }
}

// MARK: - History row

private struct HistoryRow: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(PTT.textBody(scheme))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                if copied {
                    Text("Copied")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(PTT.accentLink(scheme))
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundColor(PTT.textMuted(scheme))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(PTT.cardBG(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(PTT.surfaceBorder(scheme), lineWidth: 1)
        )
    }
}

// MARK: - Address row

private struct AddressRow: View {
    let label: String
    let value: String
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(PTT.textMuted(scheme))

            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(PTT.textBody(scheme))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                if copied {
                    Text("Copied")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(PTT.accentLink(scheme))
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundColor(PTT.textMuted(scheme))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(PTT.cardBG(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(PTT.surfaceBorder(scheme), lineWidth: 1)
        )
    }
}

final class PreferencesWindowController: NSWindowController {
    convenience init() {
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        let win = NSWindow(contentViewController: host)
        win.title = "HoldSpeak Preferences"
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
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
