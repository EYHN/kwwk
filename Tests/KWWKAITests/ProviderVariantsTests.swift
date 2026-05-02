import Foundation
import Testing
@testable import KWWKAI

@Suite("Provider variants")
struct ProviderVariantsTests {

    static let anthropicSSE = """
    event: message_start
    data: {"type":"message_start","message":{"id":"m","role":"assistant","content":[],"model":"m","usage":{"input_tokens":1,"output_tokens":0}}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    static let openaiResponsesSSE = """
    data: {"type":"response.created","response":{"id":"r","status":"in_progress"}}

    data: {"type":"response.completed","response":{"id":"r","status":"completed","usage":{"input_tokens":1,"output_tokens":1}}}

    """

    // MARK: - Azure OpenAI Responses

    @Test("Azure builds deployment-scoped URL with api-version")
    func azureURL() async throws {
        let client = StubSSEClient(body: Self.openaiResponsesSSE)
        let provider = ProviderVariants.azureOpenAIResponses(
            endpoint: URL(string: "https://contoso.openai.azure.com/")!,
            apiVersion: "2024-10-01-preview",
            apiKey: "az-key",
            client: client
        )
        let model = Model(id: "gpt-5", name: "gpt-5", api: "azure-openai-responses", provider: "azure")
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(transport: .sse)
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let u = client.lastRequest?.url.absoluteString ?? ""
        #expect(u.contains("/openai/deployments/gpt-5/responses"))
        #expect(u.contains("api-version=2024-10-01-preview"))
        #expect(client.lastRequest?.headers["api-key"] == "az-key")
        #expect(client.lastRequest?.headers["authorization"] == nil)
    }

    @Test("Azure honors per-request deployment override via metadata")
    func azureDeploymentOverride() async throws {
        let client = StubSSEClient(body: Self.openaiResponsesSSE)
        let provider = ProviderVariants.azureOpenAIResponses(
            endpoint: URL(string: "https://contoso.openai.azure.com")!,
            apiVersion: "v1",
            apiKey: "k",
            client: client
        )
        let model = Model(id: "gpt-4o", name: "gpt-4o", api: "azure-openai-responses", provider: "azure")
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(transport: .sse, metadata: ["deployment": .string("gpt4o-prod")])
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let u = client.lastRequest?.url.absoluteString ?? ""
        #expect(u.contains("/deployments/gpt4o-prod/responses"))
    }

    // MARK: - Anthropic OAuth

    @Test("Anthropic OAuth sends Bearer + anthropic-beta")
    func anthropicOAuth() async throws {
        let client = StubSSEClient(body: Self.anthropicSSE)
        let provider = ProviderVariants.anthropicOAuth(accessToken: "oauth-abc", client: client)
        let model = Model(
            id: "claude-sonnet-4-5",
            name: "claude",
            api: "anthropic-messages",
            provider: "anthropic",
            baseUrl: "https://api.anthropic.com"
        )
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let h = client.lastRequest?.headers ?? [:]
        #expect(h["authorization"] == "Bearer oauth-abc")
        #expect(h["anthropic-beta"] == "oauth-2025-04-20")
        #expect(h["x-api-key"] == nil)
    }

    // MARK: - Vertex AI

    @Test("Vertex builds project-scoped URL and uses Bearer auth")
    func vertexURL() async throws {
        let geminiSSE = """
        data: {"candidates":[{"content":{"role":"model","parts":[{"text":"hi"}]},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1,"totalTokenCount":2}}

        """
        let client = StubSSEClient(body: geminiSSE)
        let provider = ProviderVariants.vertexAI(
            project: "my-project",
            location: "us-central1",
            accessToken: "oauth-token",
            client: client
        )
        let model = Model(id: "gemini-2.5-flash", name: "m", api: "google-vertex", provider: "google-vertex")
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let u = client.lastRequest?.url.absoluteString ?? ""
        #expect(u.contains("us-central1-aiplatform.googleapis.com"))
        #expect(u.contains("/projects/my-project/locations/us-central1/publishers/google/models/gemini-2.5-flash"))
        #expect(u.contains("streamGenerateContent"))
        #expect(!u.contains("key="))
        #expect(client.lastRequest?.headers["authorization"] == "Bearer oauth-token")
    }

    // MARK: - GitHub Copilot

    @Test("Copilot sets X-Initiator based on last message role")
    func copilotInitiator() async throws {
        let sse = OpenAICompletionsTests.textSSE
        let client = StubSSEClient(body: sse)
        let provider = ProviderVariants.githubCopilot(sessionToken: "ghu_xxx", client: client)
        let model = Model(
            id: "claude-sonnet-4",
            name: "claude",
            api: "github-copilot-chat",
            provider: "github-copilot",
            baseUrl: "https://api.githubcopilot.com"
        )

        // Agent flow: last message is tool result → x-initiator=agent.
        _ = provider.stream(
            model: model,
            context: Context(messages: [
                .user(UserMessage(text: "hi")),
                .toolResult(ToolResultMessage(
                    toolCallId: "t", toolName: "noop",
                    content: [.text(TextContent(text: "ok"))]
                )),
            ]),
            options: nil
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let h1 = client.lastRequest?.headers ?? [:]
        #expect(h1["x-initiator"] == "agent")
        #expect(h1["openai-intent"] == "conversation-edits")
        #expect(h1["authorization"] == "Bearer ghu_xxx")

        // User flow: last is user message → x-initiator=user.
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(client.lastRequest?.headers["x-initiator"] == "user")
    }

    @Test("Copilot stamps copilot-vision-request when images are present")
    func copilotVision() async throws {
        let client = StubSSEClient(body: OpenAICompletionsTests.textSSE)
        let provider = ProviderVariants.githubCopilot(sessionToken: "ghu", client: client)
        let model = Model(
            id: "gpt-4o",
            name: "m",
            api: "github-copilot-chat",
            provider: "github-copilot",
            baseUrl: "https://api.githubcopilot.com"
        )
        _ = provider.stream(
            model: model,
            context: Context(messages: [
                .user(UserMessage(content: [
                    .text(TextContent(text: "what is this")),
                    .image(ImageContent(data: "abcd", mimeType: "image/png")),
                ]))
            ]),
            options: nil
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(client.lastRequest?.headers["copilot-vision-request"] == "true")
    }

    // MARK: - ChatGPT Codex

    @Test("ChatGPT Codex routes to backend-api/codex/responses with account header")
    func codexURL() async throws {
        let client = StubSSEClient(body: Self.openaiResponsesSSE)
        let provider = ProviderVariants.chatgptCodex(
            accessToken: "codex-bearer",
            accountId: "acct-xyz",
            client: client
        )
        let model = Model(id: "gpt-5-codex", name: "gpt-5-codex", api: "chatgpt-codex", provider: "chatgpt-codex")
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(transport: .sse)
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let u = client.lastRequest?.url.absoluteString ?? ""
        #expect(u == "https://chatgpt.com/backend-api/codex/responses")
        #expect(client.lastRequest?.headers["authorization"] == "Bearer codex-bearer")
        #expect(client.lastRequest?.headers["chatgpt-account-id"] == "acct-xyz")
        #expect(client.lastRequest?.headers["openai-beta"] == "responses=experimental")
    }

    @Test("ChatGPT Codex defaults to WebSocket and uses WebSocket beta")
    func codexWebSocketDefault() async throws {
        let http = StubSSEClient(body: Self.openaiResponsesSSE)
        let connection = StubWebSocketConnection(batches: [Self.webSocketMessages(from: Self.openaiResponsesSSE)])
        let ws = StubWebSocketClient(connection: connection)
        let provider = ProviderVariants.chatgptCodex(
            accessToken: "codex-bearer",
            accountId: "acct-xyz",
            client: http,
            webSocketClient: ws
        )
        let model = Model(id: "gpt-5-codex", name: "gpt-5-codex", api: "chatgpt-codex", provider: "chatgpt-codex")

        let s = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(sessionId: "codex-ws")
        )
        for await _ in s {}

        #expect(await s.result().responseId == "r")
        #expect(http.lastRequest == nil)
        #expect(ws.lastURL?.absoluteString == "wss://chatgpt.com/backend-api/codex/responses")
        #expect(ws.lastHeaders["authorization"] == "Bearer codex-bearer")
        #expect(ws.lastHeaders["chatgpt-account-id"] == "acct-xyz")
        #expect(ws.lastHeaders["openai-beta"] == "responses_websockets=2026-02-06")

        let payload = try Self.jsonObject(connection.sentTexts[0])
        #expect(payload["type"] as? String == "response.create")
        #expect(payload["store"] as? Bool == false)
    }

    private static func webSocketMessages(from sse: String) -> [String] {
        sse.components(separatedBy: "\n\n").compactMap { block in
            let dataLines = block.split(separator: "\n").compactMap { line -> String? in
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.hasPrefix("data:") else { return nil }
                return String(text.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            }
            return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
        }
    }

    private static func jsonObject(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
