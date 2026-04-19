import SwiftUI
import AppKit

@MainActor
final class PopoverViewModel: ObservableObject {
    @Published var metrics: Metrics = .init(totalWords: 0, wpm7d: 0)
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
        metrics = (try? metricsEngine.current(now: Date())) ?? .init(totalWords: 0, wpm7d: 0)
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
        .background(VisualEffectBackground(material: .popover))
        .background(PTT.popoverBG(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(PTT.surfaceBorder(scheme), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            radioIcon.frame(width: 18, height: 18)
            Text("Push-to-Talk")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(PTT.textPrimary(scheme))
            Spacer()
            Text(hotkeyHint)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(PTT.textMuted(scheme))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var hotkeyHint: String { prefs.hotkey.label }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 10) {
            statCard(value: "\(vm.metrics.totalWords.formatted())", label: "total words")
            statCard(value: "\(vm.metrics.wpm7d)", label: "wpm · 7d")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(PTT.textPrimary(scheme))
            Text(label)
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(PTT.textMuted(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(PTT.cardBG(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(PTT.cardBorder(scheme), lineWidth: 1)
        )
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RECENT")
                .font(.system(size: 9, weight: .medium))
                .tracking(1.08)
                .foregroundColor(PTT.textCaption(scheme))
                .padding(.bottom, 2)

            if vm.recent.isEmpty {
                Text("No transcriptions yet.")
                    .font(.system(size: 13))
                    .foregroundColor(PTT.textMuted(scheme))
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
                        .foregroundColor(PTT.textMuted(scheme))
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
            .buttonStyle(.plain)
            .help("Preferences")

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 13))
                    .foregroundColor(PTT.textMuted(scheme))
            }
            .buttonStyle(.plain)
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
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(PTT.accentLink(scheme).opacity(0.10))
    }
}

extension Notification.Name {
    static let openPreferences = Notification.Name("openPreferences")
}

@ViewBuilder
var radioIcon: some View {
    if let url = Bundle.main.url(forResource: "radio", withExtension: "svg"),
       let nsimg = NSImage(contentsOf: url) {
        Image(nsImage: nsimg).resizable().scaledToFit()
    } else {
        Image(systemName: "antenna.radiowaves.left.and.right")
    }
}

@ViewBuilder
var settingsIcon: some View {
    if let url = Bundle.main.url(forResource: "settings", withExtension: "svg"),
       let nsimg = NSImage(contentsOf: url) {
        let templated: NSImage = {
            let copy = nsimg.copy() as! NSImage
            copy.isTemplate = true
            return copy
        }()
        Image(nsImage: templated).resizable().scaledToFit()
    } else {
        Image(systemName: "gearshape").resizable().scaledToFit()
    }
}
