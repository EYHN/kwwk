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
        let store = try OAuthStore(url: url)

        try await store.set(OAuthCredentials(access: "a", refresh: "ra", expires: .max), for: "anthropic")
        try await store.set(OAuthCredentials(access: "c", refresh: "rc", expires: .max), for: "openai-codex")
        let all = await store.all()
        #expect(all.keys.sorted() == ["anthropic", "openai-codex"])

        // Re-persist through a fresh store instance to confirm it round-trips.
        let reopened = try OAuthStore(url: url)
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
            let store = try OAuthStore(url: dir.appendingPathComponent("oauth.json"))
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
            #expect(resolved?.model.baseURL == "https://openrouter.ai/api/v1")
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
            let store = try OAuthStore(url: dir.appendingPathComponent("oauth.json"))
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
            #expect(custom?.model.baseURL == "https://openrouter.ai/api/v1")
            #expect(custom?.model.compat?.thinkingFormat == "openrouter")
            await APIRegistry.shared.unregisterScope("openrouter")
        }
    }

    // MARK: - Kimi For Coding + Z.AI Coding Plan (first-class providers)

    @Test("registerStored wires a Kimi For Coding login onto the bearer anthropic wire")
    func registerStoredKimiCoding() async throws {
        try await withSharedAPIRegistry {
            await APIRegistry.shared.unregisterScope("kimi-coding")
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("kwwk-kimi-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let store = try OAuthStore(url: dir.appendingPathComponent("oauth.json"))
            // Never-expiring credentials so registration skips the token refresh.
            try await store.set(OAuthCredentials(
                access: "kimi-token", refresh: "kimi-refresh", expires: .max
            ), for: "kimi-coding")

            let resolved = try await registerStored(
                storeId: "kimi-coding", store: store, modelOverride: nil, context1m: false
            )
            #expect(resolved?.model.id == "kimi-for-coding")
            #expect(resolved?.model.provider == "kimi-coding")
            #expect(resolved?.model.api == "anthropic-messages")
            #expect(resolved?.model.baseURL == "https://api.kimi.com/coding")
            // The KimiCLI agent string rides along from the catalog so the
            // coding endpoint accepts the request.
            #expect(resolved?.model.headers?["User-Agent"]?.hasPrefix("KimiCLI/") == true)
            let catalogEntry = try #require(ModelsCatalog.model(provider: "kimi-coding", id: "kimi-for-coding"))
            #expect(resolved?.model.contextWindow == catalogEntry.contextWindow)
            #expect(resolved?.modelLabel == "kimi-for-coding · Kimi For Coding")
            // The OAuth resolver supplies a bearer token per request.
            let auth = try await resolved?.authResolver?(catalogEntry, nil)
            #expect(auth?.token == "kimi-token")
            let scoped = await APIRegistry.shared.provider(scope: "kimi-coding", api: "anthropic-messages")
            #expect(scoped is AnthropicProvider)
            await APIRegistry.shared.unregisterScope("kimi-coding")
        }
    }

    @Test("registerStored wires Z.AI global + China logins with catalog metadata")
    func registerStoredZai() async throws {
        try await withSharedAPIRegistry {
            for (storeId, base) in [
                ("zai", "https://api.z.ai/api/coding/paas/v4"),
                ("zai-coding-cn", "https://open.bigmodel.cn/api/coding/paas/v4"),
            ] {
                await APIRegistry.shared.unregisterScope(storeId)
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("kwwk-zai-\(UUID().uuidString.prefix(8))")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let store = try OAuthStore(url: dir.appendingPathComponent("oauth.json"))
                try await store.set(OAuthCredentials(
                    access: "zai-key", refresh: "", expires: .max
                ), for: storeId)

                let resolved = try await registerStored(
                    storeId: storeId, store: store, modelOverride: nil, context1m: false
                )
                #expect(resolved?.model.id == "glm-5.2")
                #expect(resolved?.model.provider == storeId)
                #expect(resolved?.model.api == "openai-completions")
                #expect(resolved?.model.baseURL == base)
                // Catalog compat — the Z.AI thinking format — rides along.
                #expect(resolved?.model.compat?.thinkingFormat == "zai")
                let scoped = await APIRegistry.shared.provider(scope: storeId, api: "openai-completions")
                #expect(scoped is OpenAICompletionsProvider)

                // An uncatalogued override still routes through the coding
                // endpoint with the Z.AI thinking format.
                let custom = try await registerStored(
                    storeId: storeId, store: store,
                    modelOverride: "glm-99-experimental", context1m: false
                )
                #expect(custom?.model.id == "glm-99-experimental")
                #expect(custom?.model.baseURL == base)
                #expect(custom?.model.compat?.thinkingFormat == "zai")
                await APIRegistry.shared.unregisterScope(storeId)
            }
        }
    }

    @Test("the completions URL builder keeps versioned bases (Z.AI /paas/v4) intact")
    func zaiURLNotDoubleVersioned() {
        let provider = OpenAICompletionsProvider(defaultAPIKey: "k")
        let fallback = URL(string: "https://api.openai.com")!
        let zai = Model(
            id: "glm-5.2", name: "GLM-5.2", api: "openai-completions",
            provider: "zai", baseURL: "https://api.z.ai/api/coding/paas/v4"
        )
        #expect(
            provider.urlBuilder(zai, nil, fallback).absoluteString
                == "https://api.z.ai/api/coding/paas/v4/chat/completions"
        )
        // Bare hosts still gain the default /v1; existing /v1 bases don't double it.
        let bare = Model(
            id: "m", name: "m", api: "openai-completions",
            provider: "x", baseURL: "https://api.deepseek.com"
        )
        #expect(
            provider.urlBuilder(bare, nil, fallback).absoluteString
                == "https://api.deepseek.com/v1/chat/completions"
        )
        let v1 = Model(
            id: "m", name: "m", api: "openai-completions",
            provider: "x", baseURL: "https://openrouter.ai/api/v1"
        )
        #expect(
            provider.urlBuilder(v1, nil, fallback).absoluteString
                == "https://openrouter.ai/api/v1/chat/completions"
        )
    }

    // MARK: - Unified resolver dispatch

    @Test("SessionAuthResolvers dispatches by model.provider and supports mid-session add/remove")
    func resolverDispatch() async throws {
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

        #expect(try await resolvers.resolve(anthropicModel, nil)?.token == "anthropic-token")
        #expect(try await resolvers.resolve(codexModel, nil)?.token == "codex-token")
        // A static (api-key) provider has no resolver → nil → baked key used.
        #expect(try await resolvers.resolve(staticModel, nil) == nil)

        // The stable delegating closure sees a provider added later (`/login`).
        let delegate = resolvers.delegatingResolver()
        #expect(try await delegate(staticModel, nil) == nil)
        await resolvers.set(scope: "openai") { _, _ in
            ResolvedProviderAuth(token: "openai-token", scheme: .bearer)
        }
        #expect(try await delegate(staticModel, nil)?.token == "openai-token")

        // Removal (`/logout`) drops it again.
        await resolvers.remove(scope: "openai")
        #expect(try await delegate(staticModel, nil) == nil)
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
            baseURL: "https://chatgpt.com", maxTokens: 0
        )
        let picked = Model(
            id: "gpt-5.5-codex", api: "openai-responses", provider: "openai-codex",
            baseURL: "https://api.openai.com", maxTokens: 128_000
        )
        let routed = adoptFields(from: codexTemplate, into: picked)
        #expect(routed.id == "gpt-5.5-codex")
        #expect(routed.provider == "chatgpt-codex")
        #expect(routed.api == "chatgpt-codex")
        #expect(routed.baseURL == "https://chatgpt.com")
        #expect(routed.maxTokens == 0)

        // Same-provider switch (Copilot enterprise) keeps the session baseURL.
        let copilotTemplate = Model(
            id: "gpt-5.5", api: "openai-responses", provider: "github-copilot",
            baseURL: "https://api.business.githubcopilot.com"
        )
        let copilotPick = Model(
            id: "claude-opus-4-8", api: "anthropic-messages", provider: "github-copilot",
            baseURL: "https://api.individual.githubcopilot.com"
        )
        let copilotRouted = adoptFields(from: copilotTemplate, into: copilotPick)
        #expect(copilotRouted.provider == "github-copilot")
        #expect(copilotRouted.api == "anthropic-messages")
        #expect(copilotRouted.baseURL == "https://api.business.githubcopilot.com")
    }

    @Test("adoptFields keeps per-model compat + thinkingLevelMap")
    func adoptFieldsKeepsCompat() {
        var compat = ModelCompat()
        compat.thinkingFormat = "openrouter"
        let template = Model(
            id: "anthropic/claude-sonnet-5", api: "openai-completions",
            provider: "openrouter", baseURL: "https://openrouter.ai/api/v1"
        )
        let picked = Model(
            id: "z-ai/glm-5.2", api: "openai-completions",
            provider: "openrouter", baseURL: "https://openrouter.ai/api/v1",
            compat: compat, thinkingLevelMap: ["xhigh": "xhigh"]
        )
        let routed = adoptFields(from: template, into: picked)
        #expect(routed.compat?.thinkingFormat == "openrouter")
        #expect(routed.thinkingLevelMap == ["xhigh": "xhigh"])
    }
}
