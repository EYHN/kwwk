import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKCli

@Suite("multi-provider auth", .serialized)
struct MultiProviderAuthTests {

    // MARK: - Store is additive

    @Test("OAuthStore.set keeps other providers (multi-login)")
    func storeIsAdditive() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-multilogin-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("oauth.json")
        let store = OAuthStore(url: url)

        try await store.set(OAuthCredentials(access: "a", refresh: "ra", expires: .max), for: "anthropic")
        try await store.set(OAuthCredentials(access: "c", refresh: "rc", expires: .max), for: "openai-codex")
        let all = await store.all()
        #expect(all.keys.sorted() == ["anthropic", "openai-codex"])

        // Re-persist through a fresh store instance to confirm it round-trips.
        let reopened = OAuthStore(url: url)
        #expect(await reopened.get("anthropic")?.access == "a")
        #expect(await reopened.get("openai-codex")?.access == "c")
    }

    // MARK: - Priority / scope / catalog helpers

    @Test("storedProviderOrder ranks OAuth subscriptions before api keys")
    func providerOrder() {
        let all: [String: OAuthCredentials] = [
            "google-api-key": .init(access: "g", refresh: "", expires: .max),
            "anthropic": .init(access: "a", refresh: "r", expires: .max),
            "openai-codex": .init(access: "c", refresh: "r", expires: .max),
        ]
        #expect(storedProviderOrder(all) == ["openai-codex", "anthropic", "google-api-key"])
    }

    @Test("modelProviderScope collapses same-vendor logins; catalogProvider maps to the catalog key")
    func scopeAndCatalog() {
        // Anthropic OAuth and API key share the anthropic-messages wire → same
        // scope, so registerAllStored keeps only the higher-priority one.
        #expect(modelProviderScope(forStoreId: "anthropic") == "anthropic")
        #expect(modelProviderScope(forStoreId: "anthropic-api-key") == "anthropic")
        // Codex registers under the chatgpt.com variant scope, not the catalog key.
        #expect(modelProviderScope(forStoreId: "openai-codex") == "chatgpt-codex")
        #expect(catalogProvider(forStoreId: "openai-codex") == "openai-codex")
        #expect(catalogProvider(forStoreId: "openai-api-key") == "openai")
        #expect(catalogProvider(forStoreId: "github-copilot") == "github-copilot")
    }

    // MARK: - OpenRouter (first-class provider)

    @Test("openrouter maps 1:1 to scope + catalog and ranks after direct vendor keys")
    func openRouterScopeCatalogOrder() {
        #expect(modelProviderScope(forStoreId: "openrouter") == "openrouter")
        #expect(catalogProvider(forStoreId: "openrouter") == "openrouter")
        let all: [String: OAuthCredentials] = [
            "openrouter": .init(access: "o", refresh: "", expires: .max),
            "anthropic-api-key": .init(access: "a", refresh: "", expires: .max),
        ]
        #expect(storedProviderOrder(all) == ["anthropic-api-key", "openrouter"])
    }

    @Test("registerStored wires an OpenRouter login with catalog metadata")
    func registerStoredOpenRouter() async throws {
        try await withSharedAPIRegistry {
            await APIRegistry.shared.unregisterScope("openrouter")
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("kwwk-openrouter-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let store = OAuthStore(url: dir.appendingPathComponent("oauth.json"))
            try await store.set(OAuthCredentials(
                access: "sk-or-test", refresh: "", expires: .max,
                extras: ["defaultModel": .string("z-ai/glm-5.2")]
            ), for: "openrouter")

            let resolved = try await registerStored(
                storeId: "openrouter", store: store, modelOverride: nil, context1m: false
            )
            #expect(resolved?.model.id == "z-ai/glm-5.2")
            #expect(resolved?.model.provider == "openrouter")
            #expect(resolved?.model.api == "openai-completions")
            #expect(resolved?.model.baseUrl == "https://openrouter.ai/api/v1")
            // Catalog metadata — including the OpenRouter reasoning format the
            // completions encoder needs — rides along. Compare against the live
            // catalog entry (not a pinned number) so a catalog regeneration
            // can't break this wiring test.
            #expect(resolved?.model.compat?.thinkingFormat == "openrouter")
            let catalogEntry = try #require(ModelsCatalog.model(provider: "openrouter", id: "z-ai/glm-5.2"))
            #expect(resolved?.model.contextWindow == catalogEntry.contextWindow)
            #expect(resolved?.modelLabel == "z-ai/glm-5.2 · OpenRouter")
            let scoped = await APIRegistry.shared.provider(scope: "openrouter", api: "openai-completions")
            #expect(scoped is OpenAICompletionsProvider)
            await APIRegistry.shared.unregisterScope("openrouter")
        }
    }

    @Test("registerStored openrouter defaults + uncatalogued ids keep the OpenRouter wire")
    func registerStoredOpenRouterFallbacks() async throws {
        try await withSharedAPIRegistry {
            await APIRegistry.shared.unregisterScope("openrouter")
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("kwwk-openrouter-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let store = OAuthStore(url: dir.appendingPathComponent("oauth.json"))
            // No defaultModel stored → sensible default.
            try await store.set(OAuthCredentials(
                access: "sk-or-test", refresh: "", expires: .max
            ), for: "openrouter")
            let defaulted = try await registerStored(
                storeId: "openrouter", store: store, modelOverride: nil, context1m: false
            )
            #expect(defaulted?.model.id == "anthropic/claude-sonnet-5")

            // An uncatalogued override still routes through the OpenRouter
            // endpoint with the OpenRouter thinking format.
            let custom = try await registerStored(
                storeId: "openrouter", store: store,
                modelOverride: "somelab/brand-new-model", context1m: false
            )
            #expect(custom?.model.id == "somelab/brand-new-model")
            #expect(custom?.model.baseUrl == "https://openrouter.ai/api/v1")
            #expect(custom?.model.compat?.thinkingFormat == "openrouter")
            await APIRegistry.shared.unregisterScope("openrouter")
        }
    }

    // MARK: - Unified resolver dispatch

    @Test("SessionAuthResolvers dispatches by model.provider and supports mid-session add/remove")
    func resolverDispatch() async {
        let resolvers = SessionAuthResolvers()
        await resolvers.set(scope: "anthropic") { _, _ in
            ResolvedProviderAuth(token: "anthropic-token", scheme: .bearer)
        }
        await resolvers.set(scope: "chatgpt-codex") { _, _ in
            ResolvedProviderAuth(token: "codex-token", scheme: .bearer)
        }

        let anthropicModel = Model(id: "claude", api: "anthropic-messages", provider: "anthropic")
        let codexModel = Model(id: "gpt", api: "chatgpt-codex", provider: "chatgpt-codex")
        let staticModel = Model(id: "k", api: "openai-responses", provider: "openai")

        #expect(await resolvers.resolve(anthropicModel, nil)?.token == "anthropic-token")
        #expect(await resolvers.resolve(codexModel, nil)?.token == "codex-token")
        // A static (api-key) provider has no resolver → nil → baked key used.
        #expect(await resolvers.resolve(staticModel, nil) == nil)

        // The stable delegating closure sees a provider added later (`/login`).
        let delegate = resolvers.delegatingResolver()
        #expect(await delegate(staticModel, nil) == nil)
        await resolvers.set(scope: "openai") { _, _ in
            ResolvedProviderAuth(token: "openai-token", scheme: .bearer)
        }
        #expect(await delegate(staticModel, nil)?.token == "openai-token")

        // Removal (`/logout`) drops it again.
        await resolvers.remove(scope: "openai")
        #expect(await delegate(staticModel, nil) == nil)
    }

    // MARK: - SessionProviders bookkeeping

    @MainActor
    @Test("SessionProviders upsert de-dupes by storeId; remove drops it")
    func sessionProviders() {
        let sp = SessionProviders()
        let a = ProviderSlot(
            storeId: "anthropic", catalogProvider: "anthropic",
            displayName: "Anthropic", template: Model(id: "claude", api: "anthropic-messages", provider: "anthropic")
        )
        sp.upsert(a)
        sp.upsert(a)  // re-login overwrites, not duplicates
        #expect(sp.slots.count == 1)

        let codex = ProviderSlot(
            storeId: "openai-codex", catalogProvider: "openai-codex",
            displayName: "ChatGPT Codex", template: Model(id: "gpt", api: "chatgpt-codex", provider: "chatgpt-codex")
        )
        sp.upsert(codex)
        #expect(sp.slots.count == 2)
        #expect(sp.slot(forStoreId: "openai-codex")?.template.provider == "chatgpt-codex")

        sp.remove(storeId: "anthropic")
        #expect(sp.slots.map { $0.storeId } == ["openai-codex"])
    }

    // MARK: - /model cross-provider routing

    @Test("adoptFields routes a cross-provider pick through the target template")
    func adoptFieldsCrossProvider() {
        // Switching to a Codex model: the catalog lists it under `openai-codex`
        // with the `openai-responses` wire, but it must route through the
        // registered `chatgpt-codex` variant scope + endpoint, and keep the
        // Codex `maxTokens == 0` sentinel.
        let codexTemplate = Model(
            id: "gpt-5.5", api: "chatgpt-codex", provider: "chatgpt-codex",
            baseUrl: "https://chatgpt.com", maxTokens: 0
        )
        let picked = Model(
            id: "gpt-5.5-codex", api: "openai-responses", provider: "openai-codex",
            baseUrl: "https://api.openai.com", maxTokens: 128_000
        )
        let routed = adoptFields(from: codexTemplate, into: picked)
        #expect(routed.id == "gpt-5.5-codex")
        #expect(routed.provider == "chatgpt-codex")
        #expect(routed.api == "chatgpt-codex")
        #expect(routed.baseUrl == "https://chatgpt.com")
        #expect(routed.maxTokens == 0)

        // Same-provider switch (Copilot enterprise) keeps the session baseUrl.
        let copilotTemplate = Model(
            id: "gpt-5.5", api: "openai-responses", provider: "github-copilot",
            baseUrl: "https://api.business.githubcopilot.com"
        )
        let copilotPick = Model(
            id: "claude-opus-4-8", api: "anthropic-messages", provider: "github-copilot",
            baseUrl: "https://api.individual.githubcopilot.com"
        )
        let copilotRouted = adoptFields(from: copilotTemplate, into: copilotPick)
        #expect(copilotRouted.provider == "github-copilot")
        #expect(copilotRouted.api == "anthropic-messages")
        #expect(copilotRouted.baseUrl == "https://api.business.githubcopilot.com")
    }

    @Test("adoptFields keeps per-model compat + thinkingLevelMap")
    func adoptFieldsKeepsCompat() {
        var compat = ModelCompat()
        compat.thinkingFormat = "openrouter"
        let template = Model(
            id: "anthropic/claude-sonnet-5", api: "openai-completions",
            provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1"
        )
        let picked = Model(
            id: "z-ai/glm-5.2", api: "openai-completions",
            provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1",
            compat: compat, thinkingLevelMap: ["xhigh": "xhigh"]
        )
        let routed = adoptFields(from: template, into: picked)
        #expect(routed.compat?.thinkingFormat == "openrouter")
        #expect(routed.thinkingLevelMap == ["xhigh": "xhigh"])
    }
}
