import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Kiro's model list. The bundled `Resources/kiro-models.json` is a small
/// seed; an account's own list — what its plan offers, with each model's
/// token limits and whether it takes images — is asked of Kiro's management
/// API with `fetch` (magpie `kiroModels`).
public enum KiroModels {
    public static let api = "kiro-assistant"
    /// Kiro's Auto, which picks a model per request; every account has it,
    /// and it is what Kiro names as the default.
    public static let defaultModelId = "auto"

    static let defaultContextWindow = 200_000
    static let defaultMaxTokens = 64_000

    /// Where an account's `generateAssistantResponse` is served.
    public static func runtimeURL(region: String) -> String {
        "https://runtime.\(region).kiro.dev"
    }

    /// `GET List-Available-Models` for the login's profile, the default
    /// model first.
    public static func fetch(
        credentials: OAuthCredentials,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> [Model] {
        let query = OAuth.urlEncodedForm([
            "origin": "KIRO_CLI", "profileArn": KiroOAuth.profileArn(credentials) ?? "",
        ])
        guard let region = KiroOAuth.apiRegion(credentials),
              let url = URL(string: "\(KiroOAuth.managementURL(region: region))List-Available-Models?\(query)") else {
            throw ProviderFailure(message: "The Kiro login's profile names a region that is not one")
        }
        let (response, body) = try await client.request(
            url: url,
            method: "GET",
            headers: ["Authorization": "Bearer \(credentials.access)", "Accept": "application/json"],
            body: nil
        )
        guard (200..<300).contains(response.statusCode) else {
            throw KiroProvider.httpFailure(status: response.statusCode, body: body)
        }
        let models = try parse(body, region: region)
        guard !models.isEmpty else { throw ProviderFailure(message: "Kiro listed no models") }
        return models
    }

    /// ListAvailableModels' answer:
    ///
    ///     {"models": [{"modelId": "claude-sonnet-4.5", "modelName": "Claude Sonnet 4.5",
    ///       "supportedInputTypes": ["TEXT", "IMAGE"],
    ///       "tokenLimits": {"maxInputTokens": 200000, "maxOutputTokens": 64000}}],
    ///      "defaultModel": {"modelId": "auto"}}
    static func parse(_ data: Data, region: String = "us-east-1") throws -> [Model] {
        struct List: Decodable {
            struct Row: Decodable {
                struct Limits: Decodable {
                    var maxInputTokens: Int?
                    var maxOutputTokens: Int?
                }
                var modelId: String?
                var modelName: String?
                var supportedInputTypes: [String]?
                var tokenLimits: Limits?
            }
            struct Default: Decodable { var modelId: String? }
            var models: [Row]?
            var defaultModel: Default?
        }
        let list = try JSONDecoder().decode(List.self, from: data)
        var out: [Model] = []
        for row in list.models ?? [] {
            guard let id = row.modelId, !id.isEmpty else { continue }
            var name = row.modelName ?? ""
            if name.isEmpty || name == id { name = id == "auto" ? "Auto" : id }
            let images = (row.supportedInputTypes ?? []).contains { $0.uppercased() == "IMAGE" }
            let model = Model(
                id: id,
                name: name,
                api: api,
                provider: "kiro",
                baseURL: runtimeURL(region: region),
                reasoning: thinks(id),
                input: images ? [.text, .image] : [.text],
                contextWindow: row.tokenLimits?.maxInputTokens ?? defaultContextWindow,
                maxTokens: row.tokenLimits?.maxOutputTokens ?? defaultMaxTokens
            )
            if id == list.defaultModel?.modelId {
                out.insert(model, at: 0)
            } else {
                out.append(model)
            }
        }
        return out
    }

    /// Kiro's thinking mode is asked of Claude models, and of Auto, which
    /// picks one (see `KiroRequest.thinks`).
    static func thinks(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("claude") || lower == "auto"
    }
}

/// The catalog row for a Kiro model id, or a usable fallback for ids the
/// bundled seed doesn't carry (each plan lists its own).
public func kiroModel(id: String) -> Model {
    if let catalog = ModelsCatalog.model(provider: "kiro", id: id) { return catalog }
    return Model(
        id: id,
        name: id,
        api: KiroModels.api,
        provider: "kiro",
        baseURL: KiroModels.runtimeURL(region: "us-east-1"),
        reasoning: KiroModels.thinks(id),
        input: [.text],
        contextWindow: KiroModels.defaultContextWindow,
        maxTokens: KiroModels.defaultMaxTokens
    )
}

// MARK: - Stored login

/// Register the stored Kiro login (`registerStored`'s `"kiro"` case).
func registerKiro(
    manager: OAuthManager,
    modelOverride: String? = nil,
    primeToken: Bool = true
) async -> ResolvedAuth {
    // Prime the token only for the active provider; the resolver refreshes
    // lazily on the first request for the others.
    if primeToken {
        _ = try? await manager.apiKey(for: "kiro")
    }
    await APIRegistry.shared.register(KiroProvider(), scope: "kiro")
    let model = kiroModel(id: modelOverride ?? KiroModels.defaultModelId)
    return ResolvedAuth(
        model: model,
        modelLabel: "\(model.id) · Kiro",
        authResolver: kiroAuthResolver(manager: manager)
    )
}

/// A Kiro request needs more than its token: the profile ARN the login is
/// asked with goes in the body, and the API is served in the profile's
/// region. Both ride along on the resolved auth.
func kiroAuthResolver(
    manager: OAuthManager
) -> @Sendable (Model, String?) async throws -> ResolvedProviderAuth? {
    { _, _ in
        do {
            let authorization = try await manager.authorization(for: "kiro")
            guard let credentials = try await manager.credentials(for: "kiro") else { return nil }
            guard let region = KiroOAuth.apiRegion(credentials) else {
                throw ProviderFailure(message: "The Kiro login names a region that is not one; sign in again")
            }
            var metadata: [String: JSONValue] = [:]
            if let profile = KiroOAuth.profileArn(credentials) { metadata["profileArn"] = .string(profile) }
            return ResolvedProviderAuth(
                token: authorization.apiKey,
                scheme: .bearer,
                baseURL: KiroModels.runtimeURL(region: region),
                metadata: metadata,
                onRejected: authorization.onRejected
            )
        } catch OAuthError.missing, OAuthError.unknownProvider {
            // Not logged in ⇒ anonymous; any other failure propagates.
            return nil
        }
    }
}
