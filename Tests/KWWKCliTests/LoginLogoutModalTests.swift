import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

// Modal `/login` / logged-out coverage: the provider picker + API-key form
// run as modals inside the live TUI (no suspend), the CLI starts without
// credentials, and `/logout` of the last provider returns to that state.

@Suite("modal /login + logged-out session", .serialized)
struct LoginLogoutModalTests {

    // MARK: - /login opens the provider picker modal

    @MainActor
    @Test("/login opens a provider-picker modal listing the login entries")
    func loginOpensPickerModal() async {
        let (ctx, harness) = await makeContext(authResolvers: SessionAuthResolvers())
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)

        await registry.find("login")?.handler(ctx, "")
        #expect(ctx.modal.isOpen, "/login should open the picker modal, not suspend the TUI")
        let rendered = (harness.modalLines ?? []).joined(separator: "\n")
        #expect(rendered.contains("Log in to a provider"))
        #expect(rendered.contains("Anthropic OAuth"))
        #expect(rendered.contains("OpenRouter API key"))

        // Esc cancels back to the transcript with a gentle notice.
        ctx.modal.routeCancel()
        #expect(!ctx.modal.isOpen)
        #expect(harness.notified.contains("login cancelled"))
    }

    @MainActor
    @Test("picking an API-key entry swaps the picker for a FormModal")
    func apiKeyEntryOpensForm() async {
        let (ctx, harness) = await makeContext(authResolvers: SessionAuthResolvers())
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)
        await registry.find("login")?.handler(ctx, "")

        // Move to the OpenRouter entry and confirm.
        guard let index = loginProviders.firstIndex(where: { $0.id == "openrouter" }) else {
            Issue.record("openrouter login entry missing")
            return
        }
        for _ in 0..<index { ctx.modal.routeDown() }
        ctx.modal.routeConfirm()

        #expect(ctx.modal.isOpen, "the API-key form replaces the picker in place")
        let rendered = (harness.modalLines ?? []).joined(separator: "\n")
        #expect(rendered.contains("OpenRouter API key"))
        #expect(rendered.contains("Enter: submit"))

        // Typed input is consumed by the form (never falls through to the
        // prompt box) and cancelling notifies without side effects.
        #expect(ctx.modal.routeText("sk-or-v1-abc"))
        ctx.modal.routeCancel()
        #expect(!ctx.modal.isOpen)
        #expect(harness.notified.contains("login cancelled"))
    }

    @MainActor
    @Test("picking an OAuth entry closes the picker and suspends the TUI for the handoff")
    func oauthEntrySuspendsTUI() async {
        // Stub records the suspension but never runs the body — the real
        // browser OAuth flow must not start in a test.
        let probe = SuspendProbe()
        let (ctx, _) = await makeContext(
            authResolvers: SessionAuthResolvers(),
            withSuspendedTUI: { _ in probe.count += 1 }
        )
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)
        await registry.find("login")?.handler(ctx, "")
        #expect(ctx.modal.isOpen)

        guard let index = loginProviders.firstIndex(where: { $0.id == "anthropic" }) else {
            Issue.record("anthropic login entry missing")
            return
        }
        guard case .oauth = loginProviders[index].flow else {
            Issue.record("anthropic login entry is no longer an OAuth flow")
            return
        }
        for _ in 0..<index { ctx.modal.routeDown() }
        ctx.modal.routeConfirm()

        // The picker closed before the handoff (the sub-flow owns the screen).
        #expect(!ctx.modal.isOpen)
        // The handoff runs on a spawned MainActor task — yield until the stub
        // records the suspension.
        for _ in 0..<1000 where probe.count == 0 {
            await Task.yield()
        }
        #expect(probe.count == 1, "the OAuth leg must run inside withSuspendedTUI")
        // With the body skipped there's no credential to activate — the
        // handler returns without registering or notifying a success.
        #expect(ctx.sessionProviders.slots.isEmpty)
    }

    // MARK: - API-key modal path registers a provider slot

    @MainActor
    @Test("completeAPIKeyLogin persists creds, registers a slot, and activates the first login")
    func apiKeyLoginRegistersSlot() async throws {
        try await withSharedAPIRegistry {
            await APIRegistry.shared.unregisterScope("openrouter")
            let store = try tempStore()
            let authResolvers = SessionAuthResolvers()
            let (ctx, harness) = await makeContext(authResolvers: authResolvers)
            let sentinel = ctx.agent.state.model
            #expect(ctx.sessionProviders.slots.isEmpty)

            await completeAPIKeyLogin(
                values: ["apiKey": "sk-or-test", "defaultModel": "z-ai/glm-5.2"],
                storeId: "openrouter",
                extrasKeys: ["defaultModel"],
                ctx: ctx,
                authResolvers: authResolvers,
                store: store
            )

            // Credentials persisted (additively) under the store id.
            #expect(await store.get("openrouter")?.access == "sk-or-test")
            // A live provider slot exists for /model.
            let slot = ctx.sessionProviders.slot(forStoreId: "openrouter")
            #expect(slot != nil)
            #expect(slot?.template.provider == "openrouter")
            // First-login activation: the logged-out session switched onto the
            // fresh provider's template so the user can prompt immediately.
            #expect(ctx.agent.state.model.id == "z-ai/glm-5.2")
            #expect(ctx.agent.state.model.provider == "openrouter")
            #expect(ctx.agent.state.model.id != sentinel.id)
            #expect(harness.notified.contains("now on z-ai/glm-5.2"))
            // Confirmation went through notify, not stdout.
            #expect(harness.notified.contains("saved openrouter credentials"))
            await APIRegistry.shared.unregisterScope("openrouter")
        }
    }

    @MainActor
    @Test("a second-provider login stays passive (no model switch) and hints at /model")
    func secondLoginDoesNotSwitch() async throws {
        try await withSharedAPIRegistry {
            await APIRegistry.shared.unregisterScope("openrouter")
            let store = try tempStore()
            let authResolvers = SessionAuthResolvers()
            let (ctx, harness) = await makeContext(authResolvers: authResolvers)
            // Simulate an already-logged-in session on another provider.
            let incumbent = Model(id: "claude", api: "anthropic-messages", provider: "anthropic")
            ctx.sessionProviders.upsert(ProviderSlot(
                storeId: "anthropic", catalogProvider: "anthropic",
                displayName: "Anthropic", template: incumbent
            ))
            ctx.agent.state.model = incumbent

            await completeAPIKeyLogin(
                values: ["apiKey": "sk-or-test", "defaultModel": "z-ai/glm-5.2"],
                storeId: "openrouter",
                extrasKeys: ["defaultModel"],
                ctx: ctx,
                authResolvers: authResolvers,
                store: store
            )

            #expect(ctx.sessionProviders.slots.count == 2)
            #expect(ctx.agent.state.model.id == "claude", "an additive login must not steal the active model")
            #expect(harness.notified.contains("/model to switch"))
            await APIRegistry.shared.unregisterScope("openrouter")
        }
    }

    // MARK: - Same-scope dedup (dual login on one vendor)

    @MainActor
    @Test("a same-scope api-key login is saved but doesn't clobber the active slot")
    func sameScopeLoginIsShadowed() async throws {
        let store = try tempStore()
        let authResolvers = SessionAuthResolvers()
        let (ctx, harness) = await makeContext(authResolvers: authResolvers)
        // Active Anthropic OAuth slot — its template.provider owns the
        // `anthropic` scope the api-key login would also register under.
        let incumbent = Model(id: "claude", api: "anthropic-messages", provider: "anthropic")
        ctx.sessionProviders.upsert(ProviderSlot(
            storeId: "anthropic", catalogProvider: "anthropic",
            displayName: "Anthropic", template: incumbent
        ))
        ctx.agent.state.model = incumbent

        await completeAPIKeyLogin(
            values: ["apiKey": "sk-ant-test"],
            storeId: "anthropic-api-key",
            extrasKeys: ["baseUrl"],
            ctx: ctx,
            authResolvers: authResolvers,
            store: store
        )

        // Credentials saved on disk for the next launch's priority ordering…
        #expect(await store.get("anthropic-api-key")?.access == "sk-ant-test")
        // …but the dedup guard refused a second slot for the same scope and
        // said so, leaving the active registration untouched.
        #expect(harness.notified.contains("shares a provider slot"))
        #expect(ctx.sessionProviders.slots.map { $0.storeId } == ["anthropic"])
        #expect(ctx.agent.state.model.id == "claude")
        #expect(ctx.agent.state.model.provider == "anthropic")
    }

    @MainActor
    @Test("/logout of a shadowed same-scope login removes only its stored credentials")
    func logoutShadowedLogin() async throws {
        let store = try tempStore()
        try await store.set(
            OAuthCredentials(access: "oauth-token", refresh: "r", expires: .max),
            for: "anthropic"
        )
        try await store.set(
            OAuthCredentials(access: "sk-ant-test", refresh: "", expires: .max),
            for: "anthropic-api-key"
        )
        let authResolvers = SessionAuthResolvers()
        await authResolvers.set(scope: "anthropic") { _, _ in
            ResolvedProviderAuth(token: "live-token", scheme: .bearer)
        }
        let (ctx, harness) = await makeContext(authResolvers: authResolvers)
        let incumbent = Model(id: "claude", api: "anthropic-messages", provider: "anthropic")
        ctx.sessionProviders.upsert(ProviderSlot(
            storeId: "anthropic", catalogProvider: "anthropic",
            displayName: "Anthropic", template: incumbent
        ))
        ctx.agent.state.model = incumbent

        // The api-key login never owned a session slot (it was shadowed by
        // the OAuth login on the same scope) — logging it out must only
        // remove its store entry.
        await performLogout(ctx, "anthropic-api-key", store: store)

        #expect(await store.get("anthropic-api-key") == nil)
        #expect(await store.get("anthropic")?.access == "oauth-token")
        #expect(harness.notified.contains("was shadowed by a same-vendor login"))
        // The active slot, model, and resolver are untouched.
        #expect(ctx.sessionProviders.slot(forStoreId: "anthropic") != nil)
        #expect(ctx.agent.state.model.id == "claude")
        #expect(try await authResolvers.resolve(incumbent, nil)?.token == "live-token")
    }

    @MainActor
    @Test("completeAPIKeyLogin without an apiKey value errors and registers nothing")
    func apiKeyLoginRequiresKey() async throws {
        let store = try tempStore()
        let authResolvers = SessionAuthResolvers()
        let (ctx, harness) = await makeContext(authResolvers: authResolvers)
        await completeAPIKeyLogin(
            values: [:], storeId: "openrouter", extrasKeys: [],
            ctx: ctx, authResolvers: authResolvers, store: store
        )
        #expect(await store.get("openrouter") == nil)
        #expect(ctx.sessionProviders.slots.isEmpty)
        #expect(harness.notified.contains("API key required"))
    }

    // MARK: - Logged-out submit gating

    @MainActor
    @Test("logged-out prompt submission is gated with a /login notice")
    func loggedOutSubmitGate() async {
        let providers = SessionProviders()
        var committed: [String] = []
        let blocked = gatePromptWhenLoggedOut(
            sessionProviders: providers,
            commit: { committed.append(contentsOf: $0) }
        )
        #expect(blocked, "empty slot list must block the turn")
        #expect(committed.joined().contains("/login to sign in"))

        // With a provider slot the gate is transparent (no output).
        providers.upsert(ProviderSlot(
            storeId: "anthropic", catalogProvider: "anthropic",
            displayName: "Anthropic",
            template: Model(id: "claude", api: "anthropic-messages", provider: "anthropic")
        ))
        committed.removeAll()
        let open = gatePromptWhenLoggedOut(
            sessionProviders: providers,
            commit: { committed.append(contentsOf: $0) }
        )
        #expect(!open)
        #expect(committed.isEmpty)
    }

    @MainActor
    @Test("/model on a logged-out session points at /login instead of a dead fallback")
    func modelCommandLoggedOut() async {
        let (ctx, harness) = await makeContext(authResolvers: SessionAuthResolvers())
        ctx.agent.state.model = loggedOutModel
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)
        await registry.find("model")?.handler(ctx, "")
        #expect(!ctx.modal.isOpen)
        #expect(harness.notified.contains("no provider configured — /login to sign in"))
    }

    // MARK: - --context-1m threading through /login

    @MainActor
    @Test("--context-1m is forwarded into a provider registered via /login")
    func context1mForwardedThroughLogin() async throws {
        try await withSharedAPIRegistry {
            await APIRegistry.shared.unregisterScope("anthropic")
            let store = try tempStore()
            // Never-expiring sentinel credentials so registration doesn't attempt
            // a token refresh.
            try await store.set(
                OAuthCredentials(access: "fake-token", refresh: "", expires: .max),
                for: "anthropic"
            )

            // The beta flips the Anthropic OAuth template's contextWindow off its
            // catalog value — pin it with a model whose catalog window is NOT
            // already 1M, so the two flag states are distinguishable.
            let with1m = try await registerStored(
                storeId: "anthropic", store: store,
                modelOverride: "claude-haiku-4-5", context1m: true
            )
            #expect(with1m?.model.contextWindow == 1_000_000)
            let without1m = try await registerStored(
                storeId: "anthropic", store: store,
                modelOverride: "claude-haiku-4-5", context1m: false
            )
            #expect(without1m?.model.contextWindow == 200_000)

            // Full chain: a session launched with --context-1m carries the flag on
            // its SlashContext; activateFreshLogin must forward it through
            // registerStoredProviderLive so the freshly-registered provider's
            // `anthropic-beta` header opts into the 1M beta.
            let authResolvers = SessionAuthResolvers()
            let (ctx, _) = await makeContext(authResolvers: authResolvers, context1m: true)
            await activateFreshLogin(
                storeId: "anthropic", ctx: ctx, authResolvers: authResolvers, store: store
            )
            let slot = ctx.sessionProviders.slot(forStoreId: "anthropic")
            #expect(slot?.template.provider == "anthropic")
            #expect(slot?.template.contextWindow == 1_000_000)
            let provider = await APIRegistry.shared.provider(
                scope: "anthropic", api: "anthropic-messages"
            ) as? AnthropicProvider
            #expect(provider?.extraHeaders["anthropic-beta"]?.contains("context-1m-2025-08-07") == true)
            await APIRegistry.shared.unregisterScope("anthropic")
        }
    }

    // MARK: - /logout of the last provider

    @MainActor
    @Test("/logout of the last provider returns to the logged-out sentinel state")
    func logoutLastProvider() async throws {
        try await withSharedAPIRegistry {
            await APIRegistry.shared.unregisterScope("openrouter")
            let store = try tempStore()
            try await store.set(
                OAuthCredentials(access: "sk-or-test", refresh: "", expires: .max),
                for: "openrouter"
            )
            let authResolvers = SessionAuthResolvers()
            let (ctx, harness) = await makeContext(authResolvers: authResolvers)
            let template = Model(
                id: "z-ai/glm-5.2", api: "openai-completions", provider: "openrouter",
                baseURL: "https://openrouter.ai/api/v1"
            )
            ctx.sessionProviders.upsert(ProviderSlot(
                storeId: "openrouter", catalogProvider: "openrouter",
                displayName: "OpenRouter", template: template
            ))
            ctx.agent.state.model = template

            await performLogout(ctx, "openrouter", store: store)

            #expect(await store.all().isEmpty)
            #expect(ctx.sessionProviders.slots.isEmpty)
            // Back on the sentinel: empty id/provider, gated until the next /login.
            #expect(ctx.agent.state.model.provider.isEmpty)
            #expect(ctx.agent.state.model.id.isEmpty)
            #expect(harness.notified.contains("no providers left; /login to sign in"))

            // The prompt gate re-engages against the emptied slot list.
            var committed: [String] = []
            #expect(gatePromptWhenLoggedOut(
                sessionProviders: ctx.sessionProviders,
                commit: { committed.append(contentsOf: $0) }
            ))
        }
    }

    // MARK: - Helpers

    private func tempStore() throws -> OAuthStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-login-modal-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try OAuthStore(url: dir.appendingPathComponent("oauth.json"))
    }

    /// SlashContext wired to a recording modal host + notifier. The faux
    /// provider only backs `ctx.agent`; sessionProviders starts empty so the
    /// context models a logged-out session unless a test seeds slots.
    /// `withSuspendedTUI` defaults to the passthrough SlashContext ships with;
    /// the OAuth-branch test injects a recording stub that skips the body.
    @MainActor
    private func makeContext(
        authResolvers: SessionAuthResolvers,
        context1m: Bool = false,
        withSuspendedTUI: @MainActor @escaping (
            _ body: @escaping @MainActor () async -> Void
        ) async -> Void = { body in await body() }
    ) async -> (SlashContext, LoginTestHarness) {
        let faux = await registerFauxProvider()
        _ = faux
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))
        let harness = LoginTestHarness()
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-login-modal-bg-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let modal = ModalHost(
            renderModalLines: { lines in harness.modalLines = lines },
            restoreTranscript: {},
            requestRender: {}
        )
        let ctx = SlashContext(
            agent: agent,
            modal: modal,
            backgroundManager: BackgroundTaskManager(outputDir: outputDir),
            sessionId: "sess",
            notifyBlock: { lines in harness.notifiedLines.append(contentsOf: lines) },
            commitScrollback: { _ in },
            refreshTranscript: {},
            sessionProviders: SessionProviders(),
            authResolvers: authResolvers,
            context1m: context1m,
            withSuspendedTUI: withSuspendedTUI
        )
        return (ctx, harness)
    }
}

/// Counts `withSuspendedTUI` invocations for the OAuth-branch test.
@MainActor
private final class SuspendProbe {
    var count = 0
}

/// Records what the modal host rendered and what the handlers notified.
@MainActor
private final class LoginTestHarness {
    var modalLines: [String]?
    var notifiedLines: [String] = []
    var notified: String { notifiedLines.joined(separator: "\n") }
}
