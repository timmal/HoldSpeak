import Foundation

/// NVIDIA Parakeet TDT models, run on this Mac through FluidAudio (Core ML, Neural Engine).
public enum ParakeetModelID: String, CaseIterable, Identifiable {
    /// moondream's post-training of Parakeet TDT 0.6B v3: 25 European languages,
    /// detected on its own. Raw value = the folder FluidAudio keeps it in (its
    /// `Repo.folderName`; the Hugging Face repo is FluidInference/parakeet-ultra-coreml).
    case ultra = "parakeet-ultra"

    public var id: String { rawValue }
    public var folderName: String { rawValue }

    /// The open Model dropdown: name, what it's good at, download size.
    public var label: String {
        switch self {
        case .ultra: return "\(shortLabel) — fastest · 25 European languages · \(downloadSize)"
        }
    }

    /// The model's name: closed dropdown, HUD, fallback hints.
    public var shortLabel: String {
        switch self {
        case .ultra: return "NVIDIA Parakeet Ultra"
        }
    }

    public var downloadSize: String {
        switch self {
        case .ultra: return "610 MB"
        }
    }

    /// What FluidAudio needs in the folder to load the model (`AsrModels.modelsExist`
    /// for the v3 family with the int8 encoder): compiled Core ML bundles and the vocabulary.
    public var requiredFiles: [String] {
        switch self {
        case .ultra:
            return ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
                    "JointDecisionv3.mlmodelc", "parakeet_vocab.json"]
        }
    }
}

public enum ParakeetSupport {
    /// FluidAudio needs macOS 14 and Apple Silicon. The app itself still runs on macOS 13,
    /// where Parakeet is hidden and Whisper is the only local engine.
    public static var isAvailable: Bool {
        #if arch(arm64)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0))
        #else
        return false
        #endif
    }

    /// True when `folder` holds a complete download of `model`.
    public static func modelExists(_ model: ParakeetModelID, in folder: URL,
                                   fileManager: FileManager = .default) -> Bool {
        model.requiredFiles.allSatisfy {
            fileManager.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }
}

public enum WhisperSupport {
    /// Compiled Core ML bundles `WhisperKit.loadModels` opens (WhisperKit 0.18.0,
    /// Core/WhisperKit.swift): it throws when any is missing. TextDecoderContextPrefill
    /// is optional there and not part of argmaxinc/whisperkit-coreml's turbo folder.
    public static let requiredBundles = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    /// What Core ML needs inside each compiled ML Program bundle; all three are in every
    /// bundle of the Hugging Face folder. A bundle without them is a cut-off download.
    public static let requiredBundleFiles = ["coremldata.bin", "model.mil", "weights/weight.bin"]

    /// Paths relative to the model folder.
    public static var requiredFiles: [String] {
        requiredBundles.flatMap { bundle in requiredBundleFiles.map { "\(bundle).mlmodelc/\($0)" } }
    }

    /// True when `folder` holds a complete Whisper model WhisperKit can load.
    public static func modelExists(in folder: URL, fileManager: FileManager = .default) -> Bool {
        requiredFiles.allSatisfy { fileManager.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }
}

public enum ModelInstallError: LocalizedError, Equatable {
    /// The download finished but the folder misses files a model needs.
    case incomplete

    public var errorDescription: String? { "The downloaded model is incomplete" }
}

/// Where models are looked up and how a finished download takes its place.
public enum ModelFolders {
    /// The first of `candidates` (in the caller's order of preference) that holds a
    /// complete model. A partial folder is skipped, so the model reads as not downloaded
    /// and can be downloaded again.
    public static func firstComplete(_ candidates: [URL], isComplete: (URL) -> Bool) -> URL? {
        candidates.first(where: isComplete)
    }

