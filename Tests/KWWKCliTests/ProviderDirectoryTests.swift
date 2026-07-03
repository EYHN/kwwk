import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKCli

/// Pins every value the provider directory derives — priority order, wire
/// scope, catalog key, display name, login form title, and the reverse
/// scope → catalog mapping — against the literals the hand-maintained tables
/// held before consolidation, so a directory edit can't silently reroute or
/// relabel an existing provider.
@Suite("provider directory")
struct ProviderDirectoryTests {

    /// (storeId, scope, catalogKey, displayName, formTitle) for every entry.
    private static let expected: [(String, String, String, String, String?)] = [
        ("openai-codex", "chatgpt-codex", "openai-codex", "ChatGPT Codex", nil),
        ("anthropic", "anthropic", "anthropic", "Anthropic (Claude Pro/Max)", nil),
        ("anthropic-api-key", "anthropic", "anthropic", "Anthropic (API key)", "Anthropic API key"),
        ("openai-api-key", "openai", "openai", "OpenAI (API key)", "OpenAI API key"),
        ("openai-compatible", "openai-compatible", "openai-compatible", "OpenAI-compatible", "OpenAI-compatible endpoint"),
        ("google-api-key", "google", "google", "Google AI Studio", "Google AI Studio API key"),
        ("openrouter", "openrouter", "openrouter", "OpenRouter", "OpenRouter API key"),
        ("github-copilot", "github-copilot", "github-copilot", "GitHub Copilot", nil),
    ]

    @Test("directory order is the stored-provider priority order")
    func priorityOrder() {
        #expect(providerDirectory.map(\.storeId) == Self.expected.map(\.0))
        // storedProviderOrder ranks all known ids by directory order.
        let all = Dictionary(uniqueKeysWithValues: Self.expected.map {
            ($0.0, OAuthCredentials(access: "x", refresh: "", expires: .max))
        })
        #expect(storedProviderOrder(all) == Self.expected.map(\.0))
    }

    @Test("every store id derives its exact pre-consolidation values")
    func derivedValuesMatchLegacyTables() {
        for (storeId, scope, catalogKey, displayName, formTitle) in Self.expected {
            #expect(modelProviderScope(forStoreId: storeId) == scope)
            #expect(catalogProvider(forStoreId: storeId) == catalogKey)
            #expect(providerDisplayName(forStoreId: storeId) == displayName)
            #expect(providerDescriptor(forStoreId: storeId)?.formTitle == formTitle)
            // Reverse mapping: the wire scope resolves back to this entry's
            // catalog key (same-scope pairs share one, so first-match is safe).
            #expect(catalogProviderKey(forAgentProvider: scope) == catalogKey)
        }
    }

    @Test("login form titles derive from the descriptor")
    func loginFormTitles() {
        for entry in loginProviders {
            guard case .apiKey = entry.flow else { continue }
            let formTitle = providerDescriptor(forStoreId: entry.id)?.formTitle
            #expect(formTitle != nil)
            #expect(loginFormTitle(for: entry) == "Log in — " + (formTitle ?? entry.id))
        }
    }

    @Test("unknown ids and env: sentinels keep their fallbacks")
    func fallbacks() {
        #expect(modelProviderScope(forStoreId: "future-provider") == "future-provider")
        #expect(catalogProvider(forStoreId: "future-provider") == "future-provider")
        #expect(providerDisplayName(forStoreId: "future-provider") == "future-provider")
        #expect(providerDisplayName(forStoreId: "env:groq") == "groq (env)")
        #expect(catalogProviderKey(forAgentProvider: "groq") == "groq")
        // Unknown stored ids sort after every known one.
        let all: [String: OAuthCredentials] = [
            "zz-unknown": .init(access: "x", refresh: "", expires: .max),
            "aa-unknown": .init(access: "x", refresh: "", expires: .max),
            "github-copilot": .init(access: "x", refresh: "", expires: .max),
        ]
        #expect(storedProviderOrder(all) == ["github-copilot", "aa-unknown", "zz-unknown"])
    }

    @Test("/model toast display names come from ProviderAttribution for every scope")
    func toastNamesAreCanonical() {
        // Every scope the directory can put on a live model must resolve to a
        // human name (no raw-id fallback) — the welcome header and the /model
        // toast now share this single table.
        #expect(ProviderAttribution.getProviderDisplayName("chatgpt-codex") == "ChatGPT Codex")
        #expect(ProviderAttribution.getProviderDisplayName("openai-codex") == "ChatGPT Codex")
        #expect(ProviderAttribution.getProviderDisplayName("anthropic") == "Anthropic")
        #expect(ProviderAttribution.getProviderDisplayName("openai") == "OpenAI")
        #expect(ProviderAttribution.getProviderDisplayName("google") == "Google Gemini")
        #expect(ProviderAttribution.getProviderDisplayName("openai-compatible") == "OpenAI-compatible")
        #expect(ProviderAttribution.getProviderDisplayName("openrouter") == "OpenRouter")
        #expect(ProviderAttribution.getProviderDisplayName("github-copilot") == "GitHub Copilot")
        for descriptor in providerDirectory {
            #expect(ProviderAttribution.displayNames[descriptor.scope] != nil)
        }
    }
}
