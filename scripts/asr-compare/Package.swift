// swift-tools-version: 5.9
// Developer-only harness: runs the same WAV clips through local Whisper (WhisperKit)
// and Parakeet (FluidAudio) and reports latency, accuracy and memory. Not part of
// the app; usage and results in docs/parakeet-vs-whisper.md.
import PackageDescription

let package = Package(
    name: "asr-compare",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Same versions the app resolves (Package.resolved / project.yml).
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "0.18.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "asr-compare",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources"
        ),
    ]
)
