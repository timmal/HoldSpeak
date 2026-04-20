import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TerminologyPreferencesView: View {
    @ObservedObject var store: TerminologyStore = .shared
    @Environment(\.colorScheme) private var scheme

    @State private var selectedID: UUID?
    @State private var editing: TerminologyEntry?
    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            footer
            searchField

            if store.entries.isEmpty {
                emptyState
            } else if filteredEntries.isEmpty {
                noMatchesState
            } else {
                list
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
                Text("Canonical forms replace the listed variants in transcripts, and bias Whisper toward your terms.")
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
            StyledDropdown(selection: binding, width: Self.languagePickerWidth, current: currentLabel) {
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
                }.buttonStyle(.plain)
            } else {
                Text("No default dictionary is bundled for this language — add terms manually.")
                    .font(.system(size: 11))
                    .foregroundColor(PTT.textSoft(scheme))
            }
        }
        .padding(.vertical, 8)
    }

    private var list: some View {
        LazyVStack(spacing: 6) {
            ForEach(filteredEntries) { entry in
                row(entry)
            }
        }
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
        .background(RoundedRectangle(cornerRadius: 8).fill(PTT.fieldBG(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PTT.fieldBorder(scheme), lineWidth: 1))
    }

    private var noMatchesState: some View {
        Text("No terms match “\(searchText)”.")
            .font(.system(size: 12))
            .foregroundColor(PTT.textSoft(scheme))
            .padding(.vertical, 8)
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
            }.buttonStyle(.plain)

            Button { confirmLoadDefaults() } label: {
                pillText("Load defaults…")
            }.buttonStyle(.plain)

            Spacer()

            Button { importJSON() } label: {
                pillText("Import…")
            }.buttonStyle(.plain)

            Button { exportJSON() } label: {
                pillText("Export…")
            }.buttonStyle(.plain)
        }
        .padding(.bottom, 4)
    }

    private func pillText(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(PTT.textPrimary(scheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(PTT.buttonBG(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PTT.fieldBorder(scheme), lineWidth: 1))
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
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([TerminologyEntry].self, from: data)
        else { return }
        store.replaceAll(entries)
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