    /// Puts the finished download `downloaded` at `destination` and returns where the
    /// model is now. A complete download replaces whatever is there. An incomplete one is
    /// never moved in: a complete `destination` is kept, otherwise `.incomplete` is thrown
    /// and both folders stay as they were (the download cache resumes from its files).
    public static func install(_ downloaded: URL, at destination: URL,
                               isComplete: (URL) -> Bool,
                               fileManager fm: FileManager = .default) throws -> URL {
        if downloaded.standardizedFileURL.path == destination.standardizedFileURL.path {
            guard isComplete(destination) else { throw ModelInstallError.incomplete }
            return destination
        }
        guard isComplete(downloaded) else {
            if isComplete(destination) { return destination }
            throw ModelInstallError.incomplete
        }
        guard fm.fileExists(atPath: destination.path) else {
            try fm.moveItem(at: downloaded, to: destination)
            return destination
        }
        // Set the old folder aside first, so a failed move leaves it in place.
        let aside = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).replaced-\(UUID().uuidString)")
        try fm.moveItem(at: destination, to: aside)
        do {
            try fm.moveItem(at: downloaded, to: destination)
        } catch {
            try? fm.moveItem(at: aside, to: destination)
            throw error
        }
        try? fm.removeItem(at: aside)
        return destination
    }
}

/// A model that runs on this Mac. Cloud engines fall back to the local one picked last.
public enum LocalModel: Hashable {
    case whisper(WhisperModelID)
    case parakeet(ParakeetModelID)

    public var engineKind: TranscriptionEngineKind {
        switch self {
        case .whisper:  return .whisper
        case .parakeet: return .parakeet
        }
    }

    /// The engine's bare name, for logs; the UI names the model with `shortLabel`.
    public var engineName: String {
        switch self {
        case .whisper:  return "Whisper"
        case .parakeet: return "Parakeet"
        }
    }

    /// The model's name: "OpenAI Whisper Turbo", "NVIDIA Parakeet Ultra".
    public var shortLabel: String {
        switch self {
        case .whisper(let m):  return m.shortLabel
        case .parakeet(let m): return m.shortLabel
        }
    }

    /// "1.5 GB", "610 MB".
    public var downloadSize: String {
        switch self {
        case .whisper(let m):  return m.downloadSize
        case .parakeet(let m): return m.downloadSize
        }
    }

    /// Parakeet needs macOS 14 on Apple Silicon; elsewhere a saved choice reads as Whisper.
    public static func supported(_ kind: TranscriptionEngineKind,
                                 parakeetAvailable: Bool = ParakeetSupport.isAvailable) -> TranscriptionEngineKind {
        kind == .parakeet && !parakeetAvailable ? .whisper : kind
    }

    /// The local model to use: the selected engine's when it is local, otherwise the
    /// local engine picked last (`lastLocal`), with Whisper for anything else.
    public static func resolve(engine: TranscriptionEngineKind, lastLocal: TranscriptionEngineKind?,
                               whisper: WhisperModelID, parakeet: ParakeetModelID,
                               parakeetAvailable: Bool = ParakeetSupport.isAvailable) -> LocalModel {
        let kind = supported(engine.isLocal ? engine : (lastLocal ?? .whisper), parakeetAvailable: parakeetAvailable)
        return kind == .parakeet ? .parakeet(parakeet) : .whisper(whisper)
    }
}

/// Parakeet doesn't say which language it heard. Terminology and history need one,
/// so it is guessed from the alphabet of the transcript.
public enum ScriptLanguage {
    private static let ukrainianOnly = Set("іїєґІЇЄҐ")

    /// "ru" or "uk" for mostly Cyrillic text, "en" for plain-ASCII Latin text, nil
    /// otherwise (accented Latin could be any of Parakeet's other European languages).
    public static func guess(_ text: String) -> String? {
        var cyrillic = 0, latin = 0, accentedLatin = 0, ukrainian = 0
        for ch in text where ch.isLetter {
            guard let scalar = ch.unicodeScalars.first else { continue }
            switch scalar.value {
            case 0x0400...0x04FF:
                cyrillic += 1
                if ukrainianOnly.contains(ch) { ukrainian += 1 }
            case 0x41...0x5A, 0x61...0x7A:
                latin += 1
            case 0x00C0...0x024F:
                latin += 1
                accentedLatin += 1
            default:
                break
            }
        }
        if cyrillic > 0, cyrillic >= latin { return ukrainian > 0 ? "uk" : "ru" }
        if latin > 0, accentedLatin == 0 { return "en" }
        return nil
    }
}
