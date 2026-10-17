// Loads HoldSpeakParakeet.framework out of a built HoldSpeak.app the way the app does
// (Bundle.load + NSClassFromString + cast to the shared @objc protocol), from a binary
// built for macOS 13 like the app, and transcribes one WAV. Run via bridge-smoke.sh.
import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count == 4 else {
    print("usage: bridge-smoke <HoldSpeak.app> <model dir> <clip.wav>")
    exit(2)
}
let app = URL(fileURLWithPath: args[1])
let modelDir = args[2]
let wav = URL(fileURLWithPath: args[3])

let frameworkURL = app.appendingPathComponent("Contents/Frameworks/HoldSpeakParakeet.framework")
guard let bundle = Bundle(url: frameworkURL) else { fatalError("no framework at \(frameworkURL.path)") }
try bundle.loadAndReturnError()
guard let type = NSClassFromString("HSParakeetBridge") as? ParakeetEngineProtocol.Type else {
    fatalError("HSParakeetBridge missing or not conforming to HSParakeetEngine")
}
let engine = type.init()
print("bridge loaded: \(engine)")

let file = try AVAudioFile(forReading: wav)
let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
try file.read(into: buffer)
let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }

let t0 = Date()
try await engine.download(model: "parakeet-ultra", to: modelDir) { _ in }
try await engine.load(model: "parakeet-ultra", from: modelDir)
print(String(format: "load %.2f s", Date().timeIntervalSince(t0)))
for _ in 0..<2 {
    let t = Date()
    let text = try await engine.transcribe(samples: data, language: nil)
    print(String(format: "%.0f ms: %@", Date().timeIntervalSince(t) * 1000, text))
}
await engine.unload()
do {
    _ = try await engine.transcribe(samples: data, language: nil)
    print("FAIL: transcribed after unload")
    exit(1)
} catch {
    print("after unload: \(error.localizedDescription)")
}
print("OK")
