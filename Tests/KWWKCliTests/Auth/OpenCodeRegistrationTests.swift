import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKCli

@Suite("OpenCode registration")
struct OpenCodeRegistrationTests {
    private func store(_ credentials: OAuthCredentials, for id: String) async throws -> OAuthStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-opencode-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try OAuthStore(url: dir.appendingPathComponent("oauth.json"))
        try await store.set(credentials, for: id)
        return store
    }

    private static let key = OAuthCredentials(access: "oc_sk_test", refresh: "", expires: .max)

    @Test("registerStored puts every wire of the plan under its own scope", arguments: [
        ("opencode-go", "glm-5.2", "OpenCode Go"),
        ("opencode", "claude-sonnet-5", "OpenCode Zen"),
    ])
    func registerStoredOpenCode(id: String, defaultModel: String, name: String) async throws {
        try await withSharedAPIRegistry {
            await APIRegistry.shared.unregisterScope(id)
            let store = try await store(Self.key, for: id)
            let resolved = try #require(try await registerStored(storeId: id, store: store))
            let catalog = try #require(ModelsCatalog.model(provider: id, id: defaultModel))
            #expect(resolved.model.id == defaultModel)
            #expect(resolved.model.api == catalog.api)
            #expect(resolved.model.provider == id)
            #expect(resolved.model.baseURL == OpenCodePlan.plan(id: id)?.rootURL)
            #expect(resolved.model.compat == catalog.compat)
            #expect(resolved.modelLabel == "\(defaultModel) · \(name)")
            // The key travels with the resolution, not the shared providers:
            // registering the plan again for another key leaves it alone.
            let auth = try #require(try await resolved.authResolver?(resolved.model, nil))
            #expect(auth.token == Self.key.access)
            #expect(auth.scheme == .bearer)
            _ = await registerOpenCode(plan: try #require(OpenCodePlan.plan(id: id)), apiKey: "oc_sk_other")
            #expect(try await resolved.authResolver?(resolved.model, nil)?.token == Self.key.access)
            for api in OpenCodePlan.wires {
                #expect(await APIRegistry.shared.provider(scope: id, api: api) is OpenCodeRequestProvider)
            }
            await APIRegistry.shared.unregisterScope(id)
        }
    }

    @Test("catalog models keep their wire, a stored default is used, an unknown id rides Chat Completions")
    func modelChoice() async throws {
        try await withSharedAPIRegistry {
            let id = OpenCodePlan.go.id
            let store = try await store(OAuthCredentials(
                access: "oc_sk_test",
                refresh: "",
                expires: .max,
                extras: ["defaultModel": .string("claude-haiku-5-5")]
            ), for: id)
            for (model, api) in [
                ("glm-5.2", "openai-completions"),
                ("grok-4.7", "openai-responses"),
                ("claude-haiku-5-5", "anthropic-messages"),
                ("gemini-4-argon", "google-generative-ai"),
            ] {
                let resolved = try #require(try await registerStored(storeId: id, store: store, modelOverride: model))
                #expect(resolved.model.api == api)
                #expect(resolved.model.baseURL == OpenCodePlan.go.rootURL)
            }
            let stored = try #require(try await registerStored(storeId: id, store: store))
            #expect(stored.model.id == "claude-haiku-5-5")

            let unknown = try #require(try await registerStored(storeId: id, store: store, modelOverride: "future-model"))
            #expect(unknown.model.api == "openai-completions")
            #expect(unknown.model.reasoning == false)
            #expect(unknown.model.input == [.text])
            #expect(unknown.model.compat?.maxTokensField == "max_tokens")
            await APIRegistry.shared.unregisterScope(id)
        }
    }

    @Test("an OPENCODE_API_KEY session goes through the plan's gateway")
    func environmentKey() async throws {
        try await withSharedAPIRegistry {
            await APIRegistry.shared.unregisterScope(OpenCodePlan.go.id)
            let resolved = try #require(await resolveEnvAuth(
                modelOverride: "opencode-go/glm-5.2",
                environment: ["OPENCODE_API_KEY": "oc_sk_env"]
            ))
            #expect(resolved.model.id == "glm-5.2")
            #expect(resolved.model.provider == OpenCodePlan.go.id)
            #expect(resolved.model.baseURL == OpenCodePlan.go.rootURL)
            #expect(resolved.modelLabel == "glm-5.2 · OpenCode Go (env)")
            let registered = await APIRegistry.shared.provider(scope: OpenCodePlan.go.id, api: "openai-completions")
            #expect(registered is OpenCodeRequestProvider)
            await APIRegistry.shared.unregisterScope(OpenCodePlan.go.id)
        }
    }

    @Test("both plans are API-key logins in the login list and the provider directory")
    func listed() {
        for (id, name) in [("opencode-go", "OpenCode Go"), ("opencode", "OpenCode Zen")] {
            guard case .apiKey(let fields, let extrasKeys)? = loginProviders.first(where: { $0.id == id })?.flow else {
                Issue.record("\(id) has no API-key login")
                continue
            }
            #expect(fields.map(\.key) == ["apiKey", "defaultModel"])
            #expect(fields.map(\.required) == [true, false])
            #expect(extrasKeys == ["defaultModel"])
            #expect(providerDisplayName(forStoreId: id) == name)
            #expect(ProviderAttribution.displayNames[id] == name)
        }
    }
}
