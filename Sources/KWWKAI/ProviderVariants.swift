import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thin wrappers over the four base providers that handle vendor-specific
/// URL / authentication / header differences. Each returns a ready-to-register
/// provider that speaks the same wire format as its base.
public enum ProviderVariants {

    // MARK: - Azure OpenAI Responses
    //
    // Azure hosts the standard OpenAI Responses API but under a deployment-
    // scoped URL shape:
    //
    //   POST {endpoint}/openai/deployments/{deployment}/responses?api-version=…
    //   api-key: {key}
    //
    // The deployment name usually matches the model id; callers can override
    // with `azureDeploymentName` via `StreamOptions.metadata["deployment"]`.
    public static func azureOpenAIResponses(
        endpoint: URL,
        apiVersion: String = "2024-10-01-preview",
        apiKey: String? = nil,
        client: HTTPClient = URLSessionHTTPClient(),
        webSocketClient: WebSocketClient? = URLSessionWebSocketClient()
    ) -> OpenAIResponsesProvider {
        let endpointString = endpoint.absoluteString.trimmedSlashes
        return OpenAIResponsesProvider(
            api: "azure-openai-responses",
            client: client,
            webSocketClient: webSocketClient,
            defaultBaseURL: endpoint,
            defaultAPIKey: apiKey,
            urlBuilder: { model, options, _ in
                let deployment: String = {
                    if let meta = options?.metadata,
                       case .string(let v) = meta["deployment"] ?? .null { return v }
                    return model.id
                }()
                let urlString = "\(endpointString)/openai/deployments/\(deployment)/responses?api-version=\(apiVersion)"
                return URL(string: urlString) ?? endpoint
            },
            authHeaderBuilder: { key in ["api-key": key] }
        )
    }

    // MARK: - Anthropic OAuth
    //
    // Anthropic's OAuth tokens (used by Claude Code) ride on a Bearer header
    // plus the `anthropic-beta: oauth-2025-04-20` opt-in. Wire format is the
    // same Messages API.
    //
    // Subscription-token requests must also identify as Claude Code via the
    // system prompt; otherwise the endpoint returns `rate_limit_error` up
    // front regardless of remaining quota.
    public static func anthropicOAuth(
        accessToken: String? = nil,
        client: HTTPClient = URLSessionHTTPClient(),
        apiVersion: String = "2023-06-01",
        beta: String = "oauth-2025-04-20"
    ) -> AnthropicProvider {
        AnthropicProvider(
            api: "anthropic-messages",
            client: client,
            defaultBaseURL: URL(string: "https://api.anthropic.com")!,
            defaultAPIKey: accessToken,
            apiVersion: apiVersion,
            extraHeaders: ["anthropic-beta": beta],
            authHeaderBuilder: { token in ["authorization": "Bearer \(token)"] },
            systemPromptPrefix: "You are Claude Code, Anthropic's official CLI for Claude."
        )
    }

    // MARK: - Google Vertex AI (Gemini)
    //
    // Vertex serves Gemini under `/v1/projects/{project}/locations/{location}/
    // publishers/google/models/{model}:streamGenerateContent` with a Bearer
    // OAuth token.
    public static func vertexAI(
        project: String,
        location: String = "us-central1",
        accessToken: String? = nil,
        client: HTTPClient = URLSessionHTTPClient()
    ) -> GoogleGeminiProvider {
        let host = "https://\(location)-aiplatform.googleapis.com"
        return GoogleGeminiProvider(
            api: "google-vertex",
            client: client,
            defaultBaseURL: URL(string: host)!,
            defaultAPIKey: accessToken,
            urlBuilder: { model, _, _, _ in
                let urlString = "\(host)/v1/projects/\(project)/locations/\(location)" +
                    "/publishers/google/models/\(model.id):streamGenerateContent?alt=sse"
                return URL(string: urlString) ?? URL(string: host)!
            },
            authHeaderBuilder: { token in ["authorization": "Bearer \(token)"] }
        )
    }

    // MARK: - ChatGPT Codex (Responses route under chatgpt.com)
    //
    // The ChatGPT subscription Codex backend exposes the OpenAI Responses API
    // at `https://chatgpt.com/backend-api/codex/responses`. The auth model:
    //
    //   authorization: Bearer <access_token>        ← JWT from ~/.codex/auth.json
    //   chatgpt-account-id: <account_id>            ← JWT claim, also in auth.json
    //   openai-beta: responses=experimental
    //
    // `accessToken` should be fresh. Callers typically pair this with
    // `OpenAICodexOAuthProvider.refresh(...)` via `OAuthManager` to get
    // auto-refresh.
    public static func chatgptCodex(
        accessToken: String? = nil,
        accountId: String? = nil,
        client: HTTPClient = URLSessionHTTPClient(),
        webSocketClient: WebSocketClient? = URLSessionWebSocketClient(),
        originator: String = "kw-cli"
    ) -> OpenAIResponsesProvider {
        var extra: [String: String] = [
            "openai-beta": "responses=experimental",
            "originator": originator,
        ]
        if let accountId {
            extra["chatgpt-account-id"] = accountId
        }
        return OpenAIResponsesProvider(
            api: "chatgpt-codex",
            client: client,
            webSocketClient: webSocketClient,
            defaultBaseURL: URL(string: "https://chatgpt.com")!,
            defaultAPIKey: accessToken,
            extraHeaders: extra,
            // Codex requires stateless inference: the endpoint rejects
            // requests with `store: true` (the Responses API default).
            bodyOverrides: ["store": .bool(false)],
            urlBuilder: { _, _, _ in
                URL(string: "https://chatgpt.com/backend-api/codex/responses")!
            },
            authHeaderBuilder: { token in ["authorization": "Bearer \(token)"] }
        )
    }

