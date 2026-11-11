import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Raccoon's models. An account's catalogue is read from the gate (`fetch`);
/// the rows in `seed` stand in before it has answered.
public enum RaccoonModels {
    /// The first of the gate's picker.
    public static let defaultModelId = "sn-sensenova-6-8-flash"

    static let defaultContextWindow = 200_000

    // MARK: - Rows

    /// The six visible models of the 2026-09-26 catalogue, in its order.
    static let seedRows: [Model] = [
        row(id: "sn-sensenova-6-8-flash", name: "SenseNova-6.8-Flash", contextWindow: 256_000, maxTokens: 63_999),
        row(
            id: "sn-sensenova-6-8-flash-lite",
            name: "SenseNova-6.8-Flash-Lite",
            contextWindow: 256_000,
            maxTokens: 63_999
        ),
        row(id: "sn-glm-5-3", name: "GLM-5-3", contextWindow: 1_000_000, maxTokens: 65_536),
        row(id: "sn-kimi-k3", name: "Kimi-K3", contextWindow: 1_000_000, maxTokens: 65_536),
        row(id: "sn-glm-5-3-flash", name: "GLM-5-3-Flash", contextWindow: 1_000_000, maxTokens: 65_536),
        row(id: "sn-deepseek-v4-1-flash", name: "DeepSeek-V4.1-Flash", contextWindow: 1_000_000, maxTokens: 65_536),
    ]

    /// The catalog's rows (`ModelsCatalog`).
    static var seed: [String: Model] {
        Dictionary(uniqueKeysWithValues: seedRows.map { ($0.id, $0) })
    }

    /// The catalog row for a model id, or a usable one for an id the seed
    /// doesn't carry (the catalogue is the account's own).
    public static func model(id: String) -> Model {
        ModelsCatalog.model(provider: RaccoonOAuth.providerId, id: id) ?? row(
            id: id,
            name: id,
            contextWindow: defaultContextWindow,
            maxTokens: RaccoonWire.maximumOutputTokens,
            images: false
        )
    }

    static func row(
        id: String,
        name: String,
        contextWindow: Int,
        maxTokens: Int,
        images: Bool = true
    ) -> Model {
        Model(
            id: id,
            name: name,
            api: "openai-completions",
            provider: RaccoonOAuth.providerId,
            baseURL: RaccoonWire.chatURL.absoluteString,
            reasoning: true,
            input: images ? [.text, .image] : [.text],
            contextWindow: contextWindow,
            maxTokens: maxTokens,
            thinkingLevelMap: noLevels
        )
    }

    /// Every model thinks by the gate's own default, and no request made of
    /// the gate so far has named a level, so none is offered.
    /// (`RaccoonWire.mend` turns a named one into the gate's `thinking`
    /// field, for a row that offers one.)
    static let noLevels: [String: String?] = Dictionary(
        uniqueKeysWithValues: ModelThinkingLevel.allCases.map { ($0.rawValue, String?.none) }
    )

    // MARK: - Live catalogue

    /// The account's models as catalog rows, read live.
    public static func fetch(
        credentials: OAuthCredentials,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> [Model] {
        let listed = await catalog(token: credentials.access, credentials: credentials, client: client)
        guard !listed.isEmpty else {
            throw ProviderFailure(message: "\(RaccoonOAuth.name)'s catalogue lists no models for this account")
        }
        return listed
    }

    private static let catalogues = AccountListingCache<[Model]>()

    /// How long the catalogue is waited for.
    static let catalogTimeout: TimeInterval = 15

    /// `GET /api/web/llm/v2/model_catalog`: the account's models in the
    /// gate's own order; empty for an answer that cannot be read.
    ///
    /// Kept per office (`AccountListingCache`).
    static func catalog(token: String, credentials: OAuthCredentials, client: HTTPClient) async -> [Model] {
        let account = RaccoonWire.accountHeaders(credentials)
        let key = account["X-Org-Code"] ?? ""
        if let kept = catalogues.listing(for: key) { return kept }
        var headers = RaccoonWire.clientHeaders.merging(account) { _, own in own }
        headers["Authorization"] = bearerHeaderValue(token)
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json"
        do {
            let (response, stream) = try await client.stream(
                url: RaccoonWire.catalogURL,
                method: "GET",
                headers: headers,
                body: nil,
                cancellation: nil,
                timeoutSeconds: catalogTimeout
            )
            guard response.statusCode == 200 else { return [] }
            var answer = Data()
            for try await chunk in stream {
                answer.append(chunk)
                guard answer.count <= 4 * 1024 * 1024 else { return [] }
            }
            guard let root = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any] else { return [] }
            let models = rows(in: (root["data"] ?? root["Data"]) as? [String: Any] ?? root)
            if !models.isEmpty { catalogues.keep(models, for: key) }
            return models
        } catch {
            return []
        }
    }

    /// The visible models of one `model_catalog` answer, each id once. The
    /// gate lists internal `raccoon-*` models with `visible: false`, which
    /// an account cannot call.
    static func rows(in catalog: [String: Any]) -> [Model] {
        var out: [Model] = []
        for category in catalog["categories"] as? [[String: Any]] ?? [] {
            for listed in category["models"] as? [[String: Any]] ?? [] {
                if listed["visible"] as? Bool == false { continue }
                guard let row = row(listed), !out.contains(where: { $0.id == row.id }) else { continue }
                out.append(row)
            }
        }
        return out
    }

    /// One model of the catalogue. Since 2026-10-04 the gate names a model
    /// by `model_name` and carries no `id` at all, and the older fields
    /// (`vision`, `input_modalities`, `context_window`, `max_output_*`) are
    /// gone: read by them alone, the catalogue is empty with no error. They
    /// stay as fallbacks for a gate that goes back to them.
    static func row(_ listed: [String: Any]) -> Model? {
        let string = GateEnvelope.firstString
        guard let id = string(listed, ["model_name", "id", "modelName"]) else { return nil }
        let params = listed["params"] as? [String: Any] ?? [:]
        func int(_ value: Any?) -> Int? {
            switch value {
            case let number as NSNumber: number.intValue
            case let text as String: Int(text)
            default: nil
            }
        }
        return row(
            id: id,
            name: string(listed, ["display_name", "displayName", "name"]) ?? id,
            contextWindow: int(listed["context_window"] ?? listed["contextWindow"])
                ?? int(params["context_window"] ?? params["contextWindow"])
                ?? defaultContextWindow,
            maxTokens: RaccoonWire.clampOutputTokens(
                int(listed["max_output_length"] ?? listed["maxOutputLength"])
                    ?? int(params["max_tokens"] ?? params["maxTokens"])
            ),
            images: readsImages(id: id, listed)
        )
    }

    /// Whether the model reads images. The catalogue says so in `tags`; the
    /// gate has never sent a modality field. `sn-deepseek-v4-1-flash` reads
    /// them with no `vision` tag, which the reference implementation
    /// measured with a real image: a model joins it by a probe, not a
    /// belief.
    static func readsImages(id: String, _ listed: [String: Any]) -> Bool {
        if let said = listed["vision"] as? Bool { return said }
        if (listed["input_modalities"] as? [String])?.contains("image") == true { return true }
        let tags = Set((listed["tags"] as? [String] ?? []).map { $0.lowercased() })
        return !tags.isDisjoint(with: ["vision", "image", "image-understanding"])
            || id == "sn-deepseek-v4-1-flash"
    }
}
