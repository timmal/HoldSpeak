import AVFoundation
import Combine
import WhisperKit

@MainActor
public final class TranscriptionEngine: ObservableObject {
    @Published public private(set) var partialText: String = ""
    @Published public private(set) var isLoading: Bool = false

    private var kit: WhisperKit?
    private var currentModelID: WhisperModelID?
    private var accumulated: [Float] = []
    private var streaming = false

    private let initialPrompt =
        "Смешанная русско-английская речь. Сохраняй английские термины в оригинале: meeting, deadline, pull request."

    public init() {}

    public func preload(model: WhisperModelID) async throws {
        if currentModelID == model, kit != nil { return }
        isLoading = true
        defer { isLoading = false }
        let url: URL
        if let local = ModelManager.shared.locateModel(model) {
            url = local
        } else {
            url = try await ModelManager.shared.download(model) { _ in }
        }
        let config = WhisperKitConfig(modelFolder: url.path,
                                      verbose: false,
                                      logLevel: .error,
                                      download: false)
        kit = try await WhisperKit(config)
        currentModelID = model
    }

    public func beginStream() {
        accumulated.removeAll(keepingCapacity: true)
        partialText = ""
    }

    public func feed(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        accumulated.append(contentsOf: UnsafeBufferPointer(start: ch, count: count))
        Task { await self.runStreamingPass() }
    }

    private func runStreamingPass() async {
        guard !streaming, let kit else { return }
        streaming = true
        defer { streaming = false }
        let snapshot = accumulated
        let options = makeOptions()
        do {
            let results: [TranscriptionResult] = try await kit.transcribe(audioArray: snapshot, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { self.partialText = text }
        } catch {
            NSLog("TranscriptionEngine streaming error: \(error)")
        }
    }

    public func finalize() async -> (text: String, language: String?, durationMs: Int)? {
        guard let kit, !accumulated.isEmpty else { return nil }
        let samples = accumulated
        let durationMs = Int(Double(samples.count) / 16.0)   // 16 samples/ms at 16 kHz
        let options = makeOptions()
        do {
            let results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let lang = results.first?.language
            if text.isEmpty { return nil }
            return (text, lang, durationMs)
        } catch {
            NSLog("TranscriptionEngine finalize error: \(error)")
            return nil
        }
    }

    private func makeOptions() -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: nil,
            temperature: 0.0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
    }
}
