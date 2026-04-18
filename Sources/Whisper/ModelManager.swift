import Foundation
import WhisperKit

public final class ModelManager {
    public static let shared = ModelManager()
    private init() {}

    public func managedDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("push-to-talk/models")
    }

    public func macWhisperDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacWhisper/models/whisperkit/models/argmaxinc/whisperkit-coreml")
    }

    public func locateModel(_ id: WhisperModelID) -> URL? {
        let fm = FileManager.default
        let managed = managedDirectory().appendingPathComponent(id.rawValue)
        if fm.fileExists(atPath: managed.path) { return managed }
        let fallback = macWhisperDirectory().appendingPathComponent(id.rawValue)
        if fm.fileExists(atPath: fallback.path) { return fallback }
        return nil
    }

    public func download(_ id: WhisperModelID,
                         progress: @escaping (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: managedDirectory(), withIntermediateDirectories: true)
        let downloaded = try await WhisperKit.download(
            variant: id.rawValue,
            from: "argmaxinc/whisperkit-coreml",
            progressCallback: { p in progress(p.fractionCompleted) }
        )
        let dst = managedDirectory().appendingPathComponent(id.rawValue)
        if downloaded.path != dst.path {
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.moveItem(at: downloaded, to: dst)
            if !FileManager.default.fileExists(atPath: dst.path) { return downloaded }
        }
        return dst
    }
}
