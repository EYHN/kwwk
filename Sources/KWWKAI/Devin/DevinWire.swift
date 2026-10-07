import Foundation

/// Devin (Codeium Cascade) wire constants shared by the provider, the model
/// generator, and OAuth. Ported from oh-my-pi's `catalog/src/wire/devin.ts`.
public enum DevinWire {
    /// Base host for Cascade's API (Connect protocol over HTTP/1.1).
    public static let defaultBaseURL = "https://server.codeium.com"

    static let getChatMessagePath = "/exa.api_server_pb.ApiServerService/GetChatMessage"
    static let assignModelPath = "/exa.api_server_pb.ApiServerService/AssignModel"
    static let getUserJwtPath = "/exa.auth_pb.AuthService/GetUserJwt"
    static let getCliModelConfigsPath = "/exa.api_server_pb.ApiServerService/GetCliModelConfigs"

    static let sessionTokenPrefix = "devin-session-token$"

    /// `Metadata.os` vocabulary.
    static var osName: String {
        #if os(macOS) || os(iOS) || targetEnvironment(macCatalyst)
        return "darwin"
        #elseif os(Windows)
        return "windows"
        #else
        return "linux"
        #endif
    }

    /// Released Devin CLI identity. The backend gates behavior on this tuple:
    /// `ideType: "chisel"` unlocks router assignment and the CLI model
    /// surface. Bump alongside oh-my-pi if the backend starts rejecting it.
    static let cliIdeName = "devin-cli"
    static let cliIdeType = "chisel"
    static let cliVersion = "3000.11.3"
    static let cliExtensionName = "chisel"

    /// Connect client identity the native CLI sends on the chat stream.
    static let connectUserAgent = "connect-go/1.18.1 (go1.26.3)"

    /// The session token as the wire carries it: the scheme prefix is required.
    static func normalizeSessionToken(_ apiKey: String) -> String {
        apiKey.hasPrefix(sessionTokenPrefix) ? apiKey : sessionTokenPrefix + apiKey
    }

    /// Released-CLI metadata with the credential already in wire form.
    static func cliMetadata(apiKey: String, userJwt: String = "") -> DevinProto.Metadata {
        DevinProto.Metadata(
            ideName: cliIdeName,
            ideVersion: cliVersion,
            ideType: cliIdeType,
            extensionName: cliExtensionName,
            extensionVersion: cliVersion,
            apiKey: apiKey,
            locale: "en",
            os: osName,
            userJwt: userJwt
        )
    }

    /// Native discovery identity: the CLI announces itself as the `chisel`
    /// client on its dev channel for `GetCliModelConfigs`, which unlocks the
    /// full native config set.
    static func discoveryMetadata(apiKey: String) -> DevinProto.Metadata {
        DevinProto.Metadata(
            ideName: "chisel",
            ideVersion: "0.0.0-dev",
            extensionName: "chisel",
            extensionVersion: "0.0.0-dev",
            apiKey: normalizeSessionToken(apiKey),
            locale: "en",
            os: osName,
            supportedModelDisplays: [
                DevinProto.DisplayOption.modelRouter,
                DevinProto.DisplayOption.quickReview,
                DevinProto.DisplayOption.internalDefault,
                DevinProto.DisplayOption.unclassified,
                DevinProto.DisplayOption.normal,
            ]
        )
    }

    /// Legacy Windsurf editor identity. Windsurf Enterprise seats expose their
    /// full roster only to this identity with the raw key.
    static func legacyWindsurfMetadata(apiKey: String) -> DevinProto.Metadata {
        DevinProto.Metadata(
            ideName: "windsurf",
            ideVersion: "3.2.23",
            extensionName: "windsurf",
            extensionVersion: "1.48.2",
            apiKey: apiKey,
            locale: "en"
        )
    }

    /// Headers for unary Connect calls (`application/proto` bodies).
    static let unaryHeaders: [String: String] = [
        "content-type": "application/proto",
        "connect-protocol-version": "1",
        "accept": "*/*",
    ]
}
