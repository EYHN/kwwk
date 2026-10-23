import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cursor's usable-model list via the `GetUsableModels` unary RPC, with
/// each id's window and image input from the model picker
/// (`AvailableModels`). kwwk itself never lists models at runtime: it reads
/// the static Cursor catalog it ships (`Resources/cursor-models.json`), and
/// `fetchUsableModels` backs the `kwwk-generate-cursor-models` script that
/// regenerates it. A host that needs an account's own list calls
/// ``CursorModels/fetch(credentials:host:clientVersion:client:)``, which
/// asks the same and reads the reply as a runtime caller needs.
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

    /// Fetch usable Cursor models for the account behind `apiKey`, for the
    /// generate script. Unlike the Run stream, `GetUsableModels` is a plain
    /// proto unary POST (`application/proto`) so a regular HTTP client
    /// suffices.
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
        // A picker Cursor cannot give leaves the list as the usable ids and
        // the curated table make it.
        let picker = (try? await fetchPickerFacts(
            apiKey: apiKey,
            host: host,
            clientVersion: clientVersion,
            client: client
        )) ?? [:]
        let models = normalize(
            CursorProto.decodeUsableModels(stripConnectUnaryFrame(body)),
            host: host,
            picker: picker
        )
        guard !models.isEmpty else { throw FetchError.emptyResponse }
        return models
    }

    // MARK: - The model picker

    /// What Cursor's model picker says of one wire id.
    public struct PickerFacts: Sendable, Equatable {
        /// The window the id runs at outside Max Mode, in tokens.
        public var contextWindow: Int?
        /// Whether the model takes images (`supportsImages`).
        public var image: Bool?
    }

    /// Fetch what Cursor's model picker says of each wire id:
    /// `AiService/AvailableModels`, asked as the CLI asks it.
    public static func fetchPickerFacts(
        apiKey: String,
        host: String = CursorAgentProvider.defaultBaseHost,
        clientVersion: String = CursorAgentProvider.defaultClientVersion,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> [String: PickerFacts] {
        guard let url = URL(string: "https://\(host)/aiserver.v1.AiService/AvailableModels") else {
            throw FetchError.http(0, "invalid host \(host)")
        }
        let (response, body) = try await client.request(
            url: url,
            method: "POST",
            headers: [
                "content-type": "application/json",
                "connect-protocol-version": "1",
                "authorization": "Bearer \(apiKey)",
                "x-ghost-mode": "true",
                "x-cursor-client-version": clientVersion,
                "x-cursor-client-type": "cli",
            ],
            body: Data(#"{"useModelParameters":true,"doNotUseMarkdown":true}"#.utf8)
        )
        guard response.statusCode < 400 else {
            throw FetchError.http(response.statusCode, String(data: body, encoding: .utf8) ?? "")
        }
        return pickerFacts(fromAvailableModels: body)
    }

    /// Read the picker's reply into facts by wire id.
    ///
    /// The usable list names a model once for each effort and speed and
    /// says nothing of its window, and the names mislead: "Claude Opus 5.5
    /// 1M" is served at 300K outside Max Mode, and nothing in a name says
    /// Grok has 256K (magpie's cursor plugin 0.2.0, #51: 110 of 153 windows
    /// read off the names were wrong, and agents compacted at the wrong
    /// point). The picker has it: each of a model's `variants` carries the
    /// wire id it runs as (`legacySlug`) and its parameters, among them the
    /// `context` size ("300k", "1m"); a model without sizes has
    /// `contextTokenLimit`. One wire id can stand for two sizes, the larger
    /// in Max Mode only (`isMaxMode`). kwwk never asks for Max Mode, so an
    /// id's window is the smallest it has outside Max Mode — or, for an id
    /// Cursor serves in Max Mode only, the smallest it has at all. Models
    /// the CLI's picker hides (hidden, chat-only, Tab-only, not for the
    /// agent) are left out, as the plugin's `modelsOf` leaves them out.
    static func pickerFacts(fromAvailableModels body: Data) -> [String: PickerFacts] {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [:] }
        func flag(_ object: [String: Any], _ key: String) -> Bool? { object[key] as? Bool }
        func tokens(_ value: Any?) -> Int {
            (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init) ?? 0
        }

        var windows: [String: (outsideMax: [Int], maxMode: [Int])] = [:]
        var facts: [String: PickerFacts] = [:]
        for model in models {
            if flag(model, "isHidden") == true || flag(model, "isChatOnly") == true
                || flag(model, "onlySupportsCmdK") == true || flag(model, "supportsAgent") == false { continue }
            let maxOnly = flag(model, "supportsNonMaxMode") == false
            for variant in model["variants"] as? [[String: Any]] ?? [] {
                guard let slug = variant["legacySlug"] as? String, !slug.isEmpty else { continue }
                let inMax = maxOnly || flag(variant, "isMaxMode") == true
                var window = 0
                for parameter in variant["parameterValues"] as? [[String: Any]] ?? []
                where parameter["id"] as? String == "context" {
                    window = contextTokens(parameter["value"] as? String ?? "")
                }
                if window == 0 {
                    window = inMax
                        ? max(tokens(model["contextTokenLimitForMaxMode"]), tokens(model["contextTokenLimit"]))
                        : tokens(model["contextTokenLimit"])
                }
                facts[slug, default: PickerFacts()].image = flag(model, "supportsImages")
                guard window > 0 else { continue }
                if inMax {
                    windows[slug, default: ([], [])].maxMode.append(window)
                } else {
                    windows[slug, default: ([], [])].outsideMax.append(window)
                }
            }
        }
        for (slug, sizes) in windows {
            facts[slug]?.contextWindow = sizes.outsideMax.min() ?? sizes.maxMode.min()
        }
        return facts
    }

    /// A picker context size in tokens: "300k" is 300000, "1m" 1000000; 0
    /// for anything else (the plugin's `tokensOf`).
    static func contextTokens(_ value: String) -> Int {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = text.last, unit == "k" || unit == "m",
              let number = Double(text.dropLast()), number > 0 else { return 0 }
        return Int((number * (unit == "m" ? 1_000_000 : 1_000)).rounded())
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

        init(
            name: String,
            reasoning: Bool,
            image: Bool,
            contextWindow: Int,
            maxTokens: Int,
            thinkingLevelMap: [String: String]?
        ) {
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
    ///
    /// Where the picker speaks of an id (`picker`), its window and whether
    /// it takes images are the picker's, over the table and the family rule:
    /// those are Cursor's own word on what it serves.
    static func normalize(
        _ models: [CursorProto.UsableModel],
        host: String,
        picker: [String: PickerFacts] = [:]
    ) -> [Model] {
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
        for (id, facts) in picker {
            guard var model = byId[id] else { continue }
            if let window = facts.contextWindow { model.contextWindow = window }
            if let image = facts.image { model.input = image ? [.text, .image] : [.text] }
            byId[id] = model
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
