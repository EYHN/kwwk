import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Devin model discovery and normalization, used by the
/// `kwwk-generate-devin-models` tool to pre-generate the bundled
/// `Resources/devin-models.json`. Ported from oh-my-pi's
/// `catalog/src/discovery/devin.ts` plus the reviewed `devin` variant
/// families in `compat/rules/taxonomy/_collapse.kdl`.
///
/// Devin exposes each reasoning effort as its own model uid
/// (`claude-opus-5-low` … `-max`). Normalization collapses those into one
/// logical model whose `thinkingLevelMap` routes each kwwk thinking level to
/// the member uid; `DevinAgentProvider.wireModelId` resolves it per request.
public enum DevinModels {
    /// Default model: plan-included SWE-1.6, present for every account.
    public static let defaultModelId = "swe-1-6"

    static let defaultContextWindow = 200_000
    static let defaultMaxTokens = 64_000

    /// Wire uids whose configs advertise `supports_images` while the backend
    /// silently drops `ChatMessagePrompt.images` (verified by oh-my-pi).
    static let imageBlindUids: Set<String> = ["swe-1-6", "swe-1-6-fast"]

    /// Curated seed — both SWE-1.6 lanes, verified live by oh-my-pi. Always
    /// present in the generated catalog so the default model resolves even
    /// when discovery returns a reduced roster.
    public static let seedModels: [Model] = [
        Model(
            id: "swe-1-6-fast", name: "SWE-1.6 Fast", api: "devin-agent", provider: "devin",
            baseURL: DevinWire.defaultBaseURL, reasoning: true, input: [.text],
            cost: ModelCost(input: 0.3, output: 1.5, cacheRead: 0.03, cacheWrite: 0),
            contextWindow: 200_000, maxTokens: 128_000,
            compat: parallelToolsCompat()
        ),
        Model(
            id: "swe-1-6", name: "SWE-1.6", api: "devin-agent", provider: "devin",
            baseURL: DevinWire.defaultBaseURL, reasoning: true, input: [.text],
            cost: ModelCost(),
            contextWindow: 200_000, maxTokens: 128_000,
            compat: parallelToolsCompat()
        ),
    ]

    private static func parallelToolsCompat() -> ModelCompat {
        var compat = ModelCompat()
        compat.supportsParallelToolCalls = true
        return compat
    }

    // MARK: - Discovery

    public enum DiscoveryError: Error, LocalizedError {
        case emptyCatalog
        public var errorDescription: String? {
            switch self {
            case .emptyCatalog:
                return "Devin returned an empty model catalog; the pinned client identities may be stale"
            }
        }
    }

