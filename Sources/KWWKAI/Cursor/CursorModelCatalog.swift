import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Development-time fetch of Cursor's usable-model list via the
/// `GetUsableModels` unary RPC. This is NOT called at runtime — kwwk ships a
/// static Cursor catalog (`Resources/cursor-models.json`); this helper only
/// backs the `kwwk-generate-cursor-models` script that regenerates it.
public enum CursorModelCatalog {
    public enum FetchError: Error, LocalizedError {
        case http(Int, String)
        case emptyResponse

        public var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "Cursor HTTP \(code): \(body)"
            case .emptyResponse: return "Cursor returned no models"
            }
        }
    }

    /// Fetch usable Cursor models for the account behind `apiKey`. Unlike the
    /// Run stream, `GetUsableModels` is a plain proto unary POST
    /// (`application/proto`) so a regular HTTP client suffices.
    public static func fetchUsableModels(
        apiKey: String,
        host: String = CursorAgentProvider.defaultBaseHost,
        clientVersion: String = CursorAgentProvider.defaultClientVersion,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> [Model] {
        guard let url = URL(string: "https://\(host)/agent.v1.AgentService/GetUsableModels") else {
            throw FetchError.http(0, "invalid host \(host)")
        }
        let (response, body) = try await client.request(
            url: url,
            method: "POST",
            headers: [
                "content-type": "application/proto",
                "authorization": "Bearer \(apiKey)",
                "x-ghost-mode": "true",
                "x-cursor-client-version": clientVersion,
                "x-cursor-client-type": "cli",
                "x-request-id": UUID().uuidString,
            ],
            body: CursorProto.encodeGetUsableModelsRequest()
        )
        guard response.statusCode < 400 else {
            throw FetchError.http(response.statusCode, String(data: body, encoding: .utf8) ?? "")
        }
        let models = normalize(
            CursorProto.decodeUsableModels(stripConnectUnaryFrame(body)),
            host: host
        )
        guard !models.isEmpty else { throw FetchError.emptyResponse }
        return models
    }

    /// Curated per-model reference data, ported from oh-my-pi's bundled Cursor
    /// catalog. The wire response's `thinking_details` is never populated by
    /// Cursor, so reasoning/image capabilities and thinking routing come from
    /// this table; models Cursor added since fall back to the generic
    /// `-thinking`-variant rule in `normalize`.
    public struct CuratedModel: Sendable {
        public var name: String
        public var reasoning: Bool
        public var image: Bool
        public var contextWindow: Int
        public var maxTokens: Int
        public var thinkingLevelMap: [String: String?]?

        init(name: String, reasoning: Bool, image: Bool, contextWindow: Int, maxTokens: Int, thinkingLevelMap: [String: String]?) {
            self.name = name
            self.reasoning = reasoning
            self.image = image
            self.contextWindow = contextWindow
            self.maxTokens = maxTokens
            self.thinkingLevelMap = thinkingLevelMap?.mapValues { $0 }
        }
    }

    public static let curated: [String: CuratedModel] = [
        "claude-4.5-opus-high": .init(name: "Claude 4.5 Opus", reasoning: true, image: true, contextWindow: 200_000, maxTokens: 64_000, thinkingLevelMap: ["off": "claude-4.5-opus-high", "minimal": "claude-4.5-opus-high-thinking", "low": "claude-4.5-opus-high-thinking", "medium": "claude-4.5-opus-high-thinking", "high": "claude-4.5-opus-high-thinking"]),
        "claude-4.5-sonnet": .init(name: "Claude 4.5 Sonnet", reasoning: true, image: true, contextWindow: 200_000, maxTokens: 64_000, thinkingLevelMap: ["off": "claude-4.5-sonnet", "minimal": "claude-4.5-sonnet-thinking", "low": "claude-4.5-sonnet-thinking", "medium": "claude-4.5-sonnet-thinking", "high": "claude-4.5-sonnet-thinking"]),
        "claude-4.6-opus-high": .init(name: "Claude 4.6 Opus", reasoning: true, image: false, contextWindow: 200_000, maxTokens: 64_000, thinkingLevelMap: ["off": "claude-4.6-opus-high", "minimal": "claude-4.6-opus-high-thinking", "low": "claude-4.6-opus-high-thinking", "medium": "claude-4.6-opus-high-thinking", "high": "claude-4.6-opus-high-thinking"]),
        "claude-4.6-sonnet-medium": .init(name: "Claude 4.6 Sonnet", reasoning: true, image: false, contextWindow: 200_000, maxTokens: 64_000, thinkingLevelMap: ["off": "claude-4.6-sonnet-medium", "minimal": "claude-4.6-sonnet-medium-thinking", "low": "claude-4.6-sonnet-medium-thinking", "medium": "claude-4.6-sonnet-medium-thinking", "high": "claude-4.6-sonnet-medium-thinking"]),
        "composer-1": .init(name: "Composer 1", reasoning: false, image: false, contextWindow: 200_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "composer-1.5": .init(name: "Composer 1.5", reasoning: false, image: false, contextWindow: 200_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "default": .init(name: "Auto (Cursor picks)", reasoning: false, image: true, contextWindow: 200_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gemini-3-flash": .init(name: "Gemini 3 Flash", reasoning: true, image: true, contextWindow: 1_048_576, maxTokens: 65_536, thinkingLevelMap: nil),
        "gemini-3-pro": .init(name: "Gemini 3 Pro", reasoning: true, image: true, contextWindow: 1_048_576, maxTokens: 65_536, thinkingLevelMap: nil),
        "gemini-3.1-pro": .init(name: "Gemini 3.1 Pro Preview", reasoning: true, image: true, contextWindow: 1_048_576, maxTokens: 65_536, thinkingLevelMap: nil),
        "gpt-5.1-codex-max": .init(name: "GPT-5.1 Codex Max", reasoning: true, image: true, contextWindow: 272_000, maxTokens: 128_000, thinkingLevelMap: nil),
        "gpt-5.1-codex-max-high": .init(name: "GPT-5.1 Codex Max High", reasoning: true, image: true, contextWindow: 272_000, maxTokens: 128_000, thinkingLevelMap: nil),
        "gpt-5.1-codex-mini": .init(name: "GPT-5.1 Codex mini", reasoning: true, image: true, contextWindow: 272_000, maxTokens: 128_000, thinkingLevelMap: nil),
        "gpt-5.1-high": .init(name: "GPT-5.1 High", reasoning: false, image: false, contextWindow: 200_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.2": .init(name: "GPT-5.2", reasoning: true, image: true, contextWindow: 400_000, maxTokens: 128_000, thinkingLevelMap: nil),
        "gpt-5.2-codex": .init(name: "GPT-5.2 Codex", reasoning: true, image: true, contextWindow: 272_000, maxTokens: 128_000, thinkingLevelMap: nil),
        "gpt-5.2-codex-fast": .init(name: "GPT-5.2 Codex Fast", reasoning: false, image: false, contextWindow: 272_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.2-codex-high": .init(name: "GPT-5.2 Codex High", reasoning: false, image: false, contextWindow: 272_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.2-codex-high-fast": .init(name: "GPT-5.2 Codex High Fast", reasoning: false, image: false, contextWindow: 272_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.2-codex-low": .init(name: "GPT-5.2 Codex Low", reasoning: false, image: false, contextWindow: 272_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.2-codex-low-fast": .init(name: "GPT-5.2 Codex Low Fast", reasoning: false, image: false, contextWindow: 272_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.2-codex-xhigh": .init(name: "GPT-5.2 Codex Extra High", reasoning: false, image: false, contextWindow: 272_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.2-codex-xhigh-fast": .init(name: "GPT-5.2 Codex Extra High Fast", reasoning: false, image: false, contextWindow: 272_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.2-high": .init(name: "GPT-5.2 High", reasoning: true, image: true, contextWindow: 400_000, maxTokens: 128_000, thinkingLevelMap: nil),
        "gpt-5.3-codex": .init(name: "GPT-5.3 Codex", reasoning: true, image: true, contextWindow: 272_000, maxTokens: 128_000, thinkingLevelMap: nil),
        "gpt-5.3-codex-fast": .init(name: "GPT-5.3 Codex Fast", reasoning: false, image: false, contextWindow: 272_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.3-codex-high": .init(name: "GPT-5.3 Codex High", reasoning: false, image: false, contextWindow: 272_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.3-codex-high-fast": .init(name: "GPT-5.3 Codex High Fast", reasoning: false, image: false, contextWindow: 272_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.3-codex-low": .init(name: "GPT-5.3 Codex Low", reasoning: false, image: false, contextWindow: 272_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.3-codex-low-fast": .init(name: "GPT-5.3 Codex Low Fast", reasoning: false, image: false, contextWindow: 272_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.3-codex-spark-preview": .init(name: "GPT-5.3 Codex Spark", reasoning: false, image: false, contextWindow: 200_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.3-codex-xhigh": .init(name: "GPT-5.3 Codex Extra High", reasoning: false, image: false, contextWindow: 272_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.3-codex-xhigh-fast": .init(name: "GPT-5.3 Codex Extra High Fast", reasoning: false, image: false, contextWindow: 272_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.4-high": .init(name: "GPT-5.4 High", reasoning: false, image: false, contextWindow: 200_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.4-high-fast": .init(name: "GPT-5.4 High Fast", reasoning: false, image: false, contextWindow: 200_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.4-low": .init(name: "GPT-5.4 Low", reasoning: false, image: false, contextWindow: 200_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.4-medium": .init(name: "GPT-5.4", reasoning: false, image: false, contextWindow: 200_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.4-medium-fast": .init(name: "GPT-5.4 Fast", reasoning: false, image: false, contextWindow: 200_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.4-xhigh": .init(name: "GPT-5.4 Extra High", reasoning: false, image: false, contextWindow: 200_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "gpt-5.4-xhigh-fast": .init(name: "GPT-5.4 Extra High Fast", reasoning: false, image: false, contextWindow: 200_000, maxTokens: 64_000, thinkingLevelMap: nil),
        "grok-code-fast-1": .init(name: "Grok Code Fast 1", reasoning: true, image: false, contextWindow: 256_000, maxTokens: 10_000, thinkingLevelMap: nil),
        "kimi-k2.5": .init(name: "Kimi K2.5", reasoning: true, image: true, contextWindow: 262_144, maxTokens: 65_536, thinkingLevelMap: nil),
    ]

    /// Convert decoded Cursor model details into kwwk `Model`s.
    ///
    /// Capabilities come from the curated table above (the wire never carries
    /// them). Fetched ids missing from the table get the generic rule: when the
    /// account also has `<id>-thinking`, the base model advertises reasoning
    /// with a `thinkingLevelMap` routing every level to that variant. Wire ids
    /// that only exist as a thinking-routing target are folded into their base
    /// model and hidden from the visible list, matching oh-my-pi's collapse.
    static func normalize(_ models: [CursorProto.UsableModel], host: String) -> [Model] {
        var byId: [String: Model] = [:]
        let fetchedIds = Set(models.map { $0.modelId.trimmingCharacters(in: .whitespaces) })

        // Wire ids reachable through some base model's thinking routing.
        var routingTargets = Set<String>()
        for (baseId, entry) in curated {
            for case let target? in (entry.thinkingLevelMap ?? [:]).values where target != baseId {
                routingTargets.insert(target)
            }
        }
        for id in fetchedIds where fetchedIds.contains("\(id)-thinking") && curated[id] == nil {
            routingTargets.insert("\(id)-thinking")
        }

        for m in models {
            let id = m.modelId.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !routingTargets.contains(id) else { continue }

            if let entry = curated[id] {
                byId[id] = Model(
                    id: id,
                    name: entry.name,
                    api: "cursor-agent",
                    provider: "cursor",
                    baseURL: "https://\(host)",
                    reasoning: entry.reasoning,
                    input: entry.image ? [.text, .image] : [.text],
                    cost: ModelCost(),
                    contextWindow: entry.contextWindow,
                    maxTokens: entry.maxTokens,
                    thinkingLevelMap: entry.thinkingLevelMap
                )
                continue
            }

            let thinkingVariant = fetchedIds.contains("\(id)-thinking") ? "\(id)-thinking" : nil
            byId[id] = Model(
                id: id,
                name: pickDisplayName(m, fallbackId: id),
                api: "cursor-agent",
                provider: "cursor",
                baseURL: "https://\(host)",
                reasoning: m.hasThinking || thinkingVariant != nil || id.hasSuffix("-thinking"),
                input: inferInput(fromCursorId: id),
                cost: ModelCost(),
                contextWindow: 200_000,
                maxTokens: 64_000,
                thinkingLevelMap: thinkingVariant.map { variant in
                    [
                        "off": id, "minimal": variant, "low": variant,
                        "medium": variant, "high": variant,
                    ]
                }
            )
        }
        return byId.values.sorted { $0.id < $1.id }
    }

    /// A plain-proto unary response may still arrive wrapped in a single Connect
    /// unary frame (`[flags:1][len:4]` prefix). Detect that shape and unwrap it;
    /// otherwise return the bytes untouched.
    static func stripConnectUnaryFrame(_ data: Data) -> Data {
        guard data.count >= 5 else { return data }
        let flags = data[data.startIndex]
        // A raw protobuf message starts with a field tag byte; the Connect frame
        // flag byte is 0 (data) or 2 (end-stream). Only treat it as framed when
        // the declared length matches the remaining bytes exactly.
        guard flags == 0 || flags == 2 else { return data }
        let lenBytes = data.subdata(in: data.startIndex + 1 ..< data.startIndex + 5)
        let msgLen = lenBytes.reduce(0) { ($0 << 8) | Int($1) }
        guard msgLen == data.count - 5 else { return data }
        return data.subdata(in: data.startIndex + 5 ..< data.endIndex)
    }

    /// Infers input modalities for Cursor models without a curated entry.
    ///
    /// `GetUsableModels` carries no per-model modality metadata, so
    /// classification falls back to the model family: families that are
    /// multimodal in their native catalogs (claude/gemini/gpt/codex/grok-4.5)
    /// accept images, while text-only families such as composer-*, grok-code-*,
    /// and kimi-* do not. Curated entries above remain authoritative. Ports
    /// oh-my-pi's `inferInputFromCursorId` (6e209d3ec).
    static func inferInput(fromCursorId id: String) -> [InputModality] {
        let lowered = id.lowercased()
        let multimodalFamilies = ["claude", "gemini", "gpt-", "codex", "grok-4.5"]
        if multimodalFamilies.contains(where: lowered.contains) {
            return [.text, .image]
        }
        return [.text]
    }

    private static func pickDisplayName(_ m: CursorProto.UsableModel, fallbackId: String) -> String {
        for candidate in [m.displayName, m.displayNameShort, m.displayModelId] + m.aliases {
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return fallbackId
    }
}
