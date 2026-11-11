import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Trae's models. An account's roster is its own, read from the gate's
/// directory (`fetch`); the rows in `seed` stand in before it has answered,
/// the same ones for both builds.
public enum TraeModels {
    /// The model a session talks to when none was chosen: the gate's own
    /// router.
    public static let defaultModelId = "auto"

    /// The directory functions a model may be listed under, in the order
    /// they are asked. A model is callable only through the function whose
    /// roster publishes it. `solo_work_remote` carries every model a user
    /// may pick (`glm-5.3` is only there, and asked through `solo_work_lite`
    /// it answers `4001 param is invalid`); `solo_work_lite` lists internal
    /// agent entries too, so it only adds what the first one lacks.
    static let directoryFunctions = [TraeWire.defaultFunction, "solo_work_lite"]

    /// One model as the directory publishes it, with the function that lists
    /// it.
    public struct Entry: Sendable, Hashable {
        public var id: String
        public var function: String
        /// The directory calls it a reasoning model.
        public var reasoning: Bool
        public var contextWindow: Int
        public var maxTokens: Int
    }

    // MARK: - Rows

    /// The models offered before (or instead of) a live roster: the China
    /// client's own catalogue with the entries the SOLO channel cannot call
    /// left out, every one reachable through `solo_work_remote`.
    static let seedEntries: [Entry] = [
        entry(defaultModelId, reasoning: false, contextWindow: 200_000),
        entry("Doubao-Seed-Evolving", reasoning: false, contextWindow: 262_144),
        entry("Doubao-Seed-2.1-Pro", reasoning: true, contextWindow: 262_144),
        entry("Doubao-Seed-2.1-Turbo", reasoning: true, contextWindow: 262_144, maxTokens: 32_000),
        entry("glm-5.3", reasoning: true, contextWindow: 119_040),
        entry("glm-5.2", reasoning: true, contextWindow: 119_040),
        entry("DeepSeek-V4-Flash-Official", reasoning: true, contextWindow: 119_040),
        entry("DeepSeek-V4-Pro-Official", reasoning: true, contextWindow: 119_040),
        entry("kimi-k3", reasoning: true, contextWindow: 204_800),
        entry("minimax-m3", reasoning: false, contextWindow: 119_040),
        entry("qwen3.8-max", reasoning: true, contextWindow: 204_800),
        entry("qwen-3.7-plus", reasoning: false, contextWindow: 204_800),
    ]

    private static func entry(
        _ id: String,
        reasoning: Bool,
        contextWindow: Int,
        maxTokens: Int = defaultMaxTokens
    ) -> Entry {
        Entry(
            id: id,
            function: TraeWire.defaultFunction,
            reasoning: reasoning,
            contextWindow: contextWindow,
            maxTokens: maxTokens
        )
    }

    static let defaultContextWindow = 200_000
    static let defaultMaxTokens = 64_000

    /// The catalog's rows for `site` (`ModelsCatalog`).
    static func seed(on site: TraeSite) -> [String: Model] {
        Dictionary(uniqueKeysWithValues: seedEntries.map { ($0.id, row($0, site: site)) })
    }

    /// The catalog row for a model id, or a usable one for an id the seed
    /// doesn't carry (the roster is the account's own).
    public static func model(site: TraeSite, id: String) -> Model {
        ModelsCatalog.model(provider: site.id, id: id) ?? row(
            Entry(
                id: id,
                function: TraeWire.defaultFunction,
                reasoning: false,
                contextWindow: defaultContextWindow,
                maxTokens: defaultMaxTokens
            ),
            site: site
        )
    }

    static func row(_ entry: Entry, site: TraeSite) -> Model {
        Model(
            id: entry.id,
            name: entry.id,
            api: "openai-completions",
            provider: site.id,
            baseURL: TraeWire.chatURL(site).absoluteString,
            reasoning: entry.reasoning,
            contextWindow: entry.contextWindow,
            maxTokens: entry.maxTokens,
            thinkingLevelMap: entry.reasoning ? noLevels : nil
        )
    }

    /// The directory says which models reason and names no levels for them,
    /// and no request made of the gate so far has carried one: a reasoning
    /// model thinks at its own default, and none is offered. (`TraeWire.mend`
    /// passes a level on, as the reference client does, for a row that
    /// names one.)
    static let noLevels: [String: String?] = Dictionary(
        uniqueKeysWithValues: ModelThinkingLevel.allCases.map { ($0.rawValue, String?.none) }
    )

    // MARK: - Live roster

