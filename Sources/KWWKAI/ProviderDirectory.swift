import Foundation

/// One stored provider's identity, in every vocabulary the auth stack speaks:
/// the `OAuthStore` key it persists under, the `model.provider` scope it
/// registers on `APIRegistry`, the `ModelsCatalog.byProvider` key holding its
/// models, and its human-readable labels. Single source of truth — the
/// priority / scope / catalog / display helpers below all derive from
/// `providerDirectory`, so adding a provider is one entry here (plus its
/// `registerStored` case and the CLI's `loginProviders` form fields).
public struct ProviderDescriptor: Sendable {
    /// Key the credentials persist under in `OAuthStore`; also the id the
    /// CLI's `/login` and `/logout` operate on.
    public let storeId: String
    /// The `model.provider` scope the provider registers under on
    /// `APIRegistry` — the key `stream` dispatches on. Intentionally
    /// many-to-one (`anthropic` OAuth and `anthropic-api-key` both drive
    /// Anthropic's `anthropic-messages` wire); `registerAllStored` skips the
    /// later of any collision.
    public let scope: String
    /// The `ModelsCatalog.byProvider` key holding the provider's models —
    /// used to list models for the CLI's `/model` and to match a
    /// `provider/model` override to a logged-in account.
    public let catalogKey: String
    /// Label for the CLI's `/model` group header and `/login` / `/logout`
    /// listings.
    public let displayName: String
    /// Title suffix for the CLI's API-key `FormModal`; nil for OAuth entries,
    /// which never open a form.
    public let formTitle: String?

    public init(
        storeId: String,
        scope: String,
        catalogKey: String,
        displayName: String,
        formTitle: String?
    ) {
        self.storeId = storeId
        self.scope = scope
        self.catalogKey = catalogKey
        self.displayName = displayName
        self.formTitle = formTitle
    }
}

/// Every stored provider the auth stack can register, in deterministic
/// priority order: OAuth subscriptions first, then api keys. The first entry
/// present in the store is the default *active* provider at launch, and the
/// order also breaks same-scope ties (e.g. Anthropic OAuth wins over Anthropic
/// API key). Ids not listed here sort last so they surface a clear "not wired
/// up" notice rather than a silent miss.
public let providerDirectory: [ProviderDescriptor] = [
    ProviderDescriptor(
        storeId: "openai-codex",
        scope: "chatgpt-codex",
        catalogKey: "openai-codex",
        displayName: "ChatGPT Codex",
        formTitle: nil
    ),
    ProviderDescriptor(
        storeId: "anthropic",
        scope: "anthropic",
        catalogKey: "anthropic",
        displayName: "Anthropic (Claude Pro/Max)",
        formTitle: nil
    ),
    ProviderDescriptor(
        storeId: "anthropic-api-key",
        scope: "anthropic",
        catalogKey: "anthropic",
        displayName: "Anthropic (API key)",
        formTitle: "Anthropic API key"
    ),
    ProviderDescriptor(
        storeId: "openai-api-key",
        scope: "openai",
        catalogKey: "openai",
        displayName: "OpenAI (API key)",
        formTitle: "OpenAI API key"
    ),
    ProviderDescriptor(
        storeId: "openai-compatible",
        scope: "openai-compatible",
        catalogKey: "openai-compatible",
        displayName: "OpenAI-compatible",
        formTitle: "OpenAI-compatible endpoint"
    ),
    ProviderDescriptor(
        storeId: "google-api-key",
        scope: "google",
        catalogKey: "google",
        displayName: "Google AI Studio",
        formTitle: "Google AI Studio API key"
    ),
    ProviderDescriptor(
        storeId: "openrouter",
        scope: "openrouter",
        catalogKey: "openrouter",
        displayName: "OpenRouter",
        formTitle: "OpenRouter API key"
    ),
    ProviderDescriptor(
        storeId: "github-copilot",
        scope: "github-copilot",
        catalogKey: "github-copilot",
        displayName: "GitHub Copilot",
        formTitle: nil
    ),
    ProviderDescriptor(
        storeId: "cursor",
        scope: "cursor",
        catalogKey: "cursor",
        displayName: "Cursor",
        formTitle: nil
    ),
    ProviderDescriptor(
        storeId: "kimi-coding",
        scope: "kimi-coding",
        catalogKey: "kimi-coding",
        displayName: "Kimi For Coding",
        formTitle: nil
    ),
    ProviderDescriptor(
        storeId: "zai",
        scope: "zai",
        catalogKey: "zai",
        displayName: "Z.AI Coding Plan",
        formTitle: "Z.AI API key"
    ),
    ProviderDescriptor(
        storeId: "zai-coding-cn",
        scope: "zai-coding-cn",
        catalogKey: "zai-coding-cn",
        displayName: "Z.AI Coding Plan (China)",
        formTitle: "Z.AI API key (China)"
    ),
]

/// Descriptor for a store id, or nil for unknown / `env:` sentinel ids —
/// callers fall back to the raw id so unwired credentials still round-trip.
public func providerDescriptor(forStoreId storeId: String) -> ProviderDescriptor? {
    providerDirectory.first { $0.storeId == storeId }
}

/// The stored provider ids actually present in `all`, in directory priority
/// order, with unknown ids appended (sorted) so they still surface in
/// `/logout` listings and the "not wired up" launch notice.
public func storedProviderOrder(_ all: [String: OAuthCredentials]) -> [String] {
    storedProviderOrder(ids: Array(all.keys))
}

/// Same ordering over a bare id list, for credential sources that can name
/// their providers without materializing every credential
/// (`OAuthCredentialSource.providerIds()`).
public func storedProviderOrder(ids: [String]) -> [String] {
    let present = Set(ids)
    var order = providerDirectory.map(\.storeId).filter { present.contains($0) }
    let known = Set(providerDirectory.map(\.storeId))
    order.append(contentsOf: present.filter { !known.contains($0) }.sorted())
    return order
}

/// The `model.provider` scope a stored provider registers under (see
/// `ProviderDescriptor.scope`). Unknown ids map to themselves so any future
/// 1:1 id keeps working.
public func modelProviderScope(forStoreId storeId: String) -> String {
    providerDescriptor(forStoreId: storeId)?.scope ?? storeId
}

/// The `ModelsCatalog.byProvider` key holding a stored provider's models
/// (see `ProviderDescriptor.catalogKey`). Unknown ids map to themselves.
public func catalogProvider(forStoreId storeId: String) -> String {
    providerDescriptor(forStoreId: storeId)?.catalogKey ?? storeId
}

/// Human-readable label for a stored provider id, shown in the CLI's `/model`
/// group header and `/login` / `/logout` listings. `env:<provider>` sentinel
/// ids (environment-key sessions) label as "<provider> (env)"; anything else
/// unknown falls back to the raw id.
public func providerDisplayName(forStoreId storeId: String) -> String {
    if let descriptor = providerDescriptor(forStoreId: storeId) {
        return descriptor.displayName
    }
    if storeId.hasPrefix("env:") {
        return String(storeId.dropFirst(4)) + " (env)"
    }
    return storeId
}

/// Map an in-session agent `Model.provider` scope back to the key used in
/// `ModelsCatalog.byProvider`. They're mostly identical except for Codex:
/// the chatgpt.com variant registers as `chatgpt-codex` on the agent side,
/// while the catalog lists its models under `openai-codex`.
/// Public so regression tests can pin the mapping.
public func catalogProviderKey(forAgentProvider provider: String) -> String {
    providerDirectory.first { $0.scope == provider }?.catalogKey ?? provider
}