    /// Fetch the account's models via `GetCliModelConfigs` and normalize them.
    /// Tries the native `chisel` identity first, then the legacy Windsurf
    /// editor identity (Windsurf Enterprise seats only see their full roster
    /// there), keeping whichever returned more models.
    public static func fetch(
        apiKey: String,
        baseURL: String = DevinWire.defaultBaseURL,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> [Model] {
        let native = try? await fetchConfigs(
            metadata: DevinWire.discoveryMetadata(apiKey: apiKey), baseURL: baseURL, client: client
        )
        let nativeModels = native.map { normalize($0, baseURL: baseURL) }
        let seedIds = Set(seedModels.map(\.id))
        if let nativeModels, !nativeModels.isEmpty, !nativeModels.allSatisfy({ seedIds.contains($0.id) }) {
            return withSeed(nativeModels)
        }
        let legacy = try? await fetchConfigs(
            metadata: DevinWire.legacyWindsurfMetadata(apiKey: apiKey), baseURL: baseURL, client: client
        )
        let legacyModels = legacy.map { normalize($0, baseURL: baseURL) }
        let chosen: [Model]?
        if let legacyModels, legacyModels.count > (nativeModels?.count ?? -1) {
            chosen = legacyModels
        } else {
            chosen = nativeModels
        }
        guard let chosen, !chosen.isEmpty else { throw DiscoveryError.emptyCatalog }
        return withSeed(chosen)
    }

    static func fetchConfigs(
        metadata: DevinProto.Metadata, baseURL: String, client: HTTPClient
    ) async throws -> [DevinProto.ClientModelConfig] {
        let url = URL(string: DevinAgentProvider.trimSlashes(baseURL) + DevinWire.getCliModelConfigsPath)!
        let (response, body) = try await client.request(
            url: url, method: "POST", headers: DevinWire.unaryHeaders,
            body: DevinProto.encodeGetCliModelConfigsRequest(metadata: metadata)
        )
        guard response.statusCode < 400 else {
            throw DevinAgentProvider.unaryFailure(operation: "GetCliModelConfigs", response: response, body: body)
        }
        return DevinProto.decodeGetCliModelConfigsResponse(DevinProto.unaryPayload(body))
    }

    /// Ensure the seed models are present (discovered rows win).
    static func withSeed(_ models: [Model]) -> [Model] {
        var out = models
        let ids = Set(models.map(\.id))
        for seed in seedModels where !ids.contains(seed.id) { out.append(seed) }
        return out.sorted { $0.id < $1.id }
    }

    // MARK: - Normalization

    /// Convert raw `ClientModelConfig`s into catalog models: drop disabled /
    /// internal configs and Fusion pairings, collapse effort families
    /// (server-declared first, then the reviewed static table), and apply
    /// list-price fallbacks for plan-included models.
    static func normalize(_ configs: [DevinProto.ClientModelConfig], baseURL: String = DevinWire.defaultBaseURL) -> [Model] {
        var specs: [Model] = []
        var seen = Set<String>()
        var lanes: [String: FamilyLane] = [:]
        var laneOrder: [String] = []

        for config in configs where !config.disabled {
            let display = config.modelInfo?.displayOption ?? DevinProto.DisplayOption.unspecified
            if display == DevinProto.DisplayOption.quickReview || display == DevinProto.DisplayOption.internalDefault {
                continue
            }
            let uid = config.modelUid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uid.isEmpty, !seen.contains(uid) else { continue }
            seen.insert(uid)
            // Fusion pairings (`fusion-<lead>-sidekick-<x>`) are orchestrated
            // by the native client; the server cannot serve the composite uid.
            if uid.hasPrefix("fusion-"), uid.contains("-sidekick-") { continue }
            let isRouter = display == DevinProto.DisplayOption.modelRouter || config.modelInfo?.isModelRouter == true
            // Harness-less routers (`adaptive`) go through AssignModel;
            // harness-backed composites are ordinary chat uids.
            let isAssignRouter = isRouter && (config.modelInfo?.harnessUids.isEmpty ?? true)
            specs.append(modelSpec(config, uid: uid, baseURL: baseURL, isAssignRouter: isAssignRouter))
            if !isRouter {
                collectFamilyLane(&lanes, order: &laneOrder, config: config, uid: uid)
            }
        }

        let dynamic = laneOrder.compactMap { lanes[$0] }.compactMap(dynamicFamily)
        var collapsed = collapse(specs, families: dynamic)
        collapsed = collapse(collapsed, families: staticFamilies)
        return collapsed.map(applyCostFallback).sorted { $0.id < $1.id }
    }

    static func modelSpec(
        _ config: DevinProto.ClientModelConfig, uid: String, baseURL: String, isAssignRouter: Bool
    ) -> Model {
        let features = config.modelInfo?.modelFeatures
        let supportsImages = (features?.supportsImages ?? config.supportsImages) && !imageBlindUids.contains(uid)
        var compat = ModelCompat()
        var hasCompat = false
        if isAssignRouter { compat.modelRouter = true; hasCompat = true }
        if features?.supportsParallelToolCalls == true { compat.supportsParallelToolCalls = true; hasCompat = true }
        let maxOutput = Int(config.modelInfo?.maxOutputTokens ?? 0)
        let label = config.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return Model(
            id: uid,
            name: label.isEmpty ? uid : label,
            api: "devin-agent",
            provider: "devin",
            baseURL: baseURL,
            reasoning: supportsThinking(config),
            input: supportsImages ? [.text, .image] : [.text],
            cost: cost(config),
            contextWindow: config.maxTokens > 0 ? Int(config.maxTokens) : defaultContextWindow,
            maxTokens: maxOutput > 0 ? maxOutput : defaultMaxTokens,
            compat: hasCompat ? compat : nil
        )
    }

    /// Server features are authoritative; the label heuristic only covers
    /// configs that ship no `modelFeatures`.
    static func supportsThinking(_ config: DevinProto.ClientModelConfig) -> Bool {
        if let features = config.modelInfo?.modelFeatures { return features.supportsThinking }
        let label = config.label
        if label.range(of: #"\bno thinking\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return label.range(of: "think|thinking|minimal|high|medium|low|xhigh|max|reasoning",
                           options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Per-million-token rates from the config's cost dimensions. A
    /// `Sidekick` marker separates a composite's own card from component
    /// cards, so reading stops there.
    static func cost(_ config: DevinProto.ClientModelConfig) -> ModelCost {
        var cost = ModelCost()
        for dimension in config.modelDimensions {
            let label = dimension.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if label == "sidekick" { break }
            guard dimension.kind == DevinProto.ModelDimensionKind.cost
                || dimension.kind == DevinProto.ModelDimensionKind.costFuzzy else { continue }
            let raw = Double(dimension.value) * 1_000_000 / denominatorTokens(dimension.denominator)
            // Round off float32 noise (0.1 decodes as 0.10000000149…).
            let perMillion = (raw * 1e6).rounded() / 1e6
            switch label {
            case "input": cost.input = perMillion
            case "cached input": cost.cacheRead = perMillion
            case "output": cost.output = perMillion
            default: break
            }
        }
        return cost
    }

    /// Tokens covered by one cost dimension ("1M tokens", "1K tokens").
    static func denominatorTokens(_ denominator: String) -> Double {
        let pattern = #"(\d+(?:\.\d+)?)\s*([kmbKMB])?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: denominator, range: NSRange(denominator.startIndex..., in: denominator)),
              let numberRange = Range(match.range(at: 1), in: denominator),
              let number = Double(denominator[numberRange]) else { return 1_000_000 }
        var scale = 1.0
        if let suffixRange = Range(match.range(at: 2), in: denominator) {
            switch denominator[suffixRange].lowercased() {
            case "k": scale = 1_000
            case "m": scale = 1_000_000
            case "b": scale = 1_000_000_000
            default: break
            }
        }
        let tokens = number * scale
        return tokens > 0 ? tokens : 1_000_000
    }

    // MARK: - Cost fallbacks (providers/devin.kdl `cost-fallback`)

    /// Devin omits cost dimensions for plan-included models on lower tiers.
    /// These seed the enterprise list price only when upstream reports no
    /// token price at all.
    static func applyCostFallback(_ model: Model) -> Model {
        let c = model.cost
        guard c.input == 0, c.output == 0, c.cacheRead == 0, c.cacheWrite == 0 else { return model }
        var out = model
        if model.id.hasPrefix("swe-2") {
            // Enterprise promo price (75% off list) through 2026-12-31.
            out.cost = ModelCost(input: 0.75, output: 3.75, cacheRead: 0.075, cacheWrite: 0.75)
        } else if model.id == "swe-1-7" || model.id == "swe-1-7-medium" {
            out.cost = ModelCost(input: 0.5, output: 2.5, cacheRead: 0.2, cacheWrite: 0.5)
        } else if model.id == "glm-5-2" {
            out.cost = ModelCost(input: 1.4, output: 4.4, cacheRead: 0.26, cacheWrite: 1.4)
        }
        return out
    }

    // MARK: - Family collapse

    /// One effort family: logical id, member wire uids in priority order, and
    /// per-level routing (`off`, `minimal` … `max`).
    struct Family: Sendable {
        let id: String
        let name: String
        let members: [String]
        let routing: [String: String]
        var defaultMember: String?

        init(id: String, name: String, members: [String], routing: [String: String], defaultMember: String? = nil) {
            self.id = id
            self.name = name
            self.members = members
            self.routing = routing
            self.defaultMember = defaultMember
        }
    }

    static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// Replace each family's present members with one logical model. Fields
    /// come from the default member (or the first present one); `input` is
    /// the union; `thinkingLevelMap` routes every level explicitly (nil =
    /// unsupported) so the provider sends the right member uid.
    static func collapse(_ specs: [Model], families: [Family]) -> [Model] {
        var byId: [String: Model] = [:]
        for spec in specs where byId[spec.id] == nil { byId[spec.id] = spec }
        var replacement: [String: Model] = [:]
        var familyOf: [String: String] = [:]

        for family in families {
            // Already collapsed (logical row present, no raw members) passes through.
            let present = family.members.filter { byId[$0] != nil && !($0 == family.id && byId[$0]?.thinkingLevelMap != nil) }
            guard !present.isEmpty else { continue }
            let presentSet = Set(present)
            let defaultUid = family.defaultMember.flatMap { presentSet.contains($0) ? $0 : nil } ?? present[0]
            guard var base = byId[defaultUid] else { continue }

            var map: [String: String?] = [:]
            var hasEffortRoute = false
            for level in thinkingLevels {
                if let target = family.routing[level], presentSet.contains(target) {
                    map[level] = .some(target)
                    if level != "off" { hasEffortRoute = true }
                } else {
                    map[level] = .some(nil)
                }
            }
            // A family with no effort route (a pure rename) always sends its
            // default member.
            if !hasEffortRoute, family.routing["off"] == nil {
                map["off"] = .some(defaultUid)
            }
            let members = present.compactMap { byId[$0] }
            var input: [InputModality] = []
            if members.contains(where: { $0.input.contains(.text) }) { input.append(.text) }
            if members.contains(where: { $0.input.contains(.image) }) { input.append(.image) }

            base.id = family.id
            base.name = family.name
            base.input = input
            base.reasoning = hasEffortRoute
            base.thinkingLevelMap = map
            if members.contains(where: { $0.compat?.supportsParallelToolCalls == true }) {
                var compat = base.compat ?? ModelCompat()
                compat.supportsParallelToolCalls = true
                base.compat = compat
            }
            replacement[family.id] = base
            for uid in present { familyOf[uid] = family.id }
            if byId[family.id] != nil { familyOf[family.id] = family.id }
        }

        var out: [Model] = []
        var emitted = Set<String>()
        for spec in specs {
            if let familyId = familyOf[spec.id] {
                if !emitted.contains(familyId), let row = replacement[familyId] {
                    out.append(row)
                    emitted.insert(familyId)
                }
                continue
            }
            out.append(spec)
        }
        return out
    }

    // MARK: Server-declared families (modelFamilyMetadata)

    struct FamilyLane {
        var id: String
        var name: String
        var members: [String] = []
        var defaultMember: String?
        var routing: [String: String] = [:]
    }

    static let effortByName: [String: String] = [
        "none": "off", "nothinking": "off",
        "minimal": "minimal", "low": "low", "medium": "medium",
        "high": "high", "xhigh": "xhigh", "max": "max",
    ]

    private static func squash(_ s: String, separator: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: separator, options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: separator.isEmpty ? " " : separator))
    }

    /// File `config` under its server-declared family lane. Fast service and
    /// 1M context become separate lanes (`-fast` / `-1m`); effort is the
    /// lane's only routing axis.
    static func collectFamilyLane(
        _ lanes: inout [String: FamilyLane], order: inout [String],
        config: DevinProto.ClientModelConfig, uid: String
    ) {
        guard let metadata = config.modelFamilyMetadata else { return }
        let label = metadata.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }

        var effort: String?
        var thinking: Bool?
        var fast = false
        var oneMillion = false
        for entry in metadata.entries where entry.hasValue {
            let key = squash(entry.key, separator: " ")
            switch key {
            case "fast mode": fast = entry.order == 1
            case "thinking": thinking = entry.order == 1
            case "1m context": oneMillion = entry.order == 1
            case "effort", "reasoning effort": effort = effortByName[squash(entry.name, separator: "")]
            default: break
            }
        }
        // Claude's paired non-thinking/thinking configs share one effort
        // label; the explicit Thinking axis decides whether the route is off.
        if thinking == false { effort = "off" }

        let baseId = squash(label, separator: "-")
        guard !baseId.isEmpty else { return }
        let laneId = baseId + (oneMillion ? "-1m" : "") + (fast ? "-fast" : "")
        if lanes[laneId] == nil {
            lanes[laneId] = FamilyLane(id: laneId, name: label + (oneMillion ? " 1M" : "") + (fast ? " Fast" : ""))
            order.append(laneId)
        }
        lanes[laneId]!.members.append(uid)
        if lanes[laneId]!.defaultMember == nil, config.isDefaultModelInFamily || metadata.isDefaultModelInFamily {
            lanes[laneId]!.defaultMember = uid
        }
        if let effort, lanes[laneId]!.routing[effort] == nil {
            lanes[laneId]!.routing[effort] = uid
        }
    }

