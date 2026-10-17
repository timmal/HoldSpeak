import FluidAudio
import Foundation

/// FluidAudio's Parakeet behind `ParakeetEngineProtocol`. Lives in its own framework
/// (macOS 14) that the app loads at runtime; see ParakeetEngineProtocol.swift.
@objc(HSParakeetBridge)
public final class ParakeetBridge: NSObject, ParakeetEngineProtocol {
    private let state = State()

    public required override init() {
        super.init()
    }

    enum BridgeError: LocalizedError {
        case unknownModel(String)
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .unknownModel(let name): return "Unknown Parakeet model \(name)"
            case .notLoaded:              return "Parakeet model not loaded"
            }
        }
    }

    static func version(_ model: String) throws -> AsrModelVersion {
        switch model {
        case "parakeet-ultra": return .ultra
        default: throw BridgeError.unknownModel(model)
        }
    }

    /// FluidAudio resolves the folder as `directory/../<Repo.folderName>`; passing the
    /// folder itself keeps both sides pointing at the same place.
    private static func url(_ directory: String) -> URL {
        URL(fileURLWithPath: directory, isDirectory: true)
    }

    public func download(model: String, to directory: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let version = try Self.version(model)
        try await AsrModels.download(to: Self.url(directory), version: version) { p in
            progress(p.fractionCompleted)
        }
    }

    public func load(model: String, from directory: String) async throws {
        let version = try Self.version(model)
        let models = try await AsrModels.load(from: Self.url(directory), version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        await state.set(manager)
    }

    public func unload() async {
        await state.set(nil)
    }

    public func transcribe(samples: Data, language: String?) async throws -> String {
        guard let manager = await state.manager else { throw BridgeError.notLoaded }
        var audio = samples.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        // FluidAudio rejects clips under 0.3 s; pad with silence to 0.5 s.
        if audio.count < 8_000 { audio += [Float](repeating: 0, count: 8_000 - audio.count) }
        var decoder = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let hint = language.flatMap(Language.init(rawValue:))
        return try await manager.transcribe(audio, decoderState: &decoder, language: hint).text
    }

    /// The loaded manager, swapped atomically between load, unload and transcribe.
    private actor State {
        private(set) var manager: AsrManager?

        func set(_ new: AsrManager?) async {
            let old = manager
            manager = new
            await old?.cleanup()
        }
    }
}
