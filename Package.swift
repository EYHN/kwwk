// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "kwwk",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .macCatalyst(.v17),
    ],
    products: [
        .library(name: "KWWKAI", targets: ["KWWKAI"]),
        .library(name: "KWWKAgent", targets: ["KWWKAgent"]),
        .library(name: "KWWKCli", targets: ["KWWKCli"]),
        .executable(name: "kwwk", targets: ["kwwk"]),
        .executable(name: "kwwk-generate-models", targets: ["kwwk-generate-models"]),
    ],
    dependencies: [
        // swift-crypto's `Crypto` module is source-compatible with Apple's
        // `CryptoKit` and ships on both Apple and Linux — one import, one
        // set of types, regardless of platform.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // SwiftNIO backs the OAuth callback server. Replaces the Apple
        // `Network.framework`-only implementation so the OAuth login flow
        // runs the same code on macOS and Linux.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "KWWKAI",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/KWWKAI",
            resources: [.process("Resources")]
        ),
        .target(
            name: "KWWKAgent",
            dependencies: ["KWWKAI"],
            path: "Sources/KWWKAgent"
        ),
        .target(
            name: "KWWKCli",
            dependencies: ["KWWKAI", "KWWKAgent"],
            path: "Sources/KWWKCli"
        ),
        .target(
            name: "KWWKGenerateModelsCore",
            path: "Scripts/GenerateModelsCore"
        ),
        .executableTarget(
            name: "kwwk",
            dependencies: ["KWWKCli"],
            path: "Sources/kwwk"
        ),
        .executableTarget(
            name: "kwwk-generate-models",
            dependencies: ["KWWKGenerateModelsCore"],
            path: "Scripts/GenerateModels"
        ),
        .testTarget(
            name: "KWWKAITests",
            dependencies: ["KWWKAI", "KWWKGenerateModelsCore"],
            path: "Tests/KWWKAITests"
        ),
        .testTarget(
            name: "KWWKAgentTests",
            dependencies: ["KWWKAgent", "KWWKAI"],
            path: "Tests/KWWKAgentTests"
        ),
        .testTarget(
            name: "KWWKCliTests",
            dependencies: ["KWWKCli", "KWWKAgent", "KWWKAI"],
            path: "Tests/KWWKCliTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
