import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Raccoon's chat. The wire is standard OpenAI over standard SSE
/// (`chat.completion.chunk` frames ending in `data: [DONE]`), so
/// `OpenAICompletionsProvider` speaks it as it is; what is Raccoon's own is
/// the client's headers, the account's `X-Org-Code`, and three mends of the
/// body (`RaccoonWire.mend`).
///
/// From JanXiao's provider for Apelin (owngoal-dev/Apelin#40), after
/// dsh-providers-hub's `raccoon-adapter.ts`.
public struct RaccoonProvider: APIProvider {
    public let api = "openai-completions"
    private let completions: OpenAICompletionsProvider

    public init(client: HTTPClient = URLSessionHTTPClient()) {
        completions = OpenAICompletionsProvider(
            client: client,
            defaultBaseURL: RaccoonWire.chatURL,
            extraHeaders: RaccoonWire.clientHeaders,
            // The address is the endpoint itself, not a base to build on.
            urlBuilder: { _, _, endpoint in endpoint },
            bodyDecorator: { root, model, _, options in
                RaccoonWire.mend(&root, model: model, options: options)
            }
        )
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        completions.stream(model: model, context: context, options: options)
    }
}

enum RaccoonWire {
    static let llmBase = RaccoonOAuth.origin + "/api/web/llm/v2"
    static let chatURL = URL(string: llmBase + "/chat/completions")!
    static let catalogURL = URL(string: llmBase + "/model_catalog")!

    /// What the gate's own desktop client sends with every request.
    static let clientHeaders = [
        "X-Raccoon-Language": "zh",
        "X-Client-Platform": "desktop-windows",
    ]

    /// The header that names the account's office, `office_identity` of its
    /// sign-in: without it the gate answers as to an unauthorized caller,
    /// even with a valid token.
    static func accountHeaders(_ credentials: OAuthCredentials) -> [String: String] {
        ["X-Org-Code": RaccoonOAuth.string(credentials.extras[RaccoonOAuth.officeIdentityExtra]) ?? ""]
    }

    /// The most output the gate takes. The catalogue names 100,000 for
    /// several models, and the upstream refuses anything above 65,536 with a
    /// 400 for the whole turn.
    static let maximumOutputTokens = 65_536

    static func clampOutputTokens(_ value: Int?) -> Int {
        guard let value, value > 0 else { return maximumOutputTokens }
        return min(value, maximumOutputTokens)
    }

    /// Shapes the body the gate reads:
    /// - the output limit is clamped to what the gate accepts;
    /// - `reasoning_effort` is removed: the gate accepts the field and
    ///   ignores it (the reference implementation measured no difference
    ///   between `minimal` and `max`);
    /// - a named thinking level goes inside `extra_body`, as `thinking.type`
    ///   `enabled`. At the top level the gate ignores it silently.
    ///
    /// The gate has two states, on and off, and its own default is on. A
    /// request that names no level sends no field and gets that default.
    static func mend(_ root: inout [String: Any], model: Model, options: StreamOptions?) {
        for field in ["max_tokens", "max_completion_tokens"] {
            if let limit = root[field] as? Int { root[field] = clampOutputTokens(limit) }
        }
        root.removeValue(forKey: "reasoning_effort")
        root.removeValue(forKey: "reasoning")
        guard model.reasoning, options?.reasoning != nil else { return }
        root["extra_body"] = ["thinking": ["type": "enabled"]]
    }
}

// MARK: - Registration

/// Registers a stored Raccoon login (`registerStored`'s case). The catalogue
/// is read first where the login is the active one, for the model's own row.
/// Each request is signed with the account's token, renewed when it is about
/// to end, and the header that names its office.
func registerRaccoon(
    manager: OAuthManager,
    modelOverride: String? = nil,
    primeToken: Bool = true,
    client: HTTPClient = URLSessionHTTPClient()
) async -> ResolvedAuth {
    let id = RaccoonOAuth.providerId
    var listed: [Model] = []
    if primeToken, let token = try? await manager.apiKey(for: id),
       let credentials = try? await manager.credentials(for: id) {
        listed = await RaccoonModels.catalog(token: token, credentials: credentials, client: client)
    }
    let modelId = modelOverride ?? listed.first?.id ?? RaccoonModels.defaultModelId
    let model = listed.first { $0.id == modelId } ?? RaccoonModels.model(id: modelId)
    await APIRegistry.shared.register(RaccoonProvider(client: client), scope: id)
    return ResolvedAuth(
        model: model,
        modelLabel: "\(model.name) · \(RaccoonOAuth.name)",
        authResolver: { _, _ in
            do {
                let authorization = try await manager.authorization(for: id)
                // Read after the token: a renewal may name the office again.
                guard let credentials = try await manager.credentials(for: id) else { return nil }
                return ResolvedProviderAuth(
                    token: authorization.apiKey,
                    scheme: .bearer,
                    headers: RaccoonWire.accountHeaders(credentials),
                    onRejected: authorization.onRejected
                )
            } catch OAuthError.missing, OAuthError.unknownProvider {
                // Not signed in ⇒ anonymous, as the other stored logins'
                // resolvers; any other failure reaches the request.
                return nil
            }
        }
    )
}
