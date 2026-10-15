import SwiftUI
import AppKit

@MainActor
final class PopoverViewModel: ObservableObject {
    @Published var metrics: Metrics = .zero
    @Published var recent: [TranscriptionRecord] = []
    @Published var hasMore: Bool = false
    @Published var copiedID: Int64?
    @Published var update: ReleaseInfo?

    static let recentVisible = 7

    private let store: HistoryStoring
    private let metricsEngine: MetricsComputing

    init(store: HistoryStoring, metricsEngine: MetricsComputing) {
        self.store = store
        self.metricsEngine = metricsEngine
    }

    func refresh() {
        metrics = (try? metricsEngine.current(now: Date())) ?? .zero
        let fetched = (try? store.recent(limit: Self.recentVisible + 1)) ?? []
        hasMore = fetched.count > Self.recentVisible
        recent = Array(fetched.prefix(Self.recentVisible))
    }

    func checkForUpdates() async {
        guard let info = await UpdateChecker.shared.latest() else { return }
        if UpdateChecker.isNewer(info.version, than: UpdateChecker.currentVersion) {
            update = info
        } else {
            update = nil
        }
    }

    func copy(_ record: TranscriptionRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.cleanedText, forType: .string)
        copiedID = record.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == record.id { self?.copiedID = nil }
        }
    }
}

struct PopoverView: View {
    @ObservedObject var vm: PopoverViewModel
    @ObservedObject private var prefs = PreferencesStore.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(PTT.divider(scheme)).frame(height: 1)

            if let upd = vm.update {
                updateBanner(upd)
                Divider().background(PTT.divider(scheme)).frame(height: 1)
            }

            statsRow
            Divider().background(PTT.divider(scheme)).frame(height: 1)

            recentSection
            Divider().background(PTT.divider(scheme)).frame(height: 1)

            footer
        }
        .frame(width: 320)
        .modifier(PopoverChrome())
        .preferredColorScheme(colorSchemeOverride)
    }

    private var colorSchemeOverride: ColorScheme? {
        switch prefs.appTheme {
        case .auto:  return nil
        case .light: return .light
        case .dark:  return .dark
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            radioIcon
                .frame(width: 18, height: 18)
                .foregroundColor(PTT.textPrimary(scheme))
            Text("HoldSpeak")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(PTT.textPrimary(scheme))
            Spacer()
            Text(hotkeyHint)
                .font(.system(size: 12, weight: .medium))
                .pttMuted(PTT.textMuted(scheme))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var hotkeyHint: String { prefs.hotkey.label }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 10) {
            statCard(value: "\(vm.metrics.dictationsToday.formatted())", label: "today",
                     detail: "(yest. \(vm.metrics.dictationsYesterday.formatted()))",
                     changePercent: vm.metrics.dictationsTodayChangePercent,
                     changeHint: "vs. the same time a week ago")
            statCard(value: "\(vm.metrics.wpm7d)", label: "wpm · 7d",
                     changePercent: vm.metrics.wpm7dChangePercent,
                     changeHint: "vs. the same 7 days a week ago")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func statCard(value: String, label: String, detail: String? = nil,
                          changePercent: Int? = nil, changeHint: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(PTT.textPrimary(scheme))
                if let p = changePercent {
                    Text(p > 0 ? "+\(p)%" : p < 0 ? "\u{2212}\(-p)%" : "0%")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundColor(p > 0 ? PTT.trendUp(scheme) : p < 0 ? PTT.trendDown(scheme) : PTT.textMuted(scheme))
                        .help(changeHint)
                }
            }
            HStack(spacing: 3) {
                Text(label)
                    .pttMuted(PTT.textMuted(scheme))
                if let detail {
                    Text(detail)
                        .pttMuted(PTT.textCaption(scheme), level: .tertiary)
                }
            }
            .font(.system(size: 10, weight: .regular))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(PTT.cardBG(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(PTT.cardBorder(scheme), lineWidth: 1)
        )
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RECENT")
                .font(.system(size: 9, weight: .medium))
                .tracking(1.08)
                .pttMuted(PTT.textCaption(scheme))
                .padding(.bottom, 2)

            if vm.recent.isEmpty {
                Text("No transcriptions yet.")
                    .font(.system(size: 13))
                    .pttMuted(PTT.textMuted(scheme))
                    .padding(.vertical, 8)
            } else {
                ForEach(vm.recent) { r in
                    recentRow(r)
                }
                if vm.hasMore {
                    Button {
                        NotificationCenter.default.post(
                            name: .openPreferences,
                            object: "history"
                        )
                    } label: {
                        Text("See all in history")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(PTT.accentLink(scheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func recentRow(_ r: TranscriptionRecord) -> some View {
        Button {
            vm.copy(r)
        } label: {
            HStack(spacing: 10) {
                Text(r.cleanedText)
                    .font(.system(size: 13))
                    .foregroundColor(PTT.textBody(scheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if vm.copiedID == r.id {
                    Text("Copied")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(PTT.accentLink(scheme))
                } else {
                    copyIcon
                        .frame(width: 14, height: 14)
                        .pttMuted(PTT.textMuted(scheme))
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var copyIcon: some View {
        Image(systemName: "doc.on.doc")
            .font(.system(size: 11, weight: .regular))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                NotificationCenter.default.post(name: .openPreferences, object: nil)
            } label: {
                settingsIcon
                    .frame(width: 16, height: 16)
                    .foregroundColor(PTT.textPrimary(scheme))
            }
            .pttQuietButton(circle: true)
            .help("Preferences")

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 13))
                    .pttMuted(PTT.textMuted(scheme))
            }
            .pttQuietButton()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Update banner

    private func updateBanner(_ upd: ReleaseInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(PTT.accentLink(scheme))
            Text("v\(upd.version) available")
                .font(.system(size: 12))
                .foregroundColor(PTT.textBody(scheme))
            Spacer()
            Button("Download") { NSWorkspace.shared.open(upd.url) }
                .pttProminentButton()
                .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(PTT.accentLink(scheme).opacity(0.10))
    }
}

/// On macOS 26+ NSPopover draws Liquid Glass itself, so the content stays clear;
/// older systems get the blurred panel with a hairline.
private struct PopoverChrome: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
        } else {
            content
                .background(VisualEffectBackground(material: .popover))
                .background(PTT.popoverBG(scheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(PTT.surfaceBorder(scheme), lineWidth: 1)
                )
        }
    }
}

extension Notification.Name {
    static let openPreferences = Notification.Name("openPreferences")
}

/// Bundled SVG icons, loaded from disk once and shared by the popover and the
/// status item. Template images so they follow the menu bar / label tint.
enum BundledIcon {
    static let radio: NSImage? = load("radio")
    static let settings: NSImage? = load("settings")

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        return img
    }
}

@ViewBuilder
var radioIcon: some View {
    if let img = BundledIcon.radio {
        Image(nsImage: img).resizable().scaledToFit()
    } else {
        Image(systemName: "antenna.radiowaves.left.and.right").resizable().scaledToFit()
    }
}

@ViewBuilder
var settingsIcon: some View {
    if let img = BundledIcon.settings {
        Image(nsImage: img).resizable().scaledToFit()
    } else {
        Image(systemName: "gearshape").resizable().scaledToFit()
    }
}
