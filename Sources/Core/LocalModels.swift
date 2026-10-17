import Foundation

/// NVIDIA Parakeet TDT models, run on this Mac through FluidAudio (Core ML, Neural Engine).
public enum ParakeetModelID: String, CaseIterable, Identifiable {
    /// moondream's post-training of Parakeet TDT 0.6B v3: 25 European languages,
    /// detected on its own. Raw value = the folder FluidAudio keeps it in (its
    /// `Repo.folderName`; the Hugging Face repo is FluidInference/parakeet-ultra-coreml).
    case ultra = "parakeet-ultra"

    public var id: String { rawValue }
    public var folderName: String { rawValue }

    public var label: String {
        switch self {
        case .ultra: return "Ultra — 25 European languages (~630 MB)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .ultra: return "Ultra (~630 MB)"
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

    /// The engine's name in the UI.
    public var engineName: String {
        switch self {
        case .whisper:  return "Whisper"
        case .parakeet: return "Parakeet"
        }
    }

    /// "Whisper Turbo (~800 MB)", "Parakeet Ultra (~630 MB)".
    public var shortLabel: String {
        switch self {
        case .whisper(let m):  return "Whisper \(m.shortLabel)"
        case .parakeet(let m): return "Parakeet \(m.shortLabel)"
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
