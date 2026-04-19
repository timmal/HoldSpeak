import Foundation
import Combine

public struct TerminologyEntry: Codable, Identifiable, Hashable {
    public var id: UUID
    public var canonical: String
    public var variants: [String]
    public var caseSensitive: Bool

    public init(id: UUID = UUID(), canonical: String, variants: [String], caseSensitive: Bool = false) {
        self.id = id
        self.canonical = canonical
        self.variants = variants
        self.caseSensitive = caseSensitive
    }
}

public extension Notification.Name {
    static let terminologyChanged = Notification.Name("PushToTalk.terminologyChanged")
}

@MainActor
public final class TerminologyStore: ObservableObject {
    public enum MergeStrategy { case skipExisting, replaceAll }

    public static let shared = TerminologyStore()

    @Published public private(set) var entries: [TerminologyEntry] = []

    private let fileURL: URL
    private let bundle: Bundle
    private let defaultsBundleResource: String

    public init(fileURL: URL = TerminologyStore.defaultURL(),
                bundle: Bundle = .main,
                defaultsBundleResource: String = "terminology-default") {
        self.fileURL = fileURL
        self.bundle = bundle
        self.defaultsBundleResource = defaultsBundleResource
        bootstrap()
    }

    public nonisolated static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("push-to-talk/terminology.json")
    }

    // MARK: - Bootstrap

    private func bootstrap() {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: fileURL.path) {
            if let seed = bundle.url(forResource: defaultsBundleResource, withExtension: "json"),
               let data = try? Data(contentsOf: seed) {
                try? data.write(to: fileURL)
            } else {
                pttLog("TerminologyStore: no seed in bundle, starting empty")
            }
        }
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []
            return
        }
        do {
            let decoded = try JSONDecoder().decode([TerminologyEntry].self, from: data)
            entries = decoded
        } catch {
            pttLog("TerminologyStore: decode error: \(error)")
            entries = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            pttLog("TerminologyStore: save error: \(error)")
        }
        NotificationCenter.default.post(name: .terminologyChanged, object: nil)
    }

    // MARK: - Mutations

    public func add(_ entry: TerminologyEntry) {
        entries.append(entry)
        save()
    }

    public func update(_ entry: TerminologyEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
        save()
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    public func replaceAll(_ newEntries: [TerminologyEntry]) {
        entries = newEntries
        save()
    }

    public func loadDefaults(mergeStrategy: MergeStrategy) {
        guard let seed = bundle.url(forResource: defaultsBundleResource, withExtension: "json"),
              let data = try? Data(contentsOf: seed),
              let defaults = try? JSONDecoder().decode([TerminologyEntry].self, from: data)
        else {
            pttLog("TerminologyStore: loadDefaults — no bundle resource")
            return
        }
        switch mergeStrategy {
        case .replaceAll:
            entries = defaults
        case .skipExisting:
            let existing = Set(entries.map { $0.canonical.lowercased() })
            let additions = defaults.filter { !existing.contains($0.canonical.lowercased()) }
            entries.append(contentsOf: additions)
        }
        save()
    }

    // MARK: - Prompt hint

    /// Comma-joined canonical forms, truncated so that the result fits into roughly `maxChars` characters
    /// (rough proxy for ~200 WhisperKit tokens using ~4 chars/token). Final tokenizer-aware truncation
    /// lives in `TranscriptionEngine.tokenizePrompt`.
    public func promptHint(maxChars: Int = 800) -> String {
        var out = ""
        for entry in entries {
            let candidate = out.isEmpty ? entry.canonical : out + ", " + entry.canonical
            if candidate.count > maxChars { break }
            out = candidate
        }
        return out
    }
}

