import Foundation

/// Trae's chat, over `OpenAICompletionsProvider`: the request body is
/// reshaped for the gate and the gate's frames are rewritten into OpenAI
/// chunks on the way back (`TraeWire`, `TraeChatClient`), so the encoding of
/// the conversation and the decoding of the stream stay kwwk's.
public struct TraeProvider: APIProvider {
    public let api = "openai-completions"
    public let site: TraeSite
    private let completions: OpenAICompletionsProvider

    /// `functions` names, per model id, the directory function that lists
    /// the model: the only one it may be asked through.
    public init(
        site: TraeSite,
        functions: [String: String] = [:],
        client: HTTPClient = URLSessionHTTPClient()
    ) {
        self.site = site
        completions = OpenAICompletionsProvider(
            client: TraeChatClient(inner: client),
            defaultBaseURL: TraeWire.chatURL(site),
            extraHeaders: TraeWire.clientHeaders(),
            // The address is the endpoint itself, not a base to build on.
            urlBuilder: { _, _, endpoint in endpoint },
            bodyDecorator: { root, model, _, _ in
                TraeWire.mend(&root, function: functions[model.id] ?? TraeWire.defaultFunction)
            }
        )
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        completions.stream(model: model, context: context, options: options)
    }
}

// MARK: - Registration

/// Registers a stored Trae login (`registerStored`'s case for both builds).
/// The roster is read first where the login is the active one: a model is
/// asked through the function that lists it, and its row is the directory's.
/// Each request is signed with the account's JWT, renewed when it is about
/// to end, in the headers the gate reads it from.
func registerTrae(
    site: TraeSite,
    manager: OAuthManager,
    modelOverride: String? = nil,
    primeToken: Bool = true,
    client: HTTPClient = URLSessionHTTPClient()
) async -> ResolvedAuth {
    var roster: [TraeModels.Entry] = []
    if primeToken, let token = try? await manager.apiKey(for: site.id),
       let credentials = try? await manager.credentials(for: site.id) {
        roster = await TraeModels.roster(site: site, token: token, credentials: credentials, client: client)
    }
    let id = modelOverride ?? roster.first?.id ?? TraeModels.defaultModelId
    let model = roster.first { $0.id == id }.map { TraeModels.row($0, site: site) }
        ?? TraeModels.model(site: site, id: id)
    let functions = Dictionary(roster.map { ($0.id, $0.function) }) { first, _ in first }
    await APIRegistry.shared.register(
        TraeProvider(site: site, functions: functions, client: client),
        scope: site.id
    )
    return ResolvedAuth(
        model: model,
        modelLabel: "\(model.id) · \(site.name)",
        authResolver: { _, _ in
            do {
                let authorization = try await manager.authorization(for: site.id)
                guard let credentials = try await manager.credentials(for: site.id) else { return nil }
                // The gate reads the token from headers of its own, so none
                // goes out as a bearer.
                return ResolvedProviderAuth(
                    headers: TraeWire.accountHeaders(token: authorization.apiKey, credentials: credentials),
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
