import Foundation
import Testing
@testable import KWWKAI

/// Minimal `APIProvider` whose only job is to be identifiable by a tag so
/// dispatch can be asserted.
private final class TaggedProvider: APIProvider, @unchecked Sendable {
    let api: String
    let tag: String
    init(api: String, tag: String) {
        self.api = api
        self.tag = tag
    }
    func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        AssistantMessageStream()
    }
}

@Suite("APIRegistry provider-scoped dispatch")
struct APIRegistryScopeTests {

    @Test("provider-scoped registrations sharing one wire api don't collide")
    func scopedCollision() async {
        let registry = APIRegistry()
        // Two providers both speaking `anthropic-messages` — Anthropic-OAuth
        // and Copilot's Claude route — must coexist keyed by provider scope.
        await registry.register(TaggedProvider(api: "anthropic-messages", tag: "anthropic-oauth"), scope: "anthropic")
        await registry.register(TaggedProvider(api: "anthropic-messages", tag: "copilot"), scope: "github-copilot")

        let a = await registry.provider(scope: "anthropic", api: "anthropic-messages") as? TaggedProvider
        let c = await registry.provider(scope: "github-copilot", api: "anthropic-messages") as? TaggedProvider
        #expect(a?.tag == "anthropic-oauth")
        #expect(c?.tag == "copilot")
    }

    @Test("scoped lookup falls back to the flat api map")
    func scopedFallsBackToFlat() async {
        let registry = APIRegistry()
        // Flat (env-key style) registration, no scope.
        await registry.register(TaggedProvider(api: "openai-responses", tag: "flat"))
        // An unknown scope still resolves the flat provider.
        let p = await registry.provider(scope: "some-scope", api: "openai-responses") as? TaggedProvider
        #expect(p?.tag == "flat")
        // And a scoped entry wins over the flat one for its own scope.
        await registry.register(TaggedProvider(api: "openai-responses", tag: "scoped"), scope: "github-copilot")
        let scoped = await registry.provider(scope: "github-copilot", api: "openai-responses") as? TaggedProvider
        #expect(scoped?.tag == "scoped")
        let stillFlat = await registry.provider(scope: "openai", api: "openai-responses") as? TaggedProvider
        #expect(stillFlat?.tag == "flat")
    }

    @Test("unregisterScope removes only that scope's entries")
    func unregisterScope() async {
        let registry = APIRegistry()
        await registry.register(TaggedProvider(api: "anthropic-messages", tag: "anthropic"), scope: "anthropic")
        await registry.register(TaggedProvider(api: "anthropic-messages", tag: "copilot"), scope: "github-copilot")
        await registry.unregisterScope("github-copilot")
        #expect(await registry.provider(scope: "github-copilot", api: "anthropic-messages") == nil)
        let survivor = await registry.provider(scope: "anthropic", api: "anthropic-messages") as? TaggedProvider
        #expect(survivor?.tag == "anthropic")
    }

    @Test("unregisterSource tears down both flat and scoped entries")
    func unregisterSource() async {
        let registry = APIRegistry()
        await registry.register(TaggedProvider(api: "openai-completions", tag: "flat"), sourceId: "src")
        await registry.register(TaggedProvider(api: "anthropic-messages", tag: "scoped"), scope: "anthropic", sourceId: "src")
        await registry.unregisterSource("src")
        #expect(await registry.provider(for: "openai-completions") == nil)
        #expect(await registry.provider(scope: "anthropic", api: "anthropic-messages") == nil)
    }
}
