import Foundation
import WhisperKit

/// A load was asked for a model that isn't on disk. Loading never downloads: the
/// download runs from Preferences or onboarding (`ModelsViewModel.download`), with progress.
public struct ModelNotDownloadedError: LocalizedError {
    public let model: String
    public var errorDescription: String? { "\(model) is not downloaded" }
}

public final class ModelManager {
    public static let shared = ModelManager()
    private init() {}

    public func managedDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HoldSpeak/models")
    }

    public func downloadCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HoldSpeak/hf-cache")
    }

    public func macWhisperDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacWhisper/models/whisperkit/models/argmaxinc/whisperkit-coreml")
    }

    /// Default download base used by `swift-transformers` / WhisperKit when no
    /// `downloadBase` is supplied. Other WhisperKit-powered apps (and older
    /// builds of this app) drop CoreML models here, so we probe it to avoid
    /// re-downloading gigabytes the user already has.
    public func externalWhisperKitDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
    }

    /// A complete copy of `id`: HoldSpeak's own, else MacWhisper's, else the one in
    /// ~/Documents/huggingface. A partial folder anywhere is skipped, so it reads as
    /// "Not downloaded" and can be downloaded again rather than failing every load.
    public func locateModel(_ id: WhisperModelID) -> URL? {
        let candidates = [managedDirectory(), macWhisperDirectory(), externalWhisperKitDirectory()]
            .map { $0.appendingPathComponent(id.rawValue) }
        return ModelFolders.firstComplete(candidates) { WhisperSupport.modelExists(in: $0) }
    }

    /// Where FluidAudio-based apps (and FluidAudio's own CLI) keep Parakeet by default.
    public func externalFluidAudioDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FluidAudio/Models")
    }

    /// HoldSpeak's own folder for `id`; downloads go here.
    public func parakeetDirectory(_ id: ParakeetModelID) -> URL {
        managedDirectory().appendingPathComponent(id.folderName)
    }

    /// A complete copy of `id`: HoldSpeak's own, else another FluidAudio app's.
    /// nil where Parakeet can't run (macOS 13, Intel).
    public func locateParakeet(_ id: ParakeetModelID) -> URL? {
        guard ParakeetSupport.isAvailable else { return nil }
        return [parakeetDirectory(id), externalFluidAudioDirectory().appendingPathComponent(id.folderName)]
            .first { ParakeetSupport.modelExists(id, in: $0) }
    }

    public func locate(_ model: LocalModel) -> URL? {
        switch model {
        case .whisper(let id):  return locateModel(id)
        case .parakeet(let id): return locateParakeet(id)
        }
    }

    /// True when HoldSpeak itself has downloaded at least one model (older versions
    /// fetched one automatically on first launch).
    public func hasManagedModels() -> Bool {
        let items = try? FileManager.default.contentsOfDirectory(atPath: managedDirectory().path)
        return items?.contains { !$0.hasPrefix(".") } == true
    }

    /// Bytes on disk in the folders HoldSpeak downloads into. Models found in
    /// MacWhisper's, FluidAudio's or ~/Documents' folders belong to other apps and are not counted.
    public func managedBytes() -> Int64 {
        [managedDirectory(), downloadCacheDirectory()].reduce(0) { $0 + Self.size(of: $1) }
    }

    /// Deletes everything HoldSpeak downloaded; other apps' models are left alone.
    public func deleteManagedModels() throws {
        let fm = FileManager.default
        for dir in [managedDirectory(), downloadCacheDirectory()] where fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
    }

    private static func size(of dir: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// Downloads in flight, one per model. `ModelsViewModel` watches it (`onChange`), so
    /// Preferences and onboarding show a download whoever started it.
    @MainActor public let downloads = SingleFlight<LocalModel, URL>()

    /// Downloads `model` into HoldSpeak's folder. A second call for a model that is
    /// already downloading joins that download instead of writing the same files again.
    /// `progress` is called on main.
    @MainActor
    public func download(_ model: LocalModel,
                         progress: @escaping (Double) -> Void) async throws -> URL {
        try await downloads.run(model, progress: progress) { [self] report in
            try await fetch(model, progress: report)
        }
    }

    @MainActor
    private func fetch(_ model: LocalModel,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        switch model {
        case .whisper(let id):
            return try await fetchWhisper(id, progress: progress)
        case .parakeet(let id):
            guard let engine = ParakeetLoader.engine() else { throw ParakeetError.unavailable }
            let dir = parakeetDirectory(id)
            try FileManager.default.createDirectory(at: managedDirectory(), withIntermediateDirectories: true)
            try await engine.download(model: id.rawValue, to: dir.path, progress: progress)
            guard ParakeetSupport.modelExists(id, in: dir) else { throw ModelInstallError.incomplete }
            return dir
        }
    }

    private func fetchWhisper(_ id: WhisperModelID,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: managedDirectory(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloadCacheDirectory(), withIntermediateDirectories: true)
        let downloaded = try await WhisperKit.download(
            variant: id.rawValue,
            downloadBase: downloadCacheDirectory(),
            from: "argmaxinc/whisperkit-coreml",
            progressCallback: { p in progress(p.fractionCompleted) }
        )
        // Checked before it replaces anything: a cut-off download never takes the place
        // of a complete model.
        return try ModelFolders.install(downloaded, at: managedDirectory().appendingPathComponent(id.rawValue),
                                        isComplete: { WhisperSupport.modelExists(in: $0) })
    }
}
