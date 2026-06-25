import Foundation

public enum InputModality: String, Codable, Sendable, Hashable {
    case text
    case image
}

public struct ModelCost: Codable, Sendable, Hashable {
    /// USD per 1M tokens.
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

public struct Model: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// Opaque API identifier (e.g., "anthropic-messages", "openai-responses", "faux:xyz").
    public var api: String
    public var provider: String
    public var baseUrl: String
    public var reasoning: Bool
    public var input: [InputModality]
    public var cost: ModelCost
    public var contextWindow: Int
    public var maxTokens: Int
    public var headers: [String: String]?
    /// Per-API compatibility overrides (cache format, thinking format, store
    /// support, etc.). nil = auto-detect from baseUrl / provider defaults.
    public var compat: ModelCompat?
    /// Maps pi thinking levels (off/minimal/low/medium/high/xhigh) to
    /// provider/model-specific wire values. A `.some(nil)` entry marks a level
    /// as unsupported; a missing key uses provider defaults.
    public var thinkingLevelMap: [String: String?]?

    public init(
        id: String,
        name: String? = nil,
        api: String,
        provider: String,
        baseUrl: String = "",
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
        self.baseUrl = baseUrl
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
    let scale = 1_000_000.0
    let input = Double(usage.input) * model.cost.input / scale
    let output = Double(usage.output) * model.cost.output / scale
    let cacheRead = Double(usage.cacheRead) * model.cost.cacheRead / scale
    let cacheWrite = Double(usage.cacheWrite) * model.cost.cacheWrite / scale
    return Cost(
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite,
        total: input + output + cacheRead + cacheWrite
    )
}
