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
    private var promptTokens: [Int]?

    private let initialPrompt =
        "Смешанная русско-английская речь. Сохраняй английские термины в оригинале: meeting, deadline, pull request."

    private static let whisperCodes: Set<String> = [
        "en","zh","de","es","ru","ko","fr","ja","pt","tr","pl","ca","nl","ar","sv","it","id","hi","fi","vi","he","uk",
        "el","ms","cs","ro","da","hu","ta","no","th","ur","hr","bg","lt","la","mi","ml","cy","sk","te","fa","lv","bn",
        "sr","az","sl","kn","et","mk","br","eu","is","hy","ne","mn","bs","kk","sq","sw","gl","mr","pa","si","km",
        "sn","yo","so","af","oc","ka","be","tg","sd","gu","am","yi","lo","uz","fo","ht","ps","tk","nn","mt","sa",
        "lb","my","bo","tl","mg","as","tt","haw","ln","ha","ba","jw","su"
    ]

    private static func userPreferredLanguages() -> [String] {
        let codes = Locale.preferredLanguages.compactMap { tag -> String? in
            let two = String(tag.prefix(2)).lowercased()
            return whisperCodes.contains(two) ? two : nil
        }
        return codes.isEmpty ? ["en"] : Array(NSOrderedSet(array: codes)) as? [String] ?? ["en"]
    }

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
        promptTokens = tokenizePrompt(initialPrompt)
    }

    private func tokenizePrompt(_ prompt: String) -> [Int]? {
        guard let tokenizer = kit?.tokenizer else { return nil }
        let encoded = tokenizer.encode(text: " " + prompt)
        return encoded.isEmpty ? nil : encoded
    }

    public func beginStream() {
        accumulated.removeAll(keepingCapacity: true)
        partialText = ""
    }

    public var currentDurationMs: Int { Int(Double(accumulated.count) / 16.0) }

    /// Wait until any in-flight streaming pass completes, capped by `timeoutMs`.
    public func awaitStream(timeoutMs: Int) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while streaming && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
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
        guard let kit else { pttLog("finalize: kit is nil"); return nil }
        guard !accumulated.isEmpty else { pttLog("finalize: accumulated empty (no audio captured)"); return nil }
        let samples = accumulated
        let durationMs = Int(Double(samples.count) / 16.0)
        let isAuto = PreferencesStore.shared.primaryLanguage == .auto
        let preferred = Self.userPreferredLanguages()
        do {
            var override: String? = nil
            if isAuto, !preferred.isEmpty {
                let detection = try await kit.detectLangauge(audioArray: samples)
                let best = preferred
                    .compactMap { code -> (String, Float)? in
                        guard let p = detection.langProbs[code] else { return nil }
                        return (code, p)
                    }
                    .max { $0.1 < $1.1 }
                    .map { $0.0 }
                override = best ?? preferred[0]
                pttLog("finalize detect: top=\(detection.language) probs=\(detection.langProbs.filter { preferred.contains($0.key) }) chose=\(override ?? "?")")
            }
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: makeOptions(override: override))
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let lang = results.first?.language
            pttLog("finalize: text=\"\(text)\" lang=\(lang ?? "?")")
            if text.isEmpty { return nil }
            return (text, lang, durationMs)
        } catch {
            pttLog("finalize error: \(error)")
            return nil
        }
    }

    private func makeOptions(override: String? = nil) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: override ?? PreferencesStore.shared.primaryLanguage.whisperCode,
            temperature: 0.0,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: true
        )
    }
}
