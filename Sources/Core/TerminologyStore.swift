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
    static let terminologyChanged = Notification.Name("HoldSpeak.terminologyChanged")
}

/// A damaged `<lang>.json` the store found and set aside instead of overwriting.
public struct TerminologyFileNotice: Equatable {
    public enum Kind: Equatable {
        /// The file did not decode at all; the defaults (or an empty list) replaced it.
        case unreadable
        /// Some entries had no usable term and were dropped; the rest were kept.
        case partial(skipped: Int)
    }

    public let language: String
    public let kind: Kind
    /// Where the original bytes were moved. Nil if moving them failed (the file was then left alone).
    public let backupURL: URL?
    /// Why the file could not be read, in the decoder's words.
    public let reason: String

    public var fileName: String { "\(language).json" }
    public var backupFileName: String? { backupURL?.lastPathComponent }
}

/// What a lenient read of a terminology list produced.
public struct TerminologyDecodeResult: Equatable {
    public var entries: [TerminologyEntry]
    /// Entries dropped because they had no usable canonical term or a field of the wrong type.
    public var skipped: Int
    /// Entries kept with a missing `id`, `variants` or `caseSensitive` filled in.
    public var filledIn: Int
}

/// One array element, decoded without ever failing the whole list.
private struct LenientRow: Decodable {
    let entry: TerminologyEntry?
    let filledIn: Bool

    private enum Keys: String, CodingKey { case id, canonical, variants, caseSensitive }

    private enum Field<T> { case missing, value(T), invalid }

    init(from decoder: Decoder) {
        guard let c = try? decoder.container(keyedBy: Keys.self) else {
            entry = nil; filledIn = false; return
        }
        func field<T: Decodable>(_ type: T.Type, _ key: Keys) -> Field<T> {
            do {
                if let v = try c.decodeIfPresent(type, forKey: key) { return .value(v) }
                return .missing
            } catch {
                return .invalid
            }
        }

        guard case .value(let canonical) = field(String.self, .canonical),
              !canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { entry = nil; filledIn = false; return }

        var filled = false
        let variants: [String]
        switch field([String].self, .variants) {
        case .value(let v): variants = v
        case .missing:      variants = []; filled = true
        case .invalid:      entry = nil; filledIn = false; return
        }

        // An id is internal bookkeeping, so a malformed one is replaced rather than fatal.
        let id: UUID
        if case .value(let v) = field(UUID.self, .id) { id = v } else { id = UUID(); filled = true }

        // Same default as an entry created with "Add term".
        var e = TerminologyEntry(id: id, canonical: canonical, variants: variants)
        switch field(Bool.self, .caseSensitive) {
        case .value(let v): e.caseSensitive = v
        case .missing:      filled = true
        case .invalid:      entry = nil; filledIn = false; return
        }
        entry = e
        filledIn = filled
    }
}

@MainActor
public final class TerminologyStore: ObservableObject {
    public enum MergeStrategy { case skipExisting, replaceAll }

    /// Starts on `launchLanguage` and remembers the active language in the standard defaults.
    public static let shared: TerminologyStore = {
        let defaults = UserDefaults.standard
        let language = launchLanguage(
            primary: PreferencesStore.shared.primaryLanguage.whisperCode,
            persisted: defaults.string(forKey: activeLanguageKey),
            preferredLanguages: Locale.preferredLanguages,
            available: bundledLanguages(in: .main, prefix: "terminology-default"))
        return TerminologyStore(initialLanguage: language, languageDefaults: defaults)
    }()

    /// The active language, kept so that Auto starts on it next launch: engines that
    /// don't report a language (Gemini, gpt-4o-mini-transcribe) never switch it.
    public nonisolated static let activeLanguageKey = "terminologyLanguage"

    @Published public private(set) var entries: [TerminologyEntry] = []
    @Published public private(set) var activeLanguage: String
    /// Damaged files found on load, keyed by language. Cleared only by `dismissFileNotice(for:)`.
    @Published public private(set) var fileNotices: [String: TerminologyFileNotice] = [:]

    private var cache: [String: [TerminologyEntry]] = [:]

    private let directory: URL
    private let bundle: Bundle
    private let defaultsBundlePrefix: String
    /// Where the active language is remembered; nil remembers nothing.
    private let languageDefaults: UserDefaults?

    public init(directory: URL = TerminologyStore.defaultDirectory(),
                bundle: Bundle = .main,
                defaultsBundlePrefix: String = "terminology-default",
                legacyFlatFile: URL? = TerminologyStore.legacyFlatFile(),
                initialLanguage: String = "en",
                languageDefaults: UserDefaults? = nil) {
        self.directory = directory
        self.bundle = bundle
        self.defaultsBundlePrefix = defaultsBundlePrefix
        self.activeLanguage = initialLanguage
        self.languageDefaults = languageDefaults
        bootstrap(legacyFlatFile: legacyFlatFile)
        loadActive()
        rememberActiveLanguage()
    }

