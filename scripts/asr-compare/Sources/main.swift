// asr-compare — developer-only benchmark of HoldSpeak's local engines.
//
// Runs every clip of clips.tsv through each engine given with --engine and prints,
// per clip: processing latency (all audio is already there, so this is the time
// from "recording stopped" to "text ready"), word error rate against the text `say`
// read, and the transcript. Model load (including Core ML compilation on a cold
// cache) and the first inference are reported separately.
//
//   swift run -c release asr-compare --engine whisper --engine parakeet
//
// Engines:
//   whisper[:<variant>]   WhisperKit, decoded the way HoldSpeak does it (default
//                         variant openai_whisper-large-v3-v20240930, the app default)
//   parakeet[:<lang>]     FluidAudio Parakeet Ultra; <lang> (e.g. ru) turns on
//                         FluidAudio's script filter for that language
import AVFoundation
import Darwin
import FluidAudio
import Foundation
import WhisperKit

// MARK: - Arguments

struct Options {
    var engines: [String] = []
    var runs = 3
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    var only: Set<String> = []
    var parakeetDir: URL?
    var whisperDir: URL?
    var markdown: URL?
}

func parseOptions() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let a = args.next() {
        switch a {
        case "--engine": o.engines.append(args.next()!)
        case "--runs": o.runs = Int(args.next()!)!
        case "--clip": o.only.insert(args.next()!)
        case "--parakeet-dir": o.parakeetDir = URL(fileURLWithPath: args.next()!)
        case "--whisper-dir": o.whisperDir = URL(fileURLWithPath: args.next()!)
        case "--markdown": o.markdown = URL(fileURLWithPath: args.next()!)
        default:
            FileHandle.standardError.write("unknown argument \(a)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    if o.engines.isEmpty { o.engines = ["whisper", "parakeet"] }
    return o
}

// MARK: - Clips

struct Clip {
    let id: String
    let reference: String
    let samples: [Float]
    var seconds: Double { Double(samples.count) / 16_000 }
}

func loadClips(_ o: Options) throws -> [Clip] {
    let tsv = try String(contentsOf: o.root.appendingPathComponent("clips.tsv"), encoding: .utf8)
    return try tsv.split(separator: "\n").compactMap { line -> Clip? in
        guard !line.hasPrefix("#") else { return nil }
        let cols = line.split(separator: "\t", maxSplits: 2).map(String.init)
        guard cols.count == 3, o.only.isEmpty || o.only.contains(cols[0]) else { return nil }
        let url = o.root.appendingPathComponent("audio/\(cols[0]).wav")
        return Clip(id: cols[0], reference: cols[2], samples: try readWav(url))
    }
}

/// 16 kHz mono float samples, as HoldSpeak hands them to the engines.
func readWav(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    precondition(format.sampleRate == 16_000 && format.channelCount == 1, "\(url.lastPathComponent): need 16 kHz mono")
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

// MARK: - Measuring

func seconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// Physical footprint (what Activity Monitor shows as Memory) and resident size
/// (also counts memory-mapped model files), in MB. Neither sees memory the Neural
/// Engine / GPU drivers hold on the process's behalf.
struct Memory {
    let footprint: Double
    let resident: Double
}

func memoryMB() -> Memory {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return Memory(footprint: -1, resident: -1) }
    return Memory(footprint: Double(info.phys_footprint) / 1_048_576, resident: Double(info.resident_size) / 1_048_576)
}

func directorySizeMB(_ url: URL) -> Double {
    guard let walker = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
    var total = 0
    for case let file as URL in walker {
        let v = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        if v?.isRegularFile == true { total += v?.totalFileAllocatedSize ?? 0 }
    }
    return Double(total) / 1_048_576
}

/// Word error rate after lowercasing, ё→е and dropping punctuation.
func wer(reference: String, hypothesis: String) -> Double {
    func words(_ s: String) -> [String] {
        let folded = s.lowercased().replacingOccurrences(of: "ё", with: "е")
        let kept = folded.unicodeScalars.map { CharacterSet.letters.union(.decimalDigits).contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").map(String.init)
    }
    let r = words(reference), h = words(hypothesis)
    guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
    var prev = Array(0...h.count)
    for i in 1...r.count {
        var cur = [i] + Array(repeating: 0, count: h.count)
        for j in 1...max(h.count, 1) where j <= h.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return Double(prev[h.count]) / Double(r.count)
}

// MARK: - Engines

protocol Engine: AnyObject {
    var name: String { get }
    /// Folder the model was loaded from, for its size on disk.
    var modelFolder: URL? { get }
    /// Fetches the model if it isn't on disk (not timed as load).
    func download() async throws
    func load() async throws
    func transcribe(_ samples: [Float]) async throws -> String
}

let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let holdSpeakModels = appSupport.appendingPathComponent("HoldSpeak/models")

/// Mirrors HoldSpeak's WhisperTranscriber: pad short clips, pick the language among
/// the user's preferred ones (auto mode), greedy decoding with temperature fallback.
final class WhisperEngine: Engine {
    let variant: String
    var kit: WhisperKit?
    var modelFolder: URL?
    var name: String { "Whisper \(variant.replacingOccurrences(of: "openai_whisper-", with: ""))" }

    let explicitDir: URL?
    init(variant: String, dir: URL?) { self.variant = variant; explicitDir = dir }

    static let whisperCodes: Set<String> = ["en", "ru", "uk", "de", "fr", "es", "it", "pt", "pl", "nl"]
    let preferred: [String] = {
        let codes = Locale.preferredLanguages.map { String($0.prefix(2)).lowercased() }.filter { whisperCodes.contains($0) }
        let unique = NSOrderedSet(array: codes).array as? [String] ?? []
        return unique.isEmpty ? ["en"] : unique
    }()

    func locate() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return [
            holdSpeakModels.appendingPathComponent(variant),
            appSupport.appendingPathComponent("MacWhisper/models/whisperkit/models/argmaxinc/whisperkit-coreml/\(variant)"),
            docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(variant)"),
        ].first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func download() async throws {
        var folder = explicitDir ?? locate()
        if folder == nil {
            let cache = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".cache")
            print("  downloading \(variant) into \(cache.path)…")
            folder = try await WhisperKit.download(variant: variant, downloadBase: cache, from: "argmaxinc/whisperkit-coreml")
        }
        modelFolder = folder
    }

    func load() async throws {
        kit = try await WhisperKit(WhisperKitConfig(modelFolder: modelFolder!.path, verbose: false, logLevel: .error, download: false))
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let kit = kit!
        var audio = samples
        if audio.count < 32_000 {
            let deficit = 32_000 - audio.count
            audio = Array(repeating: 0, count: deficit / 2) + audio + Array(repeating: 0, count: deficit - deficit / 2)
        }
        var language: String?
        let detection = try await kit.detectLangauge(audioArray: audio)
        if preferred.count < 2 {
            language = detection.language
        } else {
            let ranked = preferred.compactMap { c in detection.langProbs[c].map { (c, $0) } }.sorted { $0.1 > $1.1 }
            language = ranked.first?.0 ?? preferred[0]
            if ranked.count >= 2, ranked[0].1 - ranked[1].1 < 0.25, ranked[1].1 > 0.15 { language = nil }
        }
        let options = DecodingOptions(
            verbose: false, task: .transcribe, language: language,
            temperature: 0, temperatureIncrementOnFallback: 0.2, temperatureFallbackCount: 2,
            usePrefillPrompt: true, detectLanguage: language == nil,
            skipSpecialTokens: true, withoutTimestamps: true, suppressBlank: false,
            compressionRatioThreshold: 2.4, logProbThreshold: -1.5, noSpeechThreshold: nil)
        let results = try await kit.transcribe(audioArray: audio, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

final class ParakeetEngine: Engine {
    let hint: Language?
    let dir: URL
    var manager: AsrManager?
    var modelFolder: URL? { dir }
    var name: String { "Parakeet Ultra" + (hint.map { " (script \($0.rawValue))" } ?? "") }

    init(hint: Language?, dir: URL?) {
        self.hint = hint
        self.dir = dir ?? holdSpeakModels.appendingPathComponent("parakeet-ultra")
    }

    func download() async throws {
        if !AsrModels.modelsExist(at: dir, version: .ultra) {
            print("  downloading Parakeet Ultra into \(dir.path)…")
            let t0 = seconds()
            try await AsrModels.download(to: dir, version: .ultra) { p in
                if Int(p.fractionCompleted * 100) % 10 == 0 { print("    \(Int(p.fractionCompleted * 100))%") }
            }
            print(String(format: "  download took %.0f s", seconds() - t0))
        }
    }

    func load() async throws {
        let models = try await AsrModels.load(from: dir, version: .ultra)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let manager = manager!
        var audio = samples
        if audio.count < 8_000 { audio += Array(repeating: 0, count: 8_000 - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(audio, decoderState: &state, language: hint).text
    }
}

func makeEngine(_ spec: String, _ o: Options) -> Engine {
    let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
    switch parts[0] {
    case "whisper": return WhisperEngine(variant: parts.count > 1 ? parts[1] : "openai_whisper-large-v3-v20240930", dir: o.whisperDir)
    case "parakeet": return ParakeetEngine(hint: parts.count > 1 ? Language(rawValue: parts[1]) : nil, dir: o.parakeetDir)
    default: fatalError("unknown engine \(spec)")
    }
}

// MARK: - Run

struct Row {
    let clip: Clip
    let firstMs: Double
    let medianMs: Double
    let wer: Double
    let text: String
}

let options = parseOptions()
let clips = try loadClips(options)
var report = ""

for spec in options.engines {
    let engine = makeEngine(spec, options)
    print("\n== \(engine.name)")
    try await engine.download()
    let memBefore = memoryMB()
    let t0 = seconds()
    try await engine.load()
    let loadS = seconds() - t0
    let memLoaded = memoryMB()
    let disk = engine.modelFolder.map(directorySizeMB) ?? 0
    print(String(format: "  load %.2f s, model on disk %.0f MB, memory before load %.0f MB footprint / %.0f MB resident, after %.0f / %.0f",
                 loadS, disk, memBefore.footprint, memBefore.resident, memLoaded.footprint, memLoaded.resident))

    var rows: [Row] = []
    var peak = memLoaded
    for clip in clips {
        let f0 = seconds()
        _ = try await engine.transcribe(clip.samples)
        let first = (seconds() - f0) * 1000
        var times: [Double] = []
        var text = ""
        for _ in 0..<options.runs {
            let s = seconds()
            text = try await engine.transcribe(clip.samples)
            times.append((seconds() - s) * 1000)
            let now = memoryMB()
            peak = Memory(footprint: max(peak.footprint, now.footprint), resident: max(peak.resident, now.resident))
        }
        let median = times.sorted()[times.count / 2]
        let row = Row(clip: clip, firstMs: first, medianMs: median, wer: wer(reference: clip.reference, hypothesis: text), text: text)
        rows.append(row)
        print(String(format: "  %-12@ %5.1fs  first %5.0f ms  median %5.0f ms  WER %4.1f%%  %@",
                     clip.id as NSString, clip.seconds, first, median, row.wer * 100, text as NSString))
    }
    let meanWer = rows.map(\.wer).reduce(0, +) / Double(max(rows.count, 1))
    print(String(format: "  mean WER %.1f%%, peak %.0f MB footprint / %.0f MB resident", meanWer * 100, peak.footprint, peak.resident))

    report += "\n### \(engine.name)\n\n"
    report += String(format: "Load %.2f s · model on disk %.0f MB · process memory (footprint / resident) %.0f / %.0f MB before load, %.0f / %.0f MB after, peak %.0f / %.0f MB · mean WER %.1f %%\n\n",
                     loadS, disk, memBefore.footprint, memBefore.resident, memLoaded.footprint, memLoaded.resident,
                     peak.footprint, peak.resident, meanWer * 100)
    report += "| Clip | Audio | First run | Median of \(options.runs) | WER | Transcript |\n|---|---:|---:|---:|---:|---|\n"
    for r in rows {
        report += String(format: "| %@ | %.1f s | %.0f ms | %.0f ms | %.0f %% | %@ |\n",
                         r.clip.id as NSString, r.clip.seconds, r.firstMs, r.medianMs, r.wer * 100,
                         r.text.replacingOccurrences(of: "|", with: "\\|") as NSString)
    }
}

if let md = options.markdown {
    try report.write(to: md, atomically: true, encoding: .utf8)
    print("\nwrote \(md.path)")
}
