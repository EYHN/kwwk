import Foundation

/// Access to pi-mono's curated catalog of 900+ models, bundled as a JSON
/// resource at `Resources/models.json`. Regenerate with:
///
///   swift run kwwk-generate-models \
///       /path/to/pi-mono/packages/ai/src/models.generated.ts
///
/// Stays in-process cheap: the JSON is parsed once on first access and held
/// in a `Model` dictionary keyed by provider + id.
public enum ModelsCatalog {
    /// Provider → model-id → Model.
    public static let byProvider: [String: [String: Model]] = loadAll()

    /// Flat list of every model in the catalog.
    public static let all: [Model] = byProvider.values.flatMap { $0.values }

    /// Every provider key in the catalog (sorted alphabetically).
    public static var providers: [String] {
        Array(byProvider.keys).sorted()
    }

    /// Lookup a model by provider + id.
    public static func model(provider: String, id: String) -> Model? {
        byProvider[provider]?[id]
    }

    /// All models under a given provider, sorted by id.
    public static func models(for provider: String) -> [Model] {
        guard let inner = byProvider[provider] else { return [] }
        return inner.keys.sorted().compactMap { inner[$0] }
    }

    // MARK: - Loader

    private static func loadAll() -> [String: [String: Model]] {
        guard let url = Bundle.module.url(forResource: "models", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return [:]
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: [String: Model]] = [:]
        for (provider, value) in root {
            guard let inner = value as? [String: Any] else { continue }
            var models: [String: Model] = [:]
            for (modelId, modelJSON) in inner {
                guard let dict = modelJSON as? [String: Any],
                      let model = decode(dict) else { continue }
                models[modelId] = model
            }
            if !models.isEmpty { out[provider] = models }
        }
        return out
    }

    /// Hand-written decoder matching the fields pi emits, including the
    /// per-model `compat` block and `thinkingLevelMap` consumed by the provider
    /// encoders for reasoning/caching/request shaping.
    private static func decode(_ dict: [String: Any]) -> Model? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String,
              let api = dict["api"] as? String,
              let provider = dict["provider"] as? String else {
            return nil
        }
        let baseUrl = dict["baseUrl"] as? String ?? ""
        let reasoning = dict["reasoning"] as? Bool ?? false
        let inputStrings = dict["input"] as? [String] ?? ["text"]
        let input: [InputModality] = inputStrings.compactMap { InputModality(rawValue: $0) }
        let contextWindow = dict["contextWindow"] as? Int ?? 0
        let maxTokens = dict["maxTokens"] as? Int ?? 0

        var cost = ModelCost()
        if let c = dict["cost"] as? [String: Any] {
            cost.input = doubleValue(c["input"]) ?? 0
            cost.output = doubleValue(c["output"]) ?? 0
            cost.cacheRead = doubleValue(c["cacheRead"]) ?? 0
            cost.cacheWrite = doubleValue(c["cacheWrite"]) ?? 0
        }

        let headers = dict["headers"] as? [String: String]

        // compat: re-serialize the sub-object and run it through JSONDecoder so
        // the flattened ModelCompat picks up whichever per-API fields are present.
        var compat: ModelCompat?
        if let compatDict = dict["compat"] as? [String: Any],
           let compatData = try? JSONSerialization.data(withJSONObject: compatDict) {
            compat = try? JSONDecoder().decode(ModelCompat.self, from: compatData)
        }

        // thinkingLevelMap: preserve the present-with-null distinction (null =>
        // level explicitly unsupported) that JSONSerialization surfaces as NSNull.
        var thinkingLevelMap: [String: String?]?
        if let mapDict = dict["thinkingLevelMap"] as? [String: Any] {
            var parsed: [String: String?] = [:]
            for (level, value) in mapDict {
                if value is NSNull {
                    parsed[level] = .some(nil)
                } else if let s = value as? String {
                    parsed[level] = .some(s)
                }
            }
            if !parsed.isEmpty { thinkingLevelMap = parsed }
        }

        return Model(
            id: id,
            name: name,
            api: api,
            provider: provider,
            baseUrl: baseUrl,
            reasoning: reasoning,
            input: input,
            cost: cost,
            contextWindow: contextWindow,
            maxTokens: maxTokens,
            headers: headers,
            compat: compat,
            thinkingLevelMap: thinkingLevelMap
        )
    }

    private static func doubleValue(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}
