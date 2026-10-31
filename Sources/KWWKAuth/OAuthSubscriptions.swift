import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Every subscription kwwk can sign in to, keep alive and read the usage of,
/// by the store id its login is kept under. A host — the kwwk CLI, an app
/// that runs the sign-in, a server that holds the refresh chain — asks here
/// and keeps no list of its own, so a provider kwwk gains reaches each of
/// them with the version that carries it.
public enum OAuthSubscriptions {
    /// What a sign-in leaves behind, which decides who has to look after it.
    public enum Upkeep: Sendable, Equatable {
        /// A refresh token: someone has to trade it for a new access token
        /// before the old one lapses (`refresher`).
        case refreshed
        /// A session that lapses and cannot be renewed: sign in again.
        case session
        /// A key that does not expire.
        case permanent
    }

    public struct Provider: Sendable, Equatable {
        public let id: String
        public let name: String
        public let upkeep: Upkeep
    }

    /// Every sign-in `login(providerId:)` runs, in the order kwwk lists them.
    public static let providers: [Provider] = [
        Provider(id: "openai-codex", name: "ChatGPT Codex", upkeep: .refreshed),
        Provider(id: "anthropic", name: "Claude Pro or Max", upkeep: .refreshed),
        Provider(id: "github-copilot", name: "GitHub Copilot", upkeep: .refreshed),
        Provider(id: "cursor", name: "Cursor", upkeep: .refreshed),
        Provider(id: "devin", name: "Devin", upkeep: .session),
        Provider(id: "kiro", name: "Kiro", upkeep: .refreshed),
        Provider(id: QoderSite.global.id, name: QoderSite.global.name, upkeep: .refreshed),
        Provider(id: QoderSite.cn.id, name: QoderSite.cn.name, upkeep: .refreshed),
        Provider(id: WorkBuddySite.china.id, name: WorkBuddySite.china.name, upkeep: .refreshed),
        Provider(id: WorkBuddySite.international.id, name: WorkBuddySite.international.name, upkeep: .refreshed),
        Provider(id: KimiSite.china.id, name: KimiSite.china.name, upkeep: .refreshed),
        Provider(id: KimiSite.global.id, name: KimiSite.global.name, upkeep: .refreshed),
        Provider(id: "xai", name: "Grok", upkeep: .refreshed),
        Provider(id: "zai", name: "Z.ai Coding Plan", upkeep: .permanent),
        Provider(id: ZaiSite.china.id, name: "BigModel Coding Plan", upkeep: .permanent),
        Provider(id: "openrouter", name: "OpenRouter", upkeep: .permanent),
    ]

    public static func provider(id: String) -> Provider? {
        providers.first { $0.id == id }
    }

    /// The store ids whose logins carry a refresh token, each with a
    /// `refresher`. A host that stores logins for others accepts a
    /// refresh-bearing one only under these.
    public static var refreshedIds: Set<String> {
        Set(providers.filter { $0.upkeep == .refreshed }.map(\.id))
    }

    /// The store ids whose usage kwwk can read (`OAuthUsage.readers`).
    public static var usageIds: Set<String> {
        Set(OAuthUsage.readers.keys)
    }

    /// Runs `providerId`'s sign-in. `kimiIdentity` is the device fingerprint
    /// Kimi binds a grant to; nil uses this machine's.
    public static func login(
        providerId: String,
        callbacks: OAuthLogin.Callbacks,
        kimiIdentity: KimiDeviceIdentity? = nil,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        switch providerId {
        case "anthropic":
            return try await OAuthLogin.loginAnthropic(callbacks: callbacks, client: client)
        case "openai-codex":
            return try await OAuthLogin.loginOpenAICodex(callbacks: callbacks, client: client)
        case "github-copilot":
            return try await OAuthLogin.loginGitHubCopilot(callbacks: callbacks, client: client)
        case "cursor":
            return try await OAuthLogin.loginCursor(callbacks: callbacks, client: client)
        case "devin":
            return try await OAuthLogin.loginDevin(callbacks: callbacks, client: client)
        case "kiro":
            return try await OAuthLogin.loginKiro(callbacks: callbacks, client: client)
        case QoderSite.global.id:
            return try await OAuthLogin.loginQoder(site: .global, callbacks: callbacks, client: client)
        case QoderSite.cn.id:
            return try await OAuthLogin.loginQoder(site: .cn, callbacks: callbacks, client: client)
        case WorkBuddySite.china.id:
            return try await OAuthLogin.loginWorkBuddy(site: .china, callbacks: callbacks, client: client)
        case WorkBuddySite.international.id:
            return try await OAuthLogin.loginWorkBuddy(site: .international, callbacks: callbacks, client: client)
        case KimiSite.china.id, KimiSite.global.id:
            return try await OAuthLogin.loginKimiCoding(
                site: KimiSite.site(id: providerId)!,
                identity: kimiIdentity,
                callbacks: callbacks,
                client: client
            )
        case "xai":
            return try await OAuthLogin.loginXai(callbacks: callbacks, client: client)
        case ZaiSite.global.id:
            return try await OAuthLogin.loginZai(site: .global, callbacks: callbacks, client: client)
        case ZaiSite.china.id:
            return try await OAuthLogin.loginZai(site: .china, callbacks: callbacks, client: client)
        case "openrouter":
            return try await OAuthLogin.loginOpenRouter(callbacks: callbacks, client: client)
        default:
            throw OAuthError.unknownProvider(providerId)
        }
    }

    /// The provider that renews `providerId`'s login, nil for a store id
    /// with nothing to renew. `kimiIdentity` is sent for a Kimi login that
    /// recorded no device id of its own; nil uses this machine's.
    public static func refresher(
        providerId: String,
        kimiIdentity: KimiDeviceIdentity? = nil
    ) -> (any OAuthProvider)? {
        switch providerId {
        case "anthropic": AnthropicOAuthProvider()
        case "openai-codex": OpenAICodexOAuthProvider()
        case "github-copilot": GitHubCopilotOAuthProvider()
        case "cursor": CursorOAuthProvider()
        case "kiro": KiroOAuthProvider()
        case QoderSite.global.id: QoderOAuthProvider(site: .global)
        case QoderSite.cn.id: QoderOAuthProvider(site: .cn)
        case WorkBuddySite.china.id: WorkBuddyOAuthProvider(site: .china)
        case WorkBuddySite.international.id: WorkBuddyOAuthProvider(site: .international)
        case KimiSite.china.id, KimiSite.global.id:
            KimiCodingOAuthProvider(site: KimiSite.site(id: providerId)!, identity: kimiIdentity)
        case "xai": XaiOAuthProvider()
        default: nil
        }
    }

    /// A refresher for every login that has one, in `providers` order.
    public static func refreshers(kimiIdentity: KimiDeviceIdentity? = nil) -> [any OAuthProvider] {
        providers.compactMap { refresher(providerId: $0.id, kimiIdentity: kimiIdentity) }
    }
}
