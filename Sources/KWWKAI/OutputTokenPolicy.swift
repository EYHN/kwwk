/// Normalizes output-token limits before they are placed on a provider wire.
///
/// A catalog's `maxTokens` is normally a model output capability, but some
/// third-party catalogs publish the whole context window in that field. Sending
/// that value verbatim makes every non-empty request impossible because the
/// provider validates `input + output <= contextWindow`. Keeping this policy in
/// KWWKAI lets request encoders and Agent preflight reserve the same value.
public enum OutputTokenPolicy {
    /// OMP applies the same ceiling to OpenAI-style requests. It is high enough
    /// not to turn ordinary generation into a short response, while avoiding
    /// catalog values that several compatible endpoints reject.
    public static let openAIMaximumOutputTokens = 64_000

    /// Whether this route can represent an explicit output limit at all.
    public static func supportsExplicitLimit(for model: Model) -> Bool {
        model.api != "cursor-agent"
            && model.api != "chatgpt-codex"
            && model.api != "openai-codex-responses"
    }

    /// The value an encoder should use when no explicit request limit was
    /// supplied. `nil` intentionally means omit the field from the wire.
    public static func automaticLimit(for model: Model) -> Int? {
        guard supportsExplicitLimit(for: model), !omitsAutomaticLimit(for: model) else {
            return nil
        }
        guard model.maxTokens > 0 else { return nil }
        return maximumAllowedLimit(for: model)
    }

    /// Resolve an optional SDK override. A non-positive explicit value is left
    /// intact so providers with a required positive field can report the same
    /// configuration error they did before; config-layer `0 = automatic`
    /// sentinels must be converted to nil before reaching StreamOptions.
    public static func effectiveLimit(for model: Model, requested: Int?) -> Int? {
        guard let requested else { return automaticLimit(for: model) }
        guard requested > 0 else { return requested }
        guard supportsExplicitLimit(for: model) else { return nil }
        return min(requested, maximumAllowedLimit(for: model))
    }

    /// Highest safe limit this model/route may claim. This also supplies a
    /// deterministic fallback for malformed metadata (`maxTokens >= context`).
    public static func maximumAllowedLimit(for model: Model) -> Int {
        let contextWindow = max(1, model.contextWindow)
        let contextCeiling = max(1, contextWindow - 1)

        let modelCeiling: Int
        if model.maxTokens > 0, model.maxTokens < contextWindow {
            modelCeiling = model.maxTokens
        } else if model.maxTokens >= contextWindow {
            modelCeiling = max(1, contextWindow / 4)
        } else {
            // Zero is an omission sentinel in a few catalogs. It is not a
            // useful automatic limit, but an explicit SDK override can still
            // be bounded by the context window.
            modelCeiling = contextCeiling
        }

        let routeCeiling = usesOpenAIOutputPolicy(model)
            ? min(contextCeiling, openAIMaximumOutputTokens)
            : contextCeiling
        return max(1, min(modelCeiling, routeCeiling))
    }

    public static func isOpenRouter(_ model: Model) -> Bool {
        model.provider.lowercased() == "openrouter"
            || model.baseURL.lowercased().contains("openrouter.ai")
    }

    private static func omitsAutomaticLimit(for model: Model) -> Bool {
        isOpenRouter(model)
    }

    private static func usesOpenAIOutputPolicy(_ model: Model) -> Bool {
        switch model.api {
        case "openai-completions", "openai-responses",
             "azure-openai-responses", "mistral-conversations":
            true
        default:
            false
        }
    }
}
