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
    private var terminologyObserver: NSObjectProtocol?

    private let baseInitialPrompt =
        "Смешанная русско-английская речь. Сохраняй английские термины в оригинале: meeting, deadline, pull request."

    // Tuning constants (exposed as `private static` for easy adjustment).
    private static let codeSwitchDeltaThreshold: Float = 0.25
    private static let codeSwitchMinProb: Float = 0.15
    private static let vadWindowSamples: Int = 480        // 30 ms at 16 kHz
    private static let vadFloor: Float = 0.002
    private static let vadRelative: Float = 0.10          // threshold = max(floor, relative * peak)
    private static let vadPaddingMs: Int = 250
    private static let vadMinDurationMs: Int = 150
    private static let vadMaxSilenceFraction: Float = 0.98
    private static let promptTokenBudget: Int = 60

    /// When true, the base + terminology prompt is passed to Whisper's decoder as
    /// `promptTokens`. This biases the model toward those terms but also disables
    /// WhisperKit's prefill KV-cache path (see TextDecoder.swift in WhisperKit), which
    /// in our tests caused intermittent empty/corrupted results. Terminology replacement
    /// still runs unconditionally as post-processing in TextCleaner.
    private static let usePromptBiasing = false

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

    public init() {
        terminologyObserver = NotificationCenter.default.addObserver(
            forName: .terminologyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildPromptTokens()
            }
        }
    }

    deinit {
        if let obs = terminologyObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

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
        rebuildPromptTokens()
    }

    private func rebuildPromptTokens() {
        guard kit != nil else { return }
        let hint = TerminologyStore.shared.promptHint()
        let fullPrompt = hint.isEmpty
            ? baseInitialPrompt
            : baseInitialPrompt + " Термины: " + hint + "."
        promptTokens = tokenizePrompt(fullPrompt, budget: Self.promptTokenBudget)
    }

    private func tokenizePrompt(_ prompt: String, budget: Int) -> [Int]? {
        guard let tokenizer = kit?.tokenizer else { return nil }
        let encoded = tokenizer.encode(text: " " + prompt)
        if encoded.isEmpty { return nil }
        if encoded.count <= budget { return encoded }
        pttLog("TranscriptionEngine: prompt truncated \(encoded.count) → \(budget) tokens")
        return Array(encoded.prefix(budget))
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
        let options = makeOptions(streaming: true)
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
        let rawMs = Int(Double(accumulated.count) / 16.0)
        guard let trimmed = trimSilence(accumulated) else {
            pttLog("finalize: VAD dropped buffer (raw=\(rawMs)ms)")
            return nil
        }
        let durationMs = Int(Double(trimmed.count) / 16.0)
        pttLog("finalize: VAD raw=\(rawMs)ms → trimmed=\(durationMs)ms")
        let isAuto = PreferencesStore.shared.primaryLanguage == .auto
        let preferred = Self.userPreferredLanguages()
        do {
            let override = try await chooseLanguage(kit: kit, samples: trimmed, isAuto: isAuto, preferred: preferred)
            let results = try await kit.transcribe(audioArray: trimmed, decodeOptions: makeOptions(override: override))
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let lang = results.first?.language
            pttLog("finalize: text=\"\(text)\" lang=\(lang ?? "?") override=\(override ?? "nil") dur=\(durationMs)ms")
            if text.isEmpty { return nil }
            return (text, lang, durationMs)
        } catch {
            pttLog("finalize error: \(error)")
            return nil
        }
    }

    private func chooseLanguage(kit: WhisperKit, samples: [Float], isAuto: Bool, preferred: [String]) async throws -> String? {
        if !isAuto {
            return PreferencesStore.shared.primaryLanguage.whisperCode
        }
        guard preferred.count >= 2 else {
            return preferred.first
        }
        let detection = try await kit.detectLangauge(audioArray: samples)
        let ranked = preferred
            .compactMap { code -> (code: String, prob: Float)? in
                guard let p = detection.langProbs[code] else { return nil }
                return (code, p)
            }
            .sorted { $0.prob > $1.prob }
        guard let top1 = ranked.first else { return preferred[0] }
        if ranked.count >= 2 {
            let top2 = ranked[1]
            let delta = top1.prob - top2.prob
            pttLog("finalize detect: top1=\(top1.code):\(top1.prob) top2=\(top2.code):\(top2.prob) delta=\(delta)")
            if delta < Self.codeSwitchDeltaThreshold && top2.prob > Self.codeSwitchMinProb {
                return nil      // let Whisper switch languages per-segment
            }
        } else {
            pttLog("finalize detect: top1=\(top1.code):\(top1.prob) (only candidate in preferred)")
        }
        return top1.code
    }

    private func makeOptions(override: String? = nil, streaming: Bool = false) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: override ?? PreferencesStore.shared.primaryLanguage.whisperCode,
            temperature: 0.0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: streaming ? 0 : 5,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: Self.usePromptBiasing ? promptTokens : nil,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )
    }

    // MARK: - VAD

    /// Trim leading/trailing silence from the buffer and return `nil` if the result
    /// is too short or the input is almost entirely silent.
    private func trimSilence(_ samples: [Float]) -> [Float]? {
        let windowSize = Self.vadWindowSamples
        guard samples.count >= windowSize else { return nil }

        let windowCount = samples.count / windowSize
        var rms = [Float](); rms.reserveCapacity(windowCount)
        var peak: Float = 0
        for w in 0..<windowCount {
            let start = w * windowSize
            var sum: Float = 0
            for i in 0..<windowSize {
                let v = samples[start + i]
                sum += v * v
            }
            let r = (sum / Float(windowSize)).squareRoot()
            rms.append(r)
            if r > peak { peak = r }
        }

        let threshold = max(Self.vadFloor, Self.vadRelative * peak)
        var firstVoice = -1
        var lastVoice = -1
        var silentCount = 0
        for (i, r) in rms.enumerated() {
            if r > threshold {
                if firstVoice < 0 { firstVoice = i }
                lastVoice = i
            } else {
                silentCount += 1
            }
        }
        guard firstVoice >= 0 else { return nil }

        let silentFraction = Float(silentCount) / Float(windowCount)
        if silentFraction > Self.vadMaxSilenceFraction { return nil }

        let paddingWindows = (Self.vadPaddingMs * 16) / windowSize    // 16 samples per ms
        let startWindow = max(0, firstVoice - paddingWindows)
        let endWindow = min(windowCount - 1, lastVoice + paddingWindows)

        let startSample = startWindow * windowSize
        let endSample = min(samples.count, (endWindow + 1) * windowSize)
        let durationMs = (endSample - startSample) / 16
        if durationMs < Self.vadMinDurationMs { return nil }

        return Array(samples[startSample..<endSample])
    }
}
