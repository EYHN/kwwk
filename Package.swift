// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kw",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "KWAI", targets: ["KWAI"]),
        .library(name: "KWAgent", targets: ["KWAgent"]),
        .library(name: "KWCoding", targets: ["KWCoding"]),
        .library(name: "KWTUI", targets: ["KWTUI"]),
        .executable(name: "kw-tui-demo", targets: ["kw-tui-demo"]),
        .executable(name: "kw-chat-demo", targets: ["kw-chat-demo"]),
        .executable(name: "kw-coding-tui", targets: ["kw-coding-tui"]),
        .executable(name: "kw-tui-snapshot", targets: ["kw-tui-snapshot"]),
        .executable(name: "kw-generate-models", targets: ["kw-generate-models"]),
        .executable(name: "kw-login", targets: ["kw-login"]),
    ],
    targets: [
        .target(
            name: "KWAI",
            path: "Sources/KWAI",
            resources: [.process("Resources")]
        ),
        .target(
            name: "KWAgent",
            dependencies: ["KWAI"],
            path: "Sources/KWAgent"
        ),
        .target(
            name: "KWCoding",
            dependencies: ["KWAI", "KWAgent"],
            path: "Sources/KWCoding"
        ),
        .target(
            name: "KWTUI",
            path: "Sources/KWTUI"
        ),
        .target(
            name: "KWCodingTUIKit",
            dependencies: ["KWAI", "KWAgent", "KWTUI"],
            path: "Sources/KWCodingTUIKit"
        ),
        .executableTarget(
            name: "kw-tui-demo",
            dependencies: ["KWTUI"],
            path: "Examples/TUIDemo"
        ),
        .executableTarget(
            name: "kw-chat-demo",
            dependencies: ["KWAI", "KWAgent", "KWTUI"],
            path: "Examples/ChatDemo"
        ),
        .executableTarget(
            name: "kw-coding-tui",
            dependencies: ["KWAI", "KWAgent", "KWCoding", "KWTUI", "KWCodingTUIKit"],
            path: "Examples/CodingTUI"
        ),
        .executableTarget(
            name: "kw-tui-snapshot",
            dependencies: ["KWAI", "KWAgent", "KWCoding", "KWTUI", "KWCodingTUIKit"],
            path: "Examples/TUISnapshot"
        ),
        .executableTarget(
            name: "kw-generate-models",
            path: "Scripts/GenerateModels"
        ),
        .executableTarget(
            name: "kw-login",
            dependencies: ["KWAI"],
            path: "Examples/Login"
        ),
        .testTarget(
            name: "KWAITests",
            dependencies: ["KWAI"],
            path: "Tests/KWAITests"
        ),
        .testTarget(
            name: "KWAgentTests",
            dependencies: ["KWAgent", "KWAI"],
            path: "Tests/KWAgentTests"
        ),
        .testTarget(
            name: "KWCodingTests",
            dependencies: ["KWCoding", "KWAgent", "KWAI"],
            path: "Tests/KWCodingTests"
        ),
        .testTarget(
            name: "KWTUITests",
            dependencies: ["KWTUI"],
            path: "Tests/KWTUITests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