    /// The account's models as catalog rows for `site`, read live.
    public static func fetch(
        site: TraeSite,
        credentials: OAuthCredentials,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> [Model] {
        let roster = await roster(site: site, token: credentials.access, credentials: credentials, client: client)
        guard !roster.isEmpty else {
            throw ProviderFailure(message: "\(site.name)'s directory lists no models for this account")
        }
        return roster.map { row($0, site: site) }
    }

    /// The account's roster: every function asked at once, the first listing
    /// of an id kept, in the order the functions are declared. A function
    /// that does not answer costs only its own models; empty when none does.
    ///
    /// Kept for ten minutes per account: a host resolves its provider on
    /// every session and every model switch, and the gate's answer does not
    /// change that often.
    static func roster(
        site: TraeSite,
        token: String,
        credentials: OAuthCredentials,
        client: HTTPClient
    ) async -> [Entry] {
        let account = "\(site.id)|\(TraeOAuth.string(credentials.extras[TraeOAuth.userIDExtra]) ?? "")"
        if let kept = RosterCache.shared.roster(for: account) { return kept }
        let headers = TraeWire.clientHeaders()
            .merging(TraeWire.accountHeaders(token: token, credentials: credentials)) { _, account in account }
            .merging(["Accept": "application/json", "Content-Type": "application/json"]) { _, json in json }
        let url = URL(string: site.gateway + "/api/ide/v1/get_detail_param")!
        let listed = await withTaskGroup(of: (Int, [Entry]).self) { group in
            for (index, function) in directoryFunctions.enumerated() {
                group.addTask {
                    (index, await entries(function: function, url: url, headers: headers, client: client))
                }
            }
            var answers: [(Int, [Entry])] = []
            for await answer in group { answers.append(answer) }
            return answers.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        var seen: Set<String> = []
        let roster = listed.filter { seen.insert($0.id).inserted }
        if !roster.isEmpty { RosterCache.shared.keep(roster, for: account) }
        return roster
    }

    /// How long one function's listing is waited for: a sign-in that reads
    /// the roster to verify the account has well under a minute for all of
    /// it.
    static let directoryTimeout: TimeInterval = 12

    /// `POST <gateway>/api/ide/v1/get_detail_param` for one function; empty
    /// for an answer that cannot be read.
    private static func entries(
        function: String,
        url: URL,
        headers: [String: String],
        client: HTTPClient
    ) async -> [Entry] {
        let body: [String: Any] = [
            "function": function,
            "config_names": NSNull(),
            "need_prompt": false,
            "current_config_info": NSNull(),
            "poly_prompt": true,
            "mode_type": NSNull(),
            "agent_type": NSNull(),
        ]
        do {
            let (response, stream) = try await client.stream(
                url: url,
                method: "POST",
                headers: headers,
                body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
                cancellation: nil,
                timeoutSeconds: directoryTimeout
            )
            guard response.statusCode == 200 else { return [] }
            var answer = Data()
            for try await chunk in stream {
                answer.append(chunk)
                guard answer.count <= 4 * 1024 * 1024 else { return [] }
            }
            guard let document = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any] else {
                return []
            }
            return entries(in: document, function: function)
        } catch {
            return []
        }
    }

    /// The models of one function's listing that a user may pick.
    static func entries(in document: [String: Any], function: String) -> [Entry] {
        (document["config_info_list"] as? [[String: Any]] ?? []).compactMap { listed in
            guard let id = listed["config_name"] as? String, !id.isEmpty, !isInternal(id),
                  listed["is_invisible_to_user"] as? Bool != true else { return nil }
            let display = listed["display_config"] as? [String: Any] ?? [:]
            let context = listed["context_window_tokens"] as? [String: Any] ?? [:]
            let detail = (listed["model_detail_list"] as? [[String: Any]])?.first ?? [:]
            let window = (context["dev"] as? NSNumber)?.intValue
                ?? (detail["prompt_max_tokens"] as? NSNumber)?.intValue ?? 0
            let maxTokens = (detail["max_tokens"] as? NSNumber)?.intValue ?? 0
            return Entry(
                id: id,
                function: function,
                reasoning: display["model_capability"] as? String == "reasoning_model",
                contextWindow: window > 0 ? window : defaultContextWindow,
                maxTokens: maxTokens > 0 ? maxTokens : defaultMaxTokens
            )
        }
    }

    /// The directory lists the agent's own entries (sub-agents, summarizers,
    /// helpers) beside the models a user may pick. No user-facing id carries
    /// `agent` in it.
    static func isInternal(_ id: String) -> Bool {
        if id.hasPrefix("custom_model_") || id.contains("agent") { return true }
        if id.contains("_advisor") || id.hasSuffix("_auto") { return true }
        if ["summary", "title_generation", "input_optimization", "fast_apply"].contains(where: id.hasPrefix) {
            return true
        }
        return id == "sagitta" || id == "aquila"
    }
}

/// The rosters this process has read, per account, for ten minutes.
private final class RosterCache: @unchecked Sendable {
    static let shared = RosterCache()

    private let lock = NSLock()
    private var kept: [String: (roster: [TraeModels.Entry], at: Date)] = [:]
    private let lifetime: TimeInterval = 10 * 60

    func roster(for account: String) -> [TraeModels.Entry]? {
        lock.withLock {
            guard let entry = kept[account], Date().timeIntervalSince(entry.at) < lifetime else { return nil }
            return entry.roster
        }
    }

    func keep(_ roster: [TraeModels.Entry], for account: String) {
        lock.withLock { kept[account] = (roster, Date()) }
    }
}
