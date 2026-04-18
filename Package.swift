// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kwwk",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "KWWKAI", targets: ["KWWKAI"]),
        .library(name: "KWWKAgent", targets: ["KWWKAgent"]),
        .library(name: "KWWKCli", targets: ["KWWKCli"]),
        .executable(name: "kwwk", targets: ["kwwk"]),
    ],
    targets: [
        .target(
            name: "KWWKAI",
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
        .executableTarget(
            name: "kwwk",
            dependencies: ["KWWKCli"],
            path: "Sources/kwwk"
        ),
        .testTarget(
            name: "KWWKAITests",
            dependencies: ["KWWKAI"],
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
