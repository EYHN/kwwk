import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A plan on OpenCode's model gateway (opencode.ai): Go, the monthly coding
/// subscription, or Zen, pay-as-you-go. Both take an OpenCode Console API key
/// as a bearer token and serve each model over the wire its catalog entry
/// names, every wire under the plan's own root
/// (https://opencode.ai/v2/docs/console/harnesses#base-urls):
///
///   - Chat Completions and Responses at `<root>/openai/v1`
///   - Anthropic Messages at `<root>/anthropic`
///   - Gemini at `<root>/google`
///
/// kwwk's transports append their own version and path to these. The
/// catalog's `baseUrl`s are not used: its Gemini entries name `<root>/v1`,
/// which becomes `<root>/v1/v1beta/models/…`, a path the gateway answers 404.
///
/// The gateway routes and caches a conversation by `x-opencode-session`
/// (`OpenCodeRequestProvider`). Go refuses a request without it, 400
/// `MissingSessionID`, before it reads the key, which is why an
/// OpenAI-compatible login cannot reach Go; Zen takes it as well.
public struct OpenCodePlan: Sendable, Hashable {
    /// Store id, `model.provider` scope and catalog key alike.
    public let id: String
    public let name: String
    /// The plan's gateway root; each wire's path goes after it.
    public let rootURL: String
    /// The model a login starts on when it names none.
    public let defaultModel: String

    public init(id: String, name: String, rootURL: String, defaultModel: String) {
        self.id = id
        self.name = name
        self.rootURL = rootURL
        self.defaultModel = defaultModel
    }

    public static let go = OpenCodePlan(
        id: "opencode-go",
        name: "OpenCode Go",
        rootURL: "https://opencode.ai/inference/go",
        defaultModel: "glm-5.2"
    )
    public static let zen = OpenCodePlan(
        id: "opencode",
        name: "OpenCode Zen",
        rootURL: "https://opencode.ai/inference",
        defaultModel: "claude-sonnet-5"
    )
    public static let all: [OpenCodePlan] = [.go, .zen]

    public static func plan(id: String) -> OpenCodePlan? {
        all.first { $0.id == id }
    }

    /// The wires the gateway serves. Every text model answers on Chat
    /// Completions too (the gateway translates), so an id the bundled catalog
    /// does not carry yet goes there.
    public static let wires = [
        "openai-completions", "openai-responses", "anthropic-messages", "google-generative-ai",
    ]

    /// Where `api` is served on this plan.
    public func baseURL(for api: String) -> String {
        switch api {
        case "anthropic-messages": rootURL + "/anthropic"
        case "google-generative-ai": rootURL + "/google"
        default: rootURL + "/openai/v1"
        }
    }
}

extension ProviderVariants {
    // MARK: - OpenCode Go / Zen
    //
    // One provider per wire the plan serves, each signing with `apiKey` as a
    // bearer token, the way the gateway reads a key on every wire (Gemini's
    // `?key=` query parameter is not read), and each wrapped in
    // `OpenCodeRequestProvider`. The Responses route stays on HTTP/SSE.
    public static func openCodeProviders(
        plan: OpenCodePlan,
        apiKey: String?,
        client: HTTPClient = URLSessionHTTPClient()
    ) -> [any APIProvider] {
        let bearer: @Sendable (String) -> [String: String] = { key in
            ["Authorization": bearerHeaderValue(key)]
        }
        let wires: [any APIProvider] = [
            OpenAICompletionsProvider(client: client, defaultAPIKey: apiKey, authHeaderBuilder: bearer),
            OpenAIResponsesProvider(
                client: client,
                webSocketClient: nil,
                defaultAPIKey: apiKey,
                authHeaderBuilder: bearer
            ),
            AnthropicProvider(client: client, defaultAPIKey: apiKey, authHeaderBuilder: bearer),
            GoogleGeminiProvider(client: client, defaultAPIKey: apiKey, authHeaderBuilder: bearer),
        ]
        return wires.map { OpenCodeRequestProvider(base: $0, plan: plan) }
    }
}

