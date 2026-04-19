import SwiftUI
import AppKit

@MainActor
final class PopoverViewModel: ObservableObject {
    @Published var metrics: Metrics = .init(totalWords: 0, wpm7d: 0)
    @Published var recent: [TranscriptionRecord] = []
    @Published var copiedID: Int64?

    private let store: HistoryStoring
    private let metricsEngine: MetricsComputing

    init(store: HistoryStoring, metricsEngine: MetricsComputing) {
        self.store = store
        self.metricsEngine = metricsEngine
    }

    func refresh() {
        metrics = (try? metricsEngine.current(now: Date())) ?? .init(totalWords: 0, wpm7d: 0)
        recent = (try? store.recent(limit: 10)) ?? []
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                radioIcon.frame(width: 18, height: 18)
                Text("Push-to-Talk").font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                VStack(alignment: .leading) {
                    Text("\(vm.metrics.totalWords)").font(.system(size: 22, weight: .semibold))
                    Text("total words").font(.caption).foregroundColor(.secondary)
                }
                VStack(alignment: .leading) {
                    Text("\(vm.metrics.wpm7d)").font(.system(size: 22, weight: .semibold))
                    Text("wpm (7d avg)").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(12)
            Divider()
            Text("RECENT")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            if vm.recent.isEmpty {
                Text("No transcriptions yet.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(vm.recent) { r in
                            Button { vm.copy(r) } label: {
                                HStack {
                                    Text(r.cleanedText)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                    if vm.copiedID == r.id {
                                        Text("Copied")
                                            .font(.caption)
                                            .foregroundColor(.accentColor)
                                    } else {
                                        Image(systemName: "doc.on.doc")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 240)
            }
            Divider()
            HStack {
                Button("Preferences…") {
                    NotificationCenter.default.post(name: .openPreferences, object: nil)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .padding(12)
            .buttonStyle(.borderless)
        }
        .frame(width: 320)
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