    /// Lanes with at least one non-`off` effort route become families; the
    /// server default member is hoisted to the front.
    static func dynamicFamily(_ lane: FamilyLane) -> Family? {
        guard lane.routing.keys.contains(where: { $0 != "off" }) else { return nil }
        var members = lane.members
        if let def = lane.defaultMember {
            members = [def] + members.filter { $0 != def }
        }
        return Family(id: lane.id, name: lane.name, members: members, routing: lane.routing, defaultMember: lane.defaultMember)
    }

    // MARK: Reviewed static families (oh-my-pi `_collapse.kdl`, provider "devin")

    /// Families whose live configs lack `modelFamilyMetadata`. Families
    /// already collapsed from server metadata pass through untouched.
    static let staticFamilies: [Family] = [
        .init(id: "claude-opus-5", name: "Claude Opus 5", members: ["claude-opus-5-low", "claude-opus-5-medium", "claude-opus-5-high", "claude-opus-5-xhigh", "claude-opus-5-max"], routing: ["low": "claude-opus-5-low", "medium": "claude-opus-5-medium", "high": "claude-opus-5-high", "xhigh": "claude-opus-5-xhigh", "max": "claude-opus-5-max"]),
        .init(id: "claude-opus-5-fast", name: "Claude Opus 5 Fast", members: ["claude-opus-5-low-fast", "claude-opus-5-medium-fast", "claude-opus-5-high-fast", "claude-opus-5-xhigh-fast", "claude-opus-5-max-fast"], routing: ["low": "claude-opus-5-low-fast", "medium": "claude-opus-5-medium-fast", "high": "claude-opus-5-high-fast", "xhigh": "claude-opus-5-xhigh-fast", "max": "claude-opus-5-max-fast"]),
        .init(id: "claude-fable-5", name: "Claude Fable 5", members: ["claude-5-fable-low", "claude-5-fable-medium", "claude-5-fable-high", "claude-5-fable-xhigh", "claude-5-fable-max"], routing: ["low": "claude-5-fable-low", "medium": "claude-5-fable-medium", "high": "claude-5-fable-high", "xhigh": "claude-5-fable-xhigh", "max": "claude-5-fable-max"]),
        .init(id: "claude-sonnet-5", name: "Claude Sonnet 5", members: ["claude-sonnet-5-low", "claude-sonnet-5-medium", "claude-sonnet-5-high", "claude-sonnet-5-xhigh", "claude-sonnet-5-max"], routing: ["low": "claude-sonnet-5-low", "medium": "claude-sonnet-5-medium", "high": "claude-sonnet-5-high", "xhigh": "claude-sonnet-5-xhigh", "max": "claude-sonnet-5-max"]),
        .init(id: "claude-opus-4-7", name: "Claude Opus 4.7", members: ["claude-opus-4-7-low", "claude-opus-4-7-medium", "claude-opus-4-7-high", "claude-opus-4-7-xhigh", "claude-opus-4-7-max"], routing: ["low": "claude-opus-4-7-low", "medium": "claude-opus-4-7-medium", "high": "claude-opus-4-7-high", "xhigh": "claude-opus-4-7-xhigh", "max": "claude-opus-4-7-max"]),
        .init(id: "claude-opus-4-7-fast", name: "Claude Opus 4.7 Fast", members: ["claude-opus-4-7-low-fast", "claude-opus-4-7-medium-fast", "claude-opus-4-7-high-fast", "claude-opus-4-7-xhigh-fast", "claude-opus-4-7-max-fast"], routing: ["low": "claude-opus-4-7-low-fast", "medium": "claude-opus-4-7-medium-fast", "high": "claude-opus-4-7-high-fast", "xhigh": "claude-opus-4-7-xhigh-fast", "max": "claude-opus-4-7-max-fast"]),
        .init(id: "claude-opus-4-8", name: "Claude Opus 4.8", members: ["claude-opus-4-8-low", "claude-opus-4-8-medium", "claude-opus-4-8-high", "claude-opus-4-8-xhigh", "claude-opus-4-8-max"], routing: ["low": "claude-opus-4-8-low", "medium": "claude-opus-4-8-medium", "high": "claude-opus-4-8-high", "xhigh": "claude-opus-4-8-xhigh", "max": "claude-opus-4-8-max"]),
        .init(id: "claude-opus-4-8-fast", name: "Claude Opus 4.8 Fast", members: ["claude-opus-4-8-low-fast", "claude-opus-4-8-medium-fast", "claude-opus-4-8-high-fast", "claude-opus-4-8-xhigh-fast", "claude-opus-4-8-max-fast"], routing: ["low": "claude-opus-4-8-low-fast", "medium": "claude-opus-4-8-medium-fast", "high": "claude-opus-4-8-high-fast", "xhigh": "claude-opus-4-8-xhigh-fast", "max": "claude-opus-4-8-max-fast"]),
        .init(id: "gpt-5-2", name: "GPT-5.2", members: ["MODEL_GPT_5_2_NONE", "MODEL_GPT_5_2_LOW", "MODEL_GPT_5_2_MEDIUM", "MODEL_GPT_5_2_HIGH", "MODEL_GPT_5_2_XHIGH"], routing: ["off": "MODEL_GPT_5_2_NONE", "low": "MODEL_GPT_5_2_LOW", "medium": "MODEL_GPT_5_2_MEDIUM", "high": "MODEL_GPT_5_2_HIGH", "xhigh": "MODEL_GPT_5_2_XHIGH"]),
        .init(id: "gpt-5-3-codex", name: "GPT-5.3 Codex", members: ["gpt-5-3-codex-low", "gpt-5-3-codex-medium", "gpt-5-3-codex-high", "gpt-5-3-codex-xhigh"], routing: ["low": "gpt-5-3-codex-low", "medium": "gpt-5-3-codex-medium", "high": "gpt-5-3-codex-high", "xhigh": "gpt-5-3-codex-xhigh"]),
        .init(id: "gpt-5-3-codex-fast", name: "GPT-5.3 Codex Fast", members: ["gpt-5-3-codex-low-priority", "gpt-5-3-codex-medium-priority", "gpt-5-3-codex-high-priority", "gpt-5-3-codex-xhigh-priority"], routing: ["low": "gpt-5-3-codex-low-priority", "medium": "gpt-5-3-codex-medium-priority", "high": "gpt-5-3-codex-high-priority", "xhigh": "gpt-5-3-codex-xhigh-priority"]),
        .init(id: "gpt-5-4", name: "GPT-5.4", members: ["gpt-5-4-none", "gpt-5-4-low", "gpt-5-4-medium", "gpt-5-4-high", "gpt-5-4-xhigh"], routing: ["off": "gpt-5-4-none", "low": "gpt-5-4-low", "medium": "gpt-5-4-medium", "high": "gpt-5-4-high", "xhigh": "gpt-5-4-xhigh"]),
        .init(id: "gpt-5-4-fast", name: "GPT-5.4 Fast", members: ["gpt-5-4-none-priority", "gpt-5-4-low-priority", "gpt-5-4-medium-priority", "gpt-5-4-high-priority", "gpt-5-4-xhigh-priority"], routing: ["off": "gpt-5-4-none-priority", "low": "gpt-5-4-low-priority", "medium": "gpt-5-4-medium-priority", "high": "gpt-5-4-high-priority", "xhigh": "gpt-5-4-xhigh-priority"]),
        .init(id: "gpt-5-4-mini", name: "GPT-5.4 Mini", members: ["gpt-5-4-mini-low", "gpt-5-4-mini-medium", "gpt-5-4-mini-high", "gpt-5-4-mini-xhigh"], routing: ["low": "gpt-5-4-mini-low", "medium": "gpt-5-4-mini-medium", "high": "gpt-5-4-mini-high", "xhigh": "gpt-5-4-mini-xhigh"]),
        .init(id: "gpt-5-5", name: "GPT-5.5", members: ["gpt-5-5-none", "gpt-5-5-low", "gpt-5-5-medium", "gpt-5-5-high", "gpt-5-5-xhigh"], routing: ["off": "gpt-5-5-none", "low": "gpt-5-5-low", "medium": "gpt-5-5-medium", "high": "gpt-5-5-high", "xhigh": "gpt-5-5-xhigh"]),
        .init(id: "gpt-5-5-fast", name: "GPT-5.5 Fast", members: ["gpt-5-5-none-priority", "gpt-5-5-low-priority", "gpt-5-5-medium-priority", "gpt-5-5-high-priority", "gpt-5-5-xhigh-priority"], routing: ["off": "gpt-5-5-none-priority", "low": "gpt-5-5-low-priority", "medium": "gpt-5-5-medium-priority", "high": "gpt-5-5-high-priority", "xhigh": "gpt-5-5-xhigh-priority"]),
        .init(id: "gpt-5-6-luna", name: "GPT-5.6 Luna", members: ["gpt-5-6-luna-none", "gpt-5-6-luna-low", "gpt-5-6-luna-medium", "gpt-5-6-luna-high", "gpt-5-6-luna-xhigh", "gpt-5-6-luna-max"], routing: ["off": "gpt-5-6-luna-none", "low": "gpt-5-6-luna-low", "medium": "gpt-5-6-luna-medium", "high": "gpt-5-6-luna-high", "xhigh": "gpt-5-6-luna-xhigh", "max": "gpt-5-6-luna-max"]),
        .init(id: "gpt-5-6-luna-fast", name: "GPT-5.6 Luna Fast", members: ["gpt-5-6-luna-none-priority", "gpt-5-6-luna-low-priority", "gpt-5-6-luna-medium-priority", "gpt-5-6-luna-high-priority", "gpt-5-6-luna-xhigh-priority", "gpt-5-6-luna-max-priority"], routing: ["off": "gpt-5-6-luna-none-priority", "low": "gpt-5-6-luna-low-priority", "medium": "gpt-5-6-luna-medium-priority", "high": "gpt-5-6-luna-high-priority", "xhigh": "gpt-5-6-luna-xhigh-priority", "max": "gpt-5-6-luna-max-priority"]),
        .init(id: "gpt-5-6-sol", name: "GPT-5.6 Sol", members: ["gpt-5-6-sol-none", "gpt-5-6-sol-low", "gpt-5-6-sol-medium", "gpt-5-6-sol-high", "gpt-5-6-sol-xhigh", "gpt-5-6-sol-max"], routing: ["off": "gpt-5-6-sol-none", "low": "gpt-5-6-sol-low", "medium": "gpt-5-6-sol-medium", "high": "gpt-5-6-sol-high", "xhigh": "gpt-5-6-sol-xhigh", "max": "gpt-5-6-sol-max"]),
        .init(id: "gpt-5-6-sol-fast", name: "GPT-5.6 Sol Fast", members: ["gpt-5-6-sol-none-priority", "gpt-5-6-sol-low-priority", "gpt-5-6-sol-medium-priority", "gpt-5-6-sol-high-priority", "gpt-5-6-sol-xhigh-priority", "gpt-5-6-sol-max-priority"], routing: ["off": "gpt-5-6-sol-none-priority", "low": "gpt-5-6-sol-low-priority", "medium": "gpt-5-6-sol-medium-priority", "high": "gpt-5-6-sol-high-priority", "xhigh": "gpt-5-6-sol-xhigh-priority", "max": "gpt-5-6-sol-max-priority"]),
        .init(id: "gpt-5-6-terra", name: "GPT-5.6 Terra", members: ["gpt-5-6-terra-none", "gpt-5-6-terra-low", "gpt-5-6-terra-medium", "gpt-5-6-terra-high", "gpt-5-6-terra-xhigh", "gpt-5-6-terra-max"], routing: ["off": "gpt-5-6-terra-none", "low": "gpt-5-6-terra-low", "medium": "gpt-5-6-terra-medium", "high": "gpt-5-6-terra-high", "xhigh": "gpt-5-6-terra-xhigh", "max": "gpt-5-6-terra-max"]),
        .init(id: "gpt-5-6-terra-fast", name: "GPT-5.6 Terra Fast", members: ["gpt-5-6-terra-none-priority", "gpt-5-6-terra-low-priority", "gpt-5-6-terra-medium-priority", "gpt-5-6-terra-high-priority", "gpt-5-6-terra-xhigh-priority", "gpt-5-6-terra-max-priority"], routing: ["off": "gpt-5-6-terra-none-priority", "low": "gpt-5-6-terra-low-priority", "medium": "gpt-5-6-terra-medium-priority", "high": "gpt-5-6-terra-high-priority", "xhigh": "gpt-5-6-terra-xhigh-priority", "max": "gpt-5-6-terra-max-priority"]),
        .init(id: "kimi-k3", name: "Kimi K3", members: ["kimi-k3-low", "kimi-k3-high", "kimi-k3-max"], routing: ["low": "kimi-k3-low", "high": "kimi-k3-high", "max": "kimi-k3-max"]),
        .init(id: "swe-1-7", name: "SWE-1.7", members: ["swe-1-7-medium", "swe-1-7"], routing: ["medium": "swe-1-7-medium", "max": "swe-1-7"]),
        .init(id: "grok-4-5", name: "Grok 4.5", members: ["grok-4-5-low", "grok-4-5-medium", "grok-4-5-high"], routing: ["low": "grok-4-5-low", "medium": "grok-4-5-medium", "high": "grok-4-5-high"]),
        .init(id: "inkling", name: "Inkling", members: ["inkling-none", "inkling-low", "inkling-medium", "inkling-high", "inkling-xhigh", "inkling-max"], routing: ["off": "inkling-none", "low": "inkling-low", "medium": "inkling-medium", "high": "inkling-high", "xhigh": "inkling-xhigh", "max": "inkling-max"]),
        .init(id: "gemini-3-1-pro", name: "Gemini 3.1 Pro", members: ["gemini-3-1-pro-low", "gemini-3-1-pro-high"], routing: ["low": "gemini-3-1-pro-low", "high": "gemini-3-1-pro-high"]),
        .init(id: "gemini-3-5-flash", name: "Gemini 3.5 Flash", members: ["gemini-3-5-flash-minimal", "gemini-3-5-flash-low", "gemini-3-5-flash-medium", "gemini-3-5-flash-high"], routing: ["minimal": "gemini-3-5-flash-minimal", "low": "gemini-3-5-flash-low", "medium": "gemini-3-5-flash-medium", "high": "gemini-3-5-flash-high"]),
        .init(id: "gemini-3-6-flash", name: "Gemini 3.6 Flash", members: ["gemini-3-6-flash-minimal", "gemini-3-6-flash-low", "gemini-3-6-flash-medium", "gemini-3-6-flash-high"], routing: ["minimal": "gemini-3-6-flash-minimal", "low": "gemini-3-6-flash-low", "medium": "gemini-3-6-flash-medium", "high": "gemini-3-6-flash-high"]),
        .init(id: "gemini-3-flash", name: "Gemini 3 Flash", members: ["MODEL_GOOGLE_GEMINI_3_0_FLASH_MINIMAL", "MODEL_GOOGLE_GEMINI_3_0_FLASH_LOW", "MODEL_GOOGLE_GEMINI_3_0_FLASH_MEDIUM", "MODEL_GOOGLE_GEMINI_3_0_FLASH_HIGH"], routing: ["minimal": "MODEL_GOOGLE_GEMINI_3_0_FLASH_MINIMAL", "low": "MODEL_GOOGLE_GEMINI_3_0_FLASH_LOW", "medium": "MODEL_GOOGLE_GEMINI_3_0_FLASH_MEDIUM", "high": "MODEL_GOOGLE_GEMINI_3_0_FLASH_HIGH"]),
        .init(id: "glm-5-2", name: "GLM-5.2", members: ["glm-5-2", "glm-5-2-none", "glm-5-2-max"], routing: ["high": "glm-5-2", "xhigh": "glm-5-2"]),
        .init(id: "glm-5-2-1m", name: "GLM-5.2 1M", members: ["glm-5-2-none-1m", "glm-5-2-1m", "glm-5-2-max-1m"], routing: ["off": "glm-5-2-none-1m", "high": "glm-5-2-1m", "xhigh": "glm-5-2-max-1m"]),
        .init(id: "gemini-3-7-flash", name: "Gemini 3.7 Flash", members: ["gemini-3-7-flash-medium", "gemini-3-7-flash-minimal", "gemini-3-7-flash-low", "gemini-3-7-flash-high"], routing: ["minimal": "gemini-3-7-flash-minimal", "low": "gemini-3-7-flash-low", "medium": "gemini-3-7-flash-medium", "high": "gemini-3-7-flash-high"], defaultMember: "gemini-3-7-flash-medium"),
        .init(id: "swe-1-7-lightning", name: "SWE-1.7 Lightning", members: ["swe-1-7-lightning-medium", "swe-1-7-lightning"], routing: ["medium": "swe-1-7-lightning-medium", "max": "swe-1-7-lightning"], defaultMember: "swe-1-7-lightning-medium"),
        .init(id: "grok-4-6", name: "Grok 4.6", members: ["grok-4-6-medium", "grok-4-6-low", "grok-4-6-high", "grok-4-6-xhigh"], routing: ["low": "grok-4-6-low", "medium": "grok-4-6-medium", "high": "grok-4-6-high", "xhigh": "grok-4-6-xhigh"], defaultMember: "grok-4-6-medium"),
        .init(id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", members: ["deepseek-v4-flash-high", "deepseek-v4-flash-low", "deepseek-v4-flash-max"], routing: ["low": "deepseek-v4-flash-low", "high": "deepseek-v4-flash-high", "max": "deepseek-v4-flash-max"], defaultMember: "deepseek-v4-flash-high"),
        .init(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", members: ["deepseek-v4-pro-high", "deepseek-v4-pro-low", "deepseek-v4-pro-max"], routing: ["low": "deepseek-v4-pro-low", "high": "deepseek-v4-pro-high", "max": "deepseek-v4-pro-max"], defaultMember: "deepseek-v4-pro-high"),
        .init(id: "nemotron-3-ultra", name: "Nemotron 3 Ultra", members: ["nemotron-3-ultra-high", "nemotron-3-ultra-none", "nemotron-3-ultra-medium"], routing: ["off": "nemotron-3-ultra-none", "medium": "nemotron-3-ultra-medium", "high": "nemotron-3-ultra-high"], defaultMember: "nemotron-3-ultra-high"),
        .init(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", members: ["MODEL_PRIVATE_11"], routing: [:]),
    ]
}
