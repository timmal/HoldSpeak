import SwiftUI
import AppKit

@MainActor
final class ModelsViewModel: ObservableObject {
    @Published var downloading = false
    @Published var progress: Double = 0

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
        } catch {
            NSLog("Model download failed: \(error)")
        }
    }
}

enum PrefsTab: String, CaseIterable, Identifiable {
    case general, audio, history, support
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .audio:   return "Audio"
        case .history: return "History"
        case .support: return "Support"
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var prefs = PreferencesStore.shared
    @ObservedObject var modelsVM: ModelsViewModel
    var historyStore: HistoryStoring
    var onClearHistory: () -> Void
    var initialTab: PrefsTab = .general

    @Environment(\.colorScheme) private var scheme
    @State private var tab: PrefsTab = .general
    @State private var updateStatus: String?
    @State private var history: [TranscriptionRecord] = []

    private static let historyLimit = 500

    private func loadHistory() {
        history = (try? historyStore.recent(limit: Self.historyLimit)) ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)

            ScrollView {
                Group {
                    switch tab {
                    case .general: generalTab
                    case .audio:   audioTab
                    case .history: historyTab
                    case .support: supportTab
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 428)
        .background(VisualEffectBackground(material: .windowBackground))
        .background(PTT.prefsBG(scheme))
        .preferredColorScheme(colorSchemeOverride)
        .onAppear {
            tab = initialTab
            if tab == .history { loadHistory() }
        }
        .onChange(of: tab) { newTab in if newTab == .history { loadHistory() } }
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
                Button { tab = t } label: {
                    Text(t.title)
                        .font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                        .foregroundColor(tab == t ? PTT.textPrimary(scheme) : PTT.textMuted(scheme))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(tab == t ? PTT.segmentSelected(scheme) : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(PTT.segmentBG(scheme))
        )
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
                        Slider(value: .init(get: { Double(prefs.holdThresholdMs) },
                                            set: { prefs.holdThresholdMs = Int($0) }),
                               in: 50...800, step: 10)
                            .frame(width: 280)
                        Text("\(prefs.holdThresholdMs) ms")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(PTT.textPrimary(scheme))
                            .monospacedDigit()
                    }
                    Text("Short taps pass through. Holds longer start recording.")
                        .font(.system(size: 11))
                        .foregroundColor(PTT.textSoft(scheme))
                }
            }

            labeledRow("HUD position") {
                styledDropdown(selection: $prefs.hudPosition, width: 240, current: prefs.hudPosition.label) {
                    ForEach(HUDPosition.allCases) { Text($0.label).tag($0) }
                }
            }

            labeledRow("Theme") {
                styledDropdown(selection: $prefs.appTheme, width: 240, current: prefs.appTheme.label) {
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
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(PTT.textPrimary(scheme))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8).fill(PTT.buttonBG(scheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8).stroke(PTT.fieldBorder(scheme), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    Text(updateStatus ?? "You're on v\(UpdateChecker.currentVersion)")
                        .font(.system(size: 11))
                        .foregroundColor(PTT.textSoft(scheme))
                }
            }
        }
    }

    // MARK: - Audio

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            labeledRow("Primary language", alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    styledDropdown(selection: $prefs.primaryLanguage, width: 280, current: prefs.primaryLanguage.label) {
                        ForEach(PrimaryLanguage.allCases) { Text($0.label).tag($0) }
                    }
                    Text("Forcing a language helps on short utterances.")
                        .font(.system(size: 11))
                        .foregroundColor(PTT.textSoft(scheme))
                }
            }

            labeledRow("Whisper model", alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    styledDropdown(selection: $prefs.modelID, width: 320, current: prefs.modelID.label) {
                        ForEach(WhisperModelID.allCases) { Text($0.label).tag($0) }
                    }
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

            labeledRow("", alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $prefs.fastInsert) {
                        Text("Fast insert (use streaming result)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(PTT.textPrimary(scheme))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Text("Inserts streaming transcript on release. Faster, may clip last fragment.")
                        .font(.system(size: 11))
                        .foregroundColor(PTT.textSoft(scheme))
                }
            }

            labeledRow("") {
                if modelsVM.downloading {
                    ProgressView(value: modelsVM.progress).frame(width: 240)
                } else {
                    Button {
                        Task { await modelsVM.download(prefs.modelID) }
                    } label: {
                        Text("Download selected model")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(modelsVM.isLocated(prefs.modelID) ? PTT.textMuted(scheme) : PTT.textPrimary(scheme))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8).fill(PTT.buttonBG(scheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8).stroke(PTT.fieldBorder(scheme), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(modelsVM.isLocated(prefs.modelID))
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
                    alert.messageText = "Clear all transcription history?"
                    alert.informativeText = "This cannot be undone and resets metrics."
                    alert.addButton(withTitle: "Clear")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        onClearHistory()
                        history = []
                    }
                } label: {
                    Text("Clear history…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(PTT.recordingRed)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(PTT.buttonBG(scheme))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).stroke(PTT.fieldBorder(scheme), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
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

    // MARK: - Styled dropdown

    @ViewBuilder
    private func styledDropdown<V: Hashable, Content: View>(
        selection: Binding<V>,
        width: CGFloat,
        current: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                Text(current)
                    .font(.system(size: 13))
                    .foregroundColor(PTT.textPrimary(scheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(PTT.textMuted(scheme))
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(width: width, height: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(PTT.fieldBG(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PTT.fieldBorder(scheme), lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
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
        win.title = "Push-to-Talk Preferences"
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
