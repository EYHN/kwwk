import Foundation

public enum InputModality: String, Codable, Sendable, Hashable {
    case text
    case image
}

public struct ModelCostTier: Codable, Sendable, Hashable {
    /// Apply this tier when total input usage is strictly above the threshold.
    public var inputTokensAbove: Int
    /// USD per 1M tokens.
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(
        inputTokensAbove: Int,
        input: Double,
        output: Double,
        cacheRead: Double,
        cacheWrite: Double
    ) {
        self.inputTokensAbove = inputTokensAbove
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

public struct ModelCost: Codable, Sendable, Hashable {
    /// USD per 1M tokens.
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    /// Request-wide pricing tiers. The highest matching threshold applies to
    /// every token in the request, not only the tokens above the threshold.
    public var tiers: [ModelCostTier]?

    public init(
        input: Double = 0,
        output: Double = 0,
        cacheRead: Double = 0,
        cacheWrite: Double = 0,
        tiers: [ModelCostTier]? = nil
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.tiers = tiers
    }
}

public struct Model: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// Opaque API identifier (e.g., "anthropic-messages", "openai-responses", "faux:xyz").
    public var api: String
    public var provider: String
    public var baseURL: String
    public var reasoning: Bool
    public var input: [InputModality]
    public var cost: ModelCost
    public var contextWindow: Int
    public var maxTokens: Int
    public var headers: [String: String]?
    /// Per-API compatibility overrides (cache format, thinking format, store
    /// support, etc.). nil = auto-detect from baseURL / provider defaults.
    public var compat: ModelCompat?
    /// Maps pi thinking levels (off/minimal/low/medium/high/xhigh/max) to
    /// provider/model-specific wire values. A `.some(nil)` entry marks a level
    /// as unsupported; a missing key uses provider defaults.
    public var thinkingLevelMap: [String: String?]?

    /// The wire/persisted key stays "baseUrl" (models.json, pi parity);
    /// only the Swift property follows Foundation's URL casing.
    enum CodingKeys: String, CodingKey {
        case id, name, api, provider
        case baseURL = "baseUrl"
        case reasoning, input, cost, contextWindow, maxTokens, headers, compat, thinkingLevelMap
    }

    public init(
        id: String,
        name: String? = nil,
        api: String,
        provider: String,
        baseURL: String = "",
        reasoning: Bool = false,
        input: [InputModality] = [.text],
        cost: ModelCost = .init(),
        contextWindow: Int = 128_000,
        maxTokens: Int = 16_384,
        headers: [String: String]? = nil,
        compat: ModelCompat? = nil,
        thinkingLevelMap: [String: String?]? = nil
    ) {
        self.id = id
        self.name = name ?? id
        self.api = api
        self.provider = provider
        self.baseURL = baseURL
        self.reasoning = reasoning
        self.input = input
        self.cost = cost
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.headers = headers
        self.compat = compat
        self.thinkingLevelMap = thinkingLevelMap
    }
}

public func modelsAreEqual(_ a: Model, _ b: Model) -> Bool {
    a.id == b.id && a.provider == b.provider && a.api == b.api
}

/// Compute USD cost from usage and model pricing (per 1M tokens).
public func calculateCost(model: Model, usage: Usage) -> Cost {
    let inputTokens = usage.input + usage.cacheRead + usage.cacheWrite
    var inputRate = model.cost.input
    var outputRate = model.cost.output
    var cacheReadRate = model.cost.cacheRead
    var cacheWriteRate = model.cost.cacheWrite
    var matchedThreshold = -1

    for tier in model.cost.tiers ?? []
    where inputTokens > tier.inputTokensAbove && tier.inputTokensAbove > matchedThreshold {
        inputRate = tier.input
        outputRate = tier.output
        cacheReadRate = tier.cacheRead
        cacheWriteRate = tier.cacheWrite
        matchedThreshold = tier.inputTokensAbove
    }

    let scale = 1_000_000.0
    let input = Double(usage.input) * inputRate / scale
    let output = Double(usage.output) * outputRate / scale
    let cacheRead = Double(usage.cacheRead) * cacheReadRate / scale
    let cacheWrite = Double(usage.cacheWrite) * cacheWriteRate / scale
    return Cost(
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite,
        total: input + output + cacheRead + cacheWrite
    )
}