/// Sends a request to its wire's path on an OpenCode plan and names its
/// conversation in `x-opencode-session`, after `CopilotRequestHeadersProvider`.
/// The plan decides the address: whatever `baseURL` a model carries (the
/// catalog's, a session template's) is replaced by the plan's base for this
/// wire. The header is the request's session id; a request with no session
/// (a title, a key check) gets one id for the whole process, since the
/// gateway wants one on every request. A header the caller set itself is
/// kept. Session cleanup and native compaction pass straight through, routed
/// and stamped the same way (no catalog model opts in to native compaction,
/// and the gateway has no `/responses/compact`, so compaction is kwwk's own
/// summary today).
struct OpenCodeRequestProvider: APIProvider, APIProviderSessionLifecycle, NativeCompactionProvider {
    static let sessionHeader = "x-opencode-session"
    static let processSession = UUID().uuidString.lowercased()

    let base: any APIProvider
    let plan: OpenCodePlan

    var api: String { base.api }

    func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        base.stream(model: routed(model), context: context, options: stamped(options))
    }

    func closeSession(sessionId: String) async {
        await (base as? any APIProviderSessionLifecycle)?.closeSession(sessionId: sessionId)
    }

    func compact(
        model: Model,
        context: Context,
        instructions: String,
        options: StreamOptions?
    ) async throws -> NativeCompactionResult? {
        guard let native = base as? any NativeCompactionProvider else { return nil }
        return try await native.compact(
            model: routed(model),
            context: context,
            instructions: instructions,
            options: stamped(options)
        )
    }

    private func routed(_ model: Model) -> Model {
        var routed = model
        routed.baseURL = plan.baseURL(for: api)
        return routed
    }

    private func stamped(_ options: StreamOptions?) -> StreamOptions {
        var stamped = options ?? StreamOptions()
        var headers = stamped.headers ?? [:]
        if !headers.keys.contains(where: { $0.lowercased() == Self.sessionHeader }) {
            let session = stamped.sessionId.flatMap { $0.isEmpty ? nil : $0 }
            headers[Self.sessionHeader] = session ?? Self.processSession
        }
        stamped.headers = headers
        return stamped
    }
}

/// Register every wire of `plan` on `APIRegistry.shared` under the plan's
/// scope and return the session's model: `modelOverride`, else
/// `defaultModel` (a login's optional default), else the plan's. A catalog
/// entry keeps its wire and capabilities; an id the catalog does not carry
/// rides Chat Completions as a plain text model. The model's `baseURL` is the
/// plan's root, the same for every model, so a `/model` pick that keeps the
/// session template's address still routes (`OpenCodeRequestProvider`).
public func registerOpenCode(
    plan: OpenCodePlan,
    apiKey: String,
    modelOverride: String? = nil,
    defaultModel: String? = nil
) async -> ResolvedAuth {
    for provider in ProviderVariants.openCodeProviders(plan: plan, apiKey: apiKey) {
        await APIRegistry.shared.register(provider, scope: plan.id)
    }
    let modelId = modelOverride ?? defaultModel.flatMap { $0.isEmpty ? nil : $0 } ?? plan.defaultModel
    let catalog = ModelsCatalog.model(provider: plan.id, id: modelId)
    let api = catalog.map(\.api).flatMap { OpenCodePlan.wires.contains($0) ? $0 : nil }
        ?? "openai-completions"
    // What the catalog's Chat Completions entries share, so an uncatalogued
    // id is asked the way the gateway's own models are.
    let fallbackCompat: ModelCompat = {
        var c = ModelCompat()
        c.maxTokensField = "max_tokens"
        c.supportsDeveloperRole = false
        c.supportsStore = false
        c.supportsStrictMode = true
        return c
    }()
    let model = Model(
        id: modelId,
        name: catalog?.name ?? modelId,
        api: api,
        provider: plan.id,
        baseURL: plan.rootURL,
        reasoning: catalog?.reasoning ?? false,
        input: catalog?.input ?? [.text],
        cost: catalog?.cost ?? ModelCost(),
        contextWindow: catalog?.contextWindow ?? 131_072,
        maxTokens: catalog?.maxTokens ?? 32_000,
        headers: catalog?.headers,
        compat: catalog?.compat ?? fallbackCompat,
        thinkingLevelMap: catalog?.thinkingLevelMap
    )
    return ResolvedAuth(
        model: model,
        modelLabel: "\(modelId) · \(plan.name)",
        authResolver: nil
    )
}
