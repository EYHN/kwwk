import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Antigravity's model list, and how a family's effort picks the id sent.
///
/// The bundled `Resources/antigravity-models.json` is a seed written from
/// the list magpie's `fetchAvailableModels` fixture recorded on 2026-10-20
/// (`internal/provider/testdata/antigravity-models-2026-10-20.json`), one
/// row per family with the effort variants folded into it; it is replaced
/// by a live `fetchAvailableModels` (`AntigravityOAuth.fetchAvailableModels`)
/// before release, and a re-sync is a file edit. Left out of it, as magpie
/// leaves them out: the `chat_*` and `tab_*` ids (Antigravity's editor),
/// `gemini-3.1-flash-image` (image-only), `gemini-2.5-pro` and
/// `gemini-2.5-flash-thinking` (magpie's hidden list), `gemini-2.5-flash` and
/// `gemini-2.5-flash-lite` (retired, listed under the name of the model
/// their users were moved to), `gemini-3-flash-agent` (named like Gemini 3.5
/// Flash (High)), `gemini-3.5-flash-lite` and the unnamed
/// `gemini-3.8-flash-tiered`.
///
/// Antigravity lists some models once for each thinking level it serves
/// them at (`gemini-3.8-flash-low`, `-medium`, `-high`, named "Gemini 3.8
/// Flash (Low)" …), so a client that also picks an effort had two to pick.
/// kwwk offers such a family as one model whose `thinkingLevelMap` maps each
/// level the family has to the variant id Antigravity serves it as, and the
/// request goes out under the id the effort picks (`variantId`). Which level
/// a variant is at is what Antigravity's name for it says, where the names
/// say one each: `gemini-3.5-flash-extra-low` is "(Low)" and
/// `gemini-3.5-flash-low` "(Medium)" (magpie `antigravity_models.go`).
public enum AntigravityModels {
    public static let api = "antigravity-codeassist"
    public static let provider = "antigravity"
    /// Antigravity's own default (`defaultAgentModelId`), as its family.
    public static let defaultModelId = "gemini-3.8-flash"

    static let defaultContextWindow = 1_048_576
    static let defaultMaxTokens = 65_536

    /// Where a request goes.
    public static var baseURL: String { AntigravityOAuth.dailyHost }

    /// The id a request for `model` goes out under: the variant the effort
    /// picks for a model that is a family of levels (the nearest level the
    /// family has, as `clampThinkingLevel` finds it), the family's default
    /// when no level is asked — high, what Gemini 3 thinks at when it isn't
    /// told a level, else the highest there is — and the model's own id
    /// when it stands for no variants.
    public static func variantId(model: Model, reasoning: ReasoningLevel?) -> String {
        guard let map = model.thinkingLevelMap, map.values.contains(where: { $0 != nil }) else { return model.id }
        if let reasoning {
            return resolveThinkingLevel(model, ModelThinkingLevel(reasoning: reasoning)) ?? model.id
        }
        for level in [ModelThinkingLevel.high, .max, .xhigh, .medium, .low, .minimal] {
            if let id = map[level.rawValue] ?? nil { return id }
        }
        return model.id
    }

    /// The level an id of Antigravity's own says it thinks at, nil for one
    /// that says none: a variant of `model`'s family (the one level of its
    /// map that names the id), or of any family the bundled catalog has, for
    /// a caller that asks for the variant by its own id. A `-tiered` id, one
    /// id that thinks at the level the request asks, names every level and
    /// so says none.
    public static func levelSaid(by id: String, model: Model) -> ModelThinkingLevel? {
        if let map = model.thinkingLevelMap { return levelSaid(by: id, in: map, family: model.id) }
        for family in ModelsCatalog.models(for: provider) {
            if let map = family.thinkingLevelMap, let level = levelSaid(by: id, in: map, family: family.id) {
                return level
            }
        }
        return nil
    }

    private static func levelSaid(by id: String, in map: [String: String?], family: String) -> ModelThinkingLevel? {
        guard id != family else { return nil }
        let levels = map.compactMap { key, value -> ModelThinkingLevel? in
            value == id ? ModelThinkingLevel(rawValue: key) : nil
        }
        return levels.count == 1 ? levels[0] : nil
    }
}

/// The catalog row for an Antigravity model id, or a usable fallback for ids
/// the bundled seed doesn't carry (each plan lists its own).
public func antigravityModel(id: String) -> Model {
    if let catalog = ModelsCatalog.model(provider: AntigravityModels.provider, id: id) { return catalog }
    let lower = id.lowercased()
    return Model(
        id: id,
        name: id,
        api: AntigravityModels.api,
        provider: AntigravityModels.provider,
        baseURL: AntigravityModels.baseURL,
        reasoning: !lower.hasPrefix("gpt-oss") && !(lower.contains("claude") && !lower.contains("thinking")),
        input: lower.hasPrefix("gpt-oss") ? [.text] : [.text, .image],
        contextWindow: lower.contains("claude") ? 250_000 : AntigravityModels.defaultContextWindow,
        maxTokens: lower.contains("claude") ? 64_000 : AntigravityModels.defaultMaxTokens
    )
}

// MARK: - Stored login

/// Register the stored Antigravity login (`registerStored`'s `"antigravity"`
/// case).
func registerAntigravity(
    manager: OAuthManager,
    modelOverride: String? = nil,
    primeToken: Bool = true
) async -> ResolvedAuth {
    // Prime the token only for the active provider; the resolver refreshes
    // lazily on the first request for the others.
    if primeToken {
        _ = try? await manager.apiKey(for: AntigravityModels.provider)
    }
    await APIRegistry.shared.register(AntigravityProvider(), scope: AntigravityModels.provider)
    let model = antigravityModel(id: modelOverride ?? AntigravityModels.defaultModelId)
    return ResolvedAuth(
        model: model,
        modelLabel: "\(model.id) · Antigravity",
        authResolver: antigravityAuthResolver(manager: manager)
    )
}

/// An Antigravity request needs more than its token: the Google Cloud
/// project the login was given goes in the envelope. It rides along on the
/// resolved auth, with the rest of what the sign-in found.
func antigravityAuthResolver(
    manager: OAuthManager
) -> @Sendable (Model, String?) async throws -> ResolvedProviderAuth? {
    { _, _ in
        do {
            let authorization = try await manager.authorization(for: AntigravityModels.provider)
            guard let credentials = try await manager.credentials(for: AntigravityModels.provider) else { return nil }
            return ResolvedProviderAuth(
                token: authorization.apiKey,
                scheme: .bearer,
                metadata: credentials.extras.filter { ["projectId", "email", "tier", "paidTier"].contains($0.key) },
                onRejected: authorization.onRejected
            )
        } catch OAuthError.missing, OAuthError.unknownProvider {
            // Not logged in ⇒ anonymous; any other failure propagates.
            return nil
        }
    }
}
