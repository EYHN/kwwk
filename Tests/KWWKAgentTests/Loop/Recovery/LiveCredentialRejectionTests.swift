import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

/// LIVE and opt-in: `KWWK_LIVE_REJECTION=1 swift test --filter LiveCredentialRejection`.
///
/// Sends one short prompt per provider through the real agent loop, with the
/// real logins in `~/.kwwk/oauth.json`, carrying a token the provider must
/// refuse: the stored access token with one character changed, its expiry
/// untouched. That is a token refused before its recorded expiry, the case
/// the rejection hook exists for. The logins file is only read: the source
/// blanks every refresh token and writes nothing, so no login is rotated.
///
/// With `KWWK_PROVIDER_ERROR_DIR` set, every refusal is also kept verbatim;
/// that is how the files under `KWWKAITests/Fixtures/ProviderErrors` were
/// captured. `KWWK_LIVE_IDS` picks the providers (comma separated). Logins
/// whose stored token has expired are skipped; refresh them with kwwk first.
@Suite("LIVE credential rejection", .enabled(if: ProcessInfo.processInfo.environment["KWWK_LIVE_REJECTION"] == "1"))
struct LiveCredentialRejectionTests {
    /// Serves a refused copy of a real login; on a rejection report it hands
    /// back the real one when `renews`, like an authority that owns refresh.
    final class LiveSource: OAuthCredentialSource, @unchecked Sendable {
        let providerId: String
        let real: OAuthCredentials
        let refused: String
        let renews: Bool
        private let lock = NSLock()
        private var serving: OAuthCredentials
        private var reports = 0
        var rejections: Int { lock.withLock { reports } }

        init(providerId: String, real: OAuthCredentials, renews: Bool) {
            var real = real
            real.refresh = ""
            var chars = Array(real.access)
            let i = chars.count - 2
            chars[i] = chars[i] == "A" ? "B" : "A"
            self.providerId = providerId
            self.real = real
            self.refused = String(chars)
            self.renews = renews
            var stale = real
            stale.access = refused
            self.serving = stale
        }

        func providerIds() async -> [String] { [providerId] }
        func credentials(for id: String) async throws -> OAuthCredentials? {
            id == providerId ? lock.withLock { serving } : nil
        }
        func credentialsAfterRejection(of rejectedAccess: String, for id: String) async throws -> OAuthCredentials? {
            lock.withLock {
                reports += 1
                guard renews else { return nil }
                serving = real
                return real
            }
        }
    }

    actor TokenLog {
        var sent: [String] = []
        func add(_ label: String) { sent.append(label) }
    }

    static let ids = (ProcessInfo.processInfo.environment["KWWK_LIVE_IDS"]
        ?? "openai-codex,anthropic,github-copilot,cursor,devin,kimi-coding,kimi-coding-ai,xai,kiro,qoder,qoder-cn,workbuddy,workbuddy-ai")
        .split(separator: ",").map(String.init)

    struct Outcome {
        var sent: [String]
        var rejections: Int
        var last: AssistantMessage?
    }

    func run(_ providerId: String, renews: Bool) async throws -> Outcome? {
        let all = try JSONDecoder().decode([String: OAuthCredentials].self,
                                           from: Data(contentsOf: OAuthStore.defaultURL()))
        guard let real = all[providerId], !real.isExpired else { return nil }
        let source = LiveSource(providerId: providerId, real: real, renews: renews)
        let resolved = try #require(try await registerStored(
            storeId: providerId, manager: OAuthManager(source: source), primeToken: false
        ))
        let resolver = try #require(resolved.authResolver)
        let log = TokenLog()
        let agent = Agent(initialState: AgentInitialState(model: resolved.model))
        agent.retryBaseDelayMs = 5
        agent.authResolver = { model, session in
            let auth = try await resolver(model, session)
            await log.add(auth?.token == source.refused ? "refused" : auth?.token == real.access ? "real" : "other")
            return auth
        }
        try? await agent.prompt("Reply with exactly the word: ok")
        var last: AssistantMessage?
        if case .assistant(let message) = agent.state.messages.last { last = message }
        return Outcome(sent: await log.sent, rejections: source.rejections, last: last)
    }

    @Test("a refused token is reported once and replayed with the renewed one", arguments: Self.ids)
    func renewed(_ providerId: String) async throws {
        guard let outcome = try await run(providerId, renews: true) else { return }
        #expect(outcome.sent == ["refused", "real"], "\(providerId)")
        #expect(outcome.rejections == 1, "\(providerId)")
        // The replay got past authentication; what it answered is the account's.
        #expect(outcome.last?.failure?.isCredentialRejection != true, "\(String(describing: outcome.last?.failure))")
    }

    @Test("with nothing renewed, the refusal surfaces after one report", arguments: Self.ids)
    func notRenewed(_ providerId: String) async throws {
        guard let outcome = try await run(providerId, renews: false) else { return }
        #expect(outcome.sent == ["refused"], "\(providerId)")
        #expect(outcome.rejections == 1, "\(providerId)")
        #expect(outcome.last?.failure?.isCredentialRejection == true, "\(String(describing: outcome.last?.failure))")
    }
}
