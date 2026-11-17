// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HoldSpeak",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HoldSpeakCore", targets: ["HoldSpeakCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "6.29.3"),
    ],
    targets: [
        .target(
            name: "ObjCCatch",
            path: "Sources/ObjCCatch"
        ),
        .target(
            name: "HoldSpeakCore",
            dependencies: [
                "ObjCCatch",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/Core"
        ),
        .testTarget(
            name: "HoldSpeakCoreTests",
            dependencies: ["HoldSpeakCore", "ObjCCatch"],
            path: "Tests"
        ),
    ]
)
