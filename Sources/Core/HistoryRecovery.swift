import Foundation

/// A history database that can't be opened is set aside rather than deleted: the user
/// may want the old transcripts back, and the next launch must not fail on it again.
public enum HistoryRecovery {
    /// SQLite's companion files, named by appending these to the database's path.
    static let sidecarSuffixes = ["-wal", "-shm", "-journal"]

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// Renames `history.sqlite` to `history.sqlite.broken-<yyyyMMdd-HHmmss>` and each
    /// sidecar to that name plus its suffix, so the set still opens together if renamed
    /// back; an existing backup with the same stamp gets `-2`, `-3`… instead.
    /// Sidecars move first and the database last: a WAL left next to a fresh database
    /// would be replayed into it. Returns the new URLs in the order moved (empty when
    /// there was nothing on disk). Throws on the first move that fails.
    @discardableResult
    public static func moveAside(_ url: URL, date: Date = Date(),
                                 fileManager fm: FileManager = .default) throws -> [URL] {
        let dir = url.deletingLastPathComponent()
        let stem = "\(url.lastPathComponent).broken-\(stampFormatter.string(from: date))"
        var base = stem
        var n = 2
        while ([""] + sidecarSuffixes).contains(where: { fm.fileExists(atPath: dir.appendingPathComponent(base + $0).path) }) {
            base = "\(stem)-\(n)"
            n += 1
        }
        var moved: [URL] = []
        for suffix in sidecarSuffixes + [""] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let target = dir.appendingPathComponent(base + suffix)
            try fm.moveItem(at: source, to: target)
            moved.append(target)
        }
        return moved
    }
}
