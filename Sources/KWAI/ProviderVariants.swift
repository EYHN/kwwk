import Foundation

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
        client: HTTPClient = URLSessionHTTPClient()
    ) -> OpenAIResponsesProvider {
        let endpointString = endpoint.absoluteString.trimmedSlashes
        return OpenAIResponsesProvider(
            api: "azure-openai-responses",
            client: client,
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
            authHeaderBuilder: { token in ["authorization": "Bearer \(token)"] }
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
        integrationID: String = "kw"
    ) -> OpenAICompletionsProvider {
        OpenAICompletionsProvider(
            api: "github-copilot-chat",
            client: client,
            defaultBaseURL: URL(string: "https://api.githubcopilot.com")!,
            defaultAPIKey: sessionToken,
            extraHeaders: [
                "editor-version": "kw/1.0",
                "copilot-integration-id": integrationID,
            ],
            urlBuilder: { _, _, fallback in
                URL(string: "https://api.githubcopilot.com/chat/completions") ?? fallback
            },
            authHeaderBuilder: { key in ["authorization": "Bearer \(key)"] },
            headersDecorator: { headers, _, context, _ in
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
        )
    }
}

private extension String {
    var trimmedSlashes: String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
