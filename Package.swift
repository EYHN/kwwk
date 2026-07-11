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
        .executable(name: "kwwk-generate-cursor-models", targets: ["kwwk-generate-cursor-models"]),
    ],
    dependencies: [
        // swift-crypto's `Crypto` module is source-compatible with Apple's
        // `CryptoKit` and ships on both Apple and Linux — one import, one
        // set of types, regardless of platform.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        // SwiftNIO backs the OAuth callback server. Replaces the Apple
        // `Network.framework`-only implementation so the OAuth login flow
        // runs the same code on macOS and Linux.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // NIO HTTP/2 + TLS back the Cursor agent transport, which speaks the
        // Connect-RPC protocol over a full-duplex HTTP/2 stream (the client
        // keeps writing heartbeats / exec results while the server streams).
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.44.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
        .package(url: "https://github.com/troughton/Cstb.git", from: "1.0.6"),
        .package(url: "https://github.com/the-swift-collective/libwebp.git", from: "1.4.1"),
    ],
    targets: [
        .target(
            name: "KWWKAI",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "stb_image", package: "Cstb"),
                .product(name: "stb_image_resize", package: "Cstb"),
                .product(name: "stb_image_write", package: "Cstb"),
                .product(name: "WebP", package: "libwebp"),
                .product(name: "libwebp", package: "libwebp"),
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
        .executableTarget(
            name: "kwwk-generate-cursor-models",
            dependencies: ["KWWKAI"],
            path: "Scripts/GenerateCursorModels"
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
