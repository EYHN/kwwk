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
        // Provider sign-in, token refresh and subscription usage with no
        // NIO or image stack behind it, for apps (AirBuild's iOS/Mac client,
        // its backend) that need the vendor wire knowledge but not the agent
        // runtime. KWWKAI re-exports it, so `import KWWKAI` sees all of it.
        .library(name: "KWWKAuth", targets: ["KWWKAuth"]),
        .library(name: "KWWKAI", targets: ["KWWKAI"]),
        .library(name: "KWWKAgent", targets: ["KWWKAgent"]),
        .library(name: "KWWKCli", targets: ["KWWKCli"]),
        .library(name: "KWWKMCP", targets: ["KWWKMCP"]),
        .executable(name: "kwwk", targets: ["kwwk"]),
        .executable(name: "kwwk-generate-models", targets: ["kwwk-generate-models"]),
        .executable(name: "kwwk-generate-cursor-models", targets: ["kwwk-generate-cursor-models"]),
        .executable(name: "kwwk-generate-devin-models", targets: ["kwwk-generate-devin-models"]),
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
        // Vendored zlib (already in the graph through libpng) for gzip framing
        // on the Devin Connect wire, used on Linux only. A private module map
        // over the system zlib.h clashes with both this module and the Apple
        // SDK's `zlib` module in any package graph that loads either.
        .package(url: "https://github.com/the-swift-collective/zlib.git", from: "1.3.1"),
    ],
    targets: [
        .target(
            name: "KWWKAuth",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/KWWKAuth"
        ),
        .target(
            name: "KWWKAI",
            dependencies: [
                "KWWKAuth",
                // Apple platforms use the SDK's own `zlib` module (swift-nio
                // already loads it); the vendored headers would collide with
                // it inside one module graph. Linux has no SDK module.
                .product(name: "ZLibC", package: "zlib", condition: .when(platforms: [.linux])),
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
            name: "KWWKMCP",
            dependencies: [
                "KWWKAI",
                "KWWKAgent",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/KWWKMCP"
        ),
        .target(
            name: "KWWKCli",
            dependencies: ["KWWKAI", "KWWKAgent", "KWWKMCP"],
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
        .executableTarget(
            name: "kwwk-generate-devin-models",
            dependencies: ["KWWKAI"],
            path: "Scripts/GenerateDevinModels"
        ),
        .testTarget(
            name: "KWWKAuthTests",
            dependencies: ["KWWKAuth"],
            path: "Tests/KWWKAuthTests"
        ),
        .testTarget(
            name: "KWWKAITests",
            dependencies: ["KWWKAI", "KWWKAuth", "KWWKGenerateModelsCore"],
            path: "Tests/KWWKAITests"
        ),
        .testTarget(
            name: "KWWKAgentTests",
            dependencies: ["KWWKAgent", "KWWKAI"],
            path: "Tests/KWWKAgentTests"
        ),
        .testTarget(
            name: "KWWKMCPTests",
            dependencies: ["KWWKMCP", "KWWKAgent", "KWWKAI", .product(name: "Crypto", package: "swift-crypto")],
            path: "Tests/KWWKMCPTests"
        ),
        .testTarget(
            name: "KWWKCliTests",
            dependencies: ["KWWKCli", "KWWKAgent", "KWWKAI"],
            path: "Tests/KWWKCliTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
