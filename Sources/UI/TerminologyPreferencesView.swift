import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TerminologyPreferencesView: View {
    @ObservedObject var store: TerminologyStore = .shared
    @Environment(\.colorScheme) private var scheme

    @State private var editing: TerminologyEntry?
    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool
    @State private var importExportWidth: CGFloat = 180

    private var filteredEntries: [TerminologyEntry] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.entries }
        let needle = q.lowercased()
        return store.entries.filter { entry in
            if entry.canonical.lowercased().contains(needle) { return true }
            return entry.variants.contains { $0.lowercased().contains(needle) }
        }
    }

    private static let languagePickerWidth: CGFloat = 180

    private struct ImportExportWidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            footer
            searchField
            if let notice = store.fileNotices[store.activeLanguage] {
                fileNoticeBanner(notice)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        Color.clear
                            .frame(height: 0)
                            .id("resultsTop")
                        if store.entries.isEmpty {
                            emptyState
                        } else if filteredEntries.isEmpty {
                            noMatchesState
                        } else {
                            ForEach(filteredEntries) { entry in
                                row(entry)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: searchText) { _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo("resultsTop", anchor: .top)
                    }
                }
            }
        }
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
        .onChange(of: store.activeLanguage) { _ in searchText = "" }
        .sheet(item: $editing) { entry in
            EditorSheet(entry: entry) { updated in
                if store.entries.contains(where: { $0.id == updated.id }) {
                    store.update(updated)
                } else {
                    store.add(updated)
                }
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Terminology")
                    .font(.system(size: 13))
                    .foregroundColor(PTT.textBody(scheme))
                Text("After transcription, each listed variant is replaced with its canonical form.")
                    .font(.system(size: 11))
                    .foregroundColor(PTT.textSoft(scheme))
            }
            Spacer(minLength: 0)
            languagePicker
        }
    }

    private var languagePicker: some View {
        let binding = Binding<String>(
            get: { store.activeLanguage },
            set: { store.setActiveLanguage($0) }
        )
        let languages = PrimaryLanguage.allCases.filter { $0 != .auto }
        let currentLabel = languages.first(where: { $0.rawValue == store.activeLanguage })?.label
            ?? store.activeLanguage.uppercased()
        return VStack(alignment: .trailing, spacing: 4) {
            Text("Last detected")
                .font(.system(size: 11))
                .foregroundColor(PTT.textMuted(scheme))
            StyledDropdown(selection: binding, width: importExportWidth, current: currentLabel) {
                ForEach(languages) { lang in
                    Text(lang.label).tag(lang.rawValue)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No terms yet for this language.")
                .font(.system(size: 13))
                .foregroundColor(PTT.textMuted(scheme))
            if store.hasSeed(for: store.activeLanguage) {
                Button { store.loadDefaults(mergeStrategy: .replaceAll) } label: {
                    pillText("Load default IT dictionary")
                }.pttButton()
            } else {
                Text("No default dictionary is bundled for this language — add terms manually.")
                    .font(.system(size: 11))
                    .foregroundColor(PTT.textSoft(scheme))
            }
        }
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(PTT.textMuted(scheme))
            TextField("Search terms", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(PTT.textBody(scheme))
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(PTT.textMuted(scheme))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .pttSurface(glass: Capsule(), fallback: RoundedRectangle(cornerRadius: 8),
                    fill: PTT.fieldBG(scheme), border: PTT.fieldBorder(scheme))
    }

    private var noMatchesState: some View {
        Text("No terms match “\(searchText)”.")
            .font(.system(size: 12))
            .foregroundColor(PTT.textSoft(scheme))
            .padding(.vertical, 8)
    }

    // MARK: - Damaged file notice

    private func fileNoticeBanner(_ notice: TerminologyFileNotice) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(PTT.trendDown(scheme))
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.noticeHeadline(notice))
                    .font(.system(size: 12))
                    .foregroundColor(PTT.textBody(scheme))
                Text(Self.noticeDetail(notice))
                    .font(.system(size: 11))
                    .foregroundColor(PTT.textSoft(scheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(notice.reason)
            }
            Spacer(minLength: 0)
            if let backup = notice.backupURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([backup]) } label: {
                    pillText("Show in Finder")
                }.pttButton()
            }
            Button { store.dismissFileNotice(for: notice.language) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundColor(PTT.textMuted(scheme))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(PTT.trendDown(scheme).opacity(0.10)))
    }

    private static func noticeHeadline(_ notice: TerminologyFileNotice) -> String {
        switch notice.kind {
        case .unreadable:
            return notice.backupURL == nil
                ? "Couldn't read \(notice.fileName)."
                : "Couldn't read \(notice.fileName), so this list was reset."
        case .partial(let skipped):
            return "Skipped \(countLabel(skipped, "entry", "entries")) in \(notice.fileName) that couldn't be read."
        }
    }

    private static func noticeDetail(_ notice: TerminologyFileNotice) -> String {
        let saved = notice.backupFileName.map { "Original saved as \($0)." } ?? "The file was left in place."
        switch notice.kind {
        case .unreadable: return "\(saved) \(notice.reason)"
        case .partial:    return saved
        }
    }

    private static func countLabel(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }

    private func row(_ entry: TerminologyEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.canonical)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(PTT.textBody(scheme))
                Text(entry.variants.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundColor(PTT.textSoft(scheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Button { editing = entry } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundColor(PTT.textMuted(scheme))
            }.buttonStyle(.plain)
            Button { store.remove(id: entry.id) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundColor(PTT.textMuted(scheme))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(PTT.cardBG(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PTT.surfaceBorder(scheme), lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { editing = TerminologyEntry(canonical: "", variants: []) } label: {
                pillText("Add term")
            }.pttButton()

            Button { confirmLoadDefaults() } label: {
                pillText("Load defaults…")
            }.pttButton()

            Spacer()

            HStack(spacing: 8) {
                Button { importJSON() } label: {
                    pillText("Import…")
                }.pttButton()

                Button { exportJSON() } label: {
                    pillText("Export…")
                }.pttButton()
            }
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: ImportExportWidthKey.self, value: g.size.width)
                }
            )
        }
        .onPreferenceChange(ImportExportWidthKey.self) { w in
            if w > 0 { importExportWidth = w }
        }
    }

    private func pillText(_ s: String) -> some View {
        Text(s)
    }

    // MARK: - Actions

    private func confirmLoadDefaults() {
        let alert = NSAlert()
        alert.messageText = "Load default IT dictionary?"
        alert.informativeText = "Merge adds missing entries. Replace discards your current list."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  store.loadDefaults(mergeStrategy: .skipExisting)
        case .alertSecondButtonReturn: store.loadDefaults(mergeStrategy: .replaceAll)
        default: break
        }
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.lastPathComponent

        let result: TerminologyDecodeResult
        do {
            result = try TerminologyStore.decodeLenient(Data(contentsOf: url))
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't import \(name)"
            alert.informativeText = TerminologyStore.describe(error)
            alert.runModal()
            return
        }

        let current = Self.countLabel(store.entries.count, "term", "terms")
        let incoming = Self.countLabel(result.entries.count, "term", "terms")
        let confirm = NSAlert()
        confirm.messageText = "Replace \(current) with \(incoming) from \(name)?"
        confirm.informativeText = result.skipped > 0
            ? "\(Self.countLabel(result.skipped, "entry", "entries")) couldn't be read and will be skipped."
            : "Your current list will be discarded."
        confirm.addButton(withTitle: "Replace")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        store.replaceAll(result.entries)
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "terminology.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(store.entries) {
            try? data.write(to: url)
        }
    }
}

private struct EditorSheet: View {
    @State var entry: TerminologyEntry
    let onSave: (TerminologyEntry) -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var variantsText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entry.canonical.isEmpty ? "New term" : "Edit term")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(PTT.textPrimary(scheme))

            VStack(alignment: .leading, spacing: 6) {
                Text("Canonical form")
                    .font(.system(size: 11))
                    .foregroundColor(PTT.textMuted(scheme))
                TextField("pull request", text: $entry.canonical)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Variants (one per line)")
                    .font(.system(size: 11))
                    .foregroundColor(PTT.textMuted(scheme))
                TextEditor(text: $variantsText)
                    .font(.system(size: 12))
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(PTT.fieldBorder(scheme), lineWidth: 1))
            }

            Toggle("Case-sensitive", isOn: $entry.caseSensitive)
                .toggleStyle(.switch)
                .controlSize(.small)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let variants = variantsText
                        .split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    var e = entry
                    e.variants = variants
                    e.canonical = e.canonical.trimmingCharacters(in: .whitespaces)
                    guard !e.canonical.isEmpty else { return }
                    onSave(e)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            variantsText = entry.variants.joined(separator: "\n")
        }
    }
}