    // MARK: - GitHub Copilot (Chat Completions route)
    //
    // Copilot proxies a chat/completions endpoint at
    // `https://api.githubcopilot.com/chat/completions`. Each request must
    // include X-Initiator, Openai-Intent, and, when images are present,
    // Copilot-Vision-Request. Token is a short-lived session token fetched
    // via the device-flow auth SDK — we take it pre-resolved.
    public static func githubCopilot(
        sessionToken: String? = nil,
        client: HTTPClient = URLSessionHTTPClient(),
        integrationID: String = "vscode-chat",
        api: String = "openai-completions",
        baseURL: URL = URL(string: "https://api.githubcopilot.com")!
    ) -> OpenAICompletionsProvider {
        let baseString = baseURL.absoluteString.trimmedSlashes
        return OpenAICompletionsProvider(
            api: api,
            client: client,
            defaultBaseURL: baseURL,
            defaultAPIKey: sessionToken,
            extraHeaders: copilotEditorHeaders(integrationID: integrationID),
            urlBuilder: { _, _, fallback in
                URL(string: "\(baseString)/chat/completions") ?? fallback
            },
            authHeaderBuilder: { key in ["authorization": "Bearer \(key)"] },
            headersDecorator: copilotDynamicHeadersDecorator()
        )
    }

    // MARK: - GitHub Copilot (Anthropic Messages route)
    //
    // Claude-on-Copilot. Copilot proxies Claude's Messages API at the same
    // host (`/v1/messages`) with Bearer session-token auth and the standard
    // editor headers. No `anthropic-beta` opt-in; no per-request dynamic
    // headers (pi doesn't stamp `X-Initiator` on this route).
    public static func githubCopilotAnthropic(
        sessionToken: String? = nil,
        client: HTTPClient = URLSessionHTTPClient(),
        integrationID: String = "vscode-chat",
        api: String = "anthropic-messages",
        baseURL: URL = URL(string: "https://api.individual.githubcopilot.com")!
    ) -> AnthropicProvider {
        // AnthropicProvider's default urlBuilder reads `model.baseUrl`,
        // which the Copilot catalog pins to `api.individual.githubcopilot.com`
        // — that would bypass the session's enterprise/business proxy
        // endpoint. We can't inject a urlBuilder on AnthropicProvider, so
        // `defaultBaseURL` is the fallback when `model.baseUrl.isEmpty`.
        // Callers who need enterprise routing should normalize
        // `model.baseUrl` via `adoptFields` on `/model` switches, which
        // keeps the session baseUrl across catalog swaps.
        AnthropicProvider(
            api: api,
            client: client,
            defaultBaseURL: baseURL,
            defaultAPIKey: sessionToken,
            extraHeaders: copilotEditorHeaders(integrationID: integrationID),
            authHeaderBuilder: { key in ["authorization": "Bearer \(key)"] }
        )
    }

    // MARK: - GitHub Copilot (OpenAI Responses route)
    //
    // GPT-5 family runs on the Responses wire over Copilot's proxy. Same
    // auth + editor headers as the completions/anthropic variants. The
    // default Responses URL (`{base}/v1/responses`) matches what Copilot
    // accepts.
    public static func githubCopilotResponses(
        sessionToken: String? = nil,
        client: HTTPClient = URLSessionHTTPClient(),
        webSocketClient: WebSocketClient? = URLSessionWebSocketClient(),
        integrationID: String = "vscode-chat",
        api: String = "openai-responses",
        baseURL: URL = URL(string: "https://api.individual.githubcopilot.com")!
    ) -> OpenAIResponsesProvider {
        let baseString = baseURL.absoluteString.trimmedSlashes
        return OpenAIResponsesProvider(
            api: api,
            client: client,
            webSocketClient: webSocketClient,
            defaultBaseURL: baseURL,
            defaultAPIKey: sessionToken,
            extraHeaders: copilotEditorHeaders(integrationID: integrationID),
            // Pin the URL to the session's Copilot endpoint. Catalog
            // Copilot-GPT-5 entries hardcode
            // `api.individual.githubcopilot.com`; without pinning, a
            // Business/Enterprise account loses its proxy host.
            urlBuilder: { _, _, _ in
                URL(string: "\(baseString)/responses")
                    ?? URL(string: "https://api.individual.githubcopilot.com/responses")!
            },
            authHeaderBuilder: { key in ["authorization": "Bearer \(key)"] }
        )
    }

    // MARK: - Shared helpers

    private static func copilotEditorHeaders(integrationID: String) -> [String: String] {
        [
            "editor-version": "vscode/1.107.0",
            "editor-plugin-version": "copilot-chat/0.35.0",
            "user-agent": "GitHubCopilotChat/0.35.0",
            "copilot-integration-id": integrationID,
        ]
    }

    private static func copilotDynamicHeadersDecorator() -> (
        @Sendable (inout [String: String], Model, Context, StreamOptions?) -> Void
    ) {
        return { headers, _, context, _ in
            let hasImages = context.messages.contains { msg in
                if case .user(let u) = msg {
                    return u.content.contains { if case .image = $0 { return true } else { return false } }
                }
                if case .toolResult(let t) = msg {
                    return t.content.contains { if case .image = $0 { return true } else { return false } }
                }
                return false
            }
            let lastIsUser: Bool = {
                guard let last = context.messages.last else { return true }
                if case .user = last { return true } else { return false }
            }()
            headers["x-initiator"] = lastIsUser ? "user" : "agent"
            headers["openai-intent"] = "conversation-edits"
            if hasImages { headers["copilot-vision-request"] = "true" }
        }
    }
}

private extension String {
    var trimmedSlashes: String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
