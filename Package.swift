// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PushToTalk",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PushToTalkCore", targets: ["PushToTalkCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "PushToTalkCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/Core"
        ),
        .testTarget(
            name: "PushToTalkCoreTests",
            dependencies: ["PushToTalkCore"],
            path: "Tests"
        ),
    ]
)
