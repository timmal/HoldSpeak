import Foundation

/// What HoldSpeakParakeet.framework offers the app.
///
/// The framework wraps FluidAudio, which needs macOS 14, while the app still supports
/// macOS 13 — and Swift refuses to import a module built for a newer macOS. So the app
/// never links or imports the framework: on macOS 14+ it loads the bundle at runtime
/// and talks to `HSParakeetBridge` through this protocol. This file is compiled into
/// both targets; the Objective-C runtime matches the two copies by their shared name.
///
/// `model` is a `ParakeetModelID` raw value (FluidAudio's folder name, e.g.
/// "parakeet-ultra"); `directory` is that folder.
@objc(HSParakeetEngine)
public protocol ParakeetEngineProtocol: NSObjectProtocol {
    init()

    /// Downloads the model into `directory` (skipped when it is already complete).
    /// `progress` gets 0…1.
    func download(model: String, to directory: String,
                  progress: @escaping @Sendable (Double) -> Void) async throws

    /// Loads (on a cold Core ML cache: compiles) the model. Replaces a loaded one.
    func load(model: String, from directory: String) async throws

    /// Frees the loaded model.
    func unload() async

    /// `samples`: 16 kHz mono Float32 PCM. `language`: an ISO code to keep the output in
    /// that language's alphabet, or nil to let Parakeet detect the language.
    func transcribe(samples: Data, language: String?) async throws -> String
}