    /// The language the store starts on. An explicit primary language wins. On Auto:
    /// the language active when the app last ran; on a first launch, the first of the
    /// Mac's preferred languages that has a bundled list ("uk-UA" counts as "uk"); else English.
    public nonisolated static func launchLanguage(primary: String?, persisted: String?,
                                                  preferredLanguages: [String],
                                                  available: [String]) -> String {
        if let primary, !primary.isEmpty { return primary }
        if let persisted, !persisted.isEmpty { return persisted }
        for preferred in preferredLanguages {
            let code = preferred.split(whereSeparator: { $0 == "-" || $0 == "_" }).first
                .map { $0.lowercased() } ?? ""
            if available.contains(code) { return code }
        }
        return "en"
    }

    /// Languages with a `<prefix>-<lang>.json` list in the bundle, sorted.
    public nonisolated static func bundledLanguages(in bundle: Bundle, prefix: String) -> [String] {
        (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0.hasPrefix(prefix + "-") }
            .map { String($0.dropFirst(prefix.count + 1)) }
            .sorted()
    }

    public nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HoldSpeak/terminology")
    }

    public nonisolated static func legacyFlatFile() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HoldSpeak/terminology.json")
    }

    // MARK: - Bootstrap

    private func bootstrap(legacyFlatFile: URL?) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let legacy = legacyFlatFile, fm.fileExists(atPath: legacy.path) {
            let target = fileURL(for: "ru")
            if !fm.fileExists(atPath: target.path) {
                try? fm.moveItem(at: legacy, to: target)
                pttLog("TerminologyStore: migrated legacy terminology.json → terminology/ru.json")
            }
        }
    }

    private func fileURL(for language: String) -> URL {
        directory.appendingPathComponent("\(language).json")
    }

    private func seedURL(for language: String) -> URL? {
        bundle.url(forResource: "\(defaultsBundlePrefix)-\(language)", withExtension: "json")
    }

    public func hasSeed(for language: String) -> Bool { seedURL(for: language) != nil }

    // MARK: - Active language

    public func setActiveLanguage(_ code: String) {
        guard !code.isEmpty, code != activeLanguage else { return }
        activeLanguage = code
        loadActive()
        rememberActiveLanguage()
    }

    private func rememberActiveLanguage() {
        languageDefaults?.set(activeLanguage, forKey: Self.activeLanguageKey)
    }

    public func entries(for language: String) -> [TerminologyEntry] {
        if let cached = cache[language] { return cached }
        let loaded = load(language, writeSeedIfMissing: false)
        cache[language] = loaded
        return loaded
    }

    public func dismissFileNotice(for language: String) {
        fileNotices[language] = nil
    }

    private func loadActive() {
        let loaded = load(activeLanguage, writeSeedIfMissing: true)
        cache[activeLanguage] = loaded
        entries = loaded
    }

    private enum DiskState {
        case missing
        case decoded(TerminologyDecodeResult)
        case unreadable(reason: String)
    }

    private func readDisk(_ language: String) -> DiskState {
        let url = fileURL(for: language)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            return .decoded(try Self.decodeLenient(data))
        } catch {
            return .unreadable(reason: Self.describe(error))
        }
    }

    /// Decodes a terminology list the way a hand-edited file needs: a missing `id` gets a fresh
    /// one, a missing `caseSensitive` or `variants` gets the "Add term" default, unknown keys are
    /// ignored, and an entry without a usable canonical term is skipped and counted.
    /// Throws only when the data is not a JSON list at all.
    public nonisolated static func decodeLenient(_ data: Data) throws -> TerminologyDecodeResult {
        let rows = try JSONDecoder().decode([LenientRow].self, from: data)
        let kept = rows.compactMap(\.entry)
        return TerminologyDecodeResult(entries: kept,
                                       skipped: rows.count - kept.count,
                                       filledIn: rows.filter { $0.entry != nil && $0.filledIn }.count)
    }

    /// Reads a language's set. A missing file falls back to the seed; a file that exists but
    /// cannot be read is moved aside first, so the user's bytes are never overwritten.
    private func load(_ language: String, writeSeedIfMissing: Bool) -> [TerminologyEntry] {
        switch readDisk(language) {
        case .decoded(let result) where result.skipped > 0:
            // Rewriting would drop the skipped entries, so keep the original bytes first.
            let backup = moveAside(language, tag: "partial")
            let noun = result.skipped == 1 ? "entry" : "entries"
            fileNotices[language] = TerminologyFileNotice(
                language: language, kind: .partial(skipped: result.skipped),
                backupURL: try? backup.get(),
                reason: "Skipped \(result.skipped) \(noun) without a usable term.")
            switch backup {
            case .success(let url):
                writeToDisk(result.entries, language: language)
                pttLog("TerminologyStore: \(language).json skipped \(result.skipped) \(noun) → original kept as \(url.lastPathComponent)")
            case .failure(let error):
                pttLog("TerminologyStore: \(language).json skipped \(result.skipped) \(noun), could not keep the original, left as is: \(error)")
            }
            return result.entries
        case .decoded(let result):
            if result.filledIn > 0 {
                writeToDisk(result.entries, language: language)
                pttLog("TerminologyStore: \(language).json filled in missing fields on \(result.filledIn) entries")
            }
            return result.entries
        case .missing:
            return seed(language, write: writeSeedIfMissing)
        case .unreadable(let reason):
            let backup = moveAside(language, tag: "unreadable")
            let backupURL = try? backup.get()
            fileNotices[language] = TerminologyFileNotice(language: language, kind: .unreadable,
                                                          backupURL: backupURL, reason: reason)
            switch backup {
            case .success(let url):
                pttLog("TerminologyStore: \(language).json unreadable (\(reason)) → moved to \(url.lastPathComponent), using defaults")
                return seed(language, write: true)
            case .failure(let error):
                // Could not keep the original elsewhere, so leave it where it is and only seed in memory.
                pttLog("TerminologyStore: \(language).json unreadable (\(reason)), could not move it aside: \(error)")
                return seedEntries(for: language) ?? []
            }
        }
    }

    private func seed(_ language: String, write: Bool) -> [TerminologyEntry] {
        guard let seed = seedEntries(for: language) else { return [] }
        if write { writeToDisk(seed, language: language) }
        return seed
    }

    private static let backupStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// Renames `<lang>.json` to `<lang>.json.<tag>-<yyyyMMdd-HHmmss>` in the same folder.
    private func moveAside(_ language: String, tag: String) -> Result<URL, Error> {
        let fm = FileManager.default
        let base = "\(language).json.\(tag)-\(Self.backupStamp.string(from: Date()))"
        var target = directory.appendingPathComponent(base)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        do {
            try fm.moveItem(at: fileURL(for: language), to: target)
            return .success(target)
        } catch {
            return .failure(error)
        }
    }

    /// A short, human-readable reason for a decode failure ("Unexpected character 'o' around line 1, column 30.").
    public nonisolated static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .dataCorrupted(let ctx):
            if let underlying = ctx.underlyingError as NSError?,
               let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String {
                return detail
            }
            return ctx.debugDescription
        case .typeMismatch(_, let ctx) where ctx.codingPath.isEmpty:
            return "Expected a list of terms."
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .keyNotFound(_, let ctx):
            let path = ctx.codingPath.map { $0.intValue.map { "#\($0 + 1)" } ?? $0.stringValue }
            return path.isEmpty ? ctx.debugDescription : "\(path.joined(separator: " → ")): \(ctx.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private func seedEntries(for language: String) -> [TerminologyEntry]? {
        guard let url = seedURL(for: language),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([TerminologyEntry].self, from: data)
        else { return nil }
        return decoded
    }

    private func writeToDisk(_ entries: [TerminologyEntry], language: String) {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL(for: language), options: .atomic)
        } catch {
            pttLog("TerminologyStore: save error (\(language)): \(error)")
        }
    }

    // MARK: - Mutations on active set

    private func persistActive() {
        cache[activeLanguage] = entries
        writeToDisk(entries, language: activeLanguage)
        NotificationCenter.default.post(name: .terminologyChanged, object: nil)
    }

    public func add(_ entry: TerminologyEntry) {
        entries.append(entry)
        persistActive()
    }

    public func update(_ entry: TerminologyEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
        persistActive()
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persistActive()
    }

    public func replaceAll(_ newEntries: [TerminologyEntry]) {
        entries = newEntries
        persistActive()
    }

    public func loadDefaults(mergeStrategy: MergeStrategy) {
        guard let defaults = seedEntries(for: activeLanguage) else {
            pttLog("TerminologyStore: no seed for \(activeLanguage)")
            return
        }
        switch mergeStrategy {
        case .replaceAll:
            entries = defaults
        case .skipExisting:
            let existing = Set(entries.map { $0.canonical.lowercased() })
            entries.append(contentsOf: defaults.filter { !existing.contains($0.canonical.lowercased()) })
        }
        persistActive()
    }
}
