// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YourTurn",
    // English is the source language; zh-Hant is the translation. Any system language
    // outside those two falls back to English.
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "YourTurn",
            path: "Sources/YourTurn",
            resources: [.process("Resources")]
        )
    ]
)
