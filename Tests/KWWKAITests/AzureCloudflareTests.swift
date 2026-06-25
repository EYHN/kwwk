import Foundation
import Testing
@testable import KWWKAI

@Suite("Azure + Cloudflare wiring")
struct AzureCloudflareTests {

    static let openaiCompletionsSSE = """
    data: {"id":"c","choices":[{"index":0,"delta":{"content":"hi"}}]}

    data: {"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

    data: [DONE]

    """

    static let openaiResponsesSSE = """
    data: {"type":"response.created","response":{"id":"r","status":"in_progress"}}

    data: {"type":"response.completed","response":{"id":"r","status":"completed","usage":{"input_tokens":1,"output_tokens":1}}}

    """

    // MARK: - Placeholder substitution

    @Test("Substitutes both Cloudflare placeholders from a value source")
    func substituteBoth() {
        let base = "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/compat"
        let out = substituteCloudflarePlaceholders(in: base) { key in
            ["CLOUDFLARE_ACCOUNT_ID": "acct123", "CLOUDFLARE_GATEWAY_ID": "gw456"][key]
        }
        #expect(out == "https://gateway.ai.cloudflare.com/v1/acct123/gw456/compat")
    }

    @Test("Substitutes only the account placeholder for Workers AI base")
    func substituteAccountOnly() {
        let base = "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1"
        let out = substituteCloudflarePlaceholders(in: base) { key in
            key == "CLOUDFLARE_ACCOUNT_ID" ? "acctZ" : nil
        }
        #expect(out == "https://api.cloudflare.com/client/v4/accounts/acctZ/ai/v1")
    }

    @Test("Missing values collapse to empty string (pi parity)")
    func substituteMissing() {
        let base = "https://x/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/y"
        let out = substituteCloudflarePlaceholders(in: base) { _ in nil }
        #expect(out == "https://x///y")
    }

    @Test("Leaves non-Cloudflare base URLs untouched")
    func substituteNoop() {
        let base = "https://api.openai.com"
        let out = substituteCloudflarePlaceholders(in: base) { _ in "should-not-be-used" }
        #expect(out == base)
    }

    // MARK: - Azure env resolution

    @Test("Azure resolves from explicit base URL + key")
    func azureFromBaseURL() {
        let env = [
            "AZURE_OPENAI_API_KEY": "az-key",
            "AZURE_OPENAI_BASE_URL": "https://contoso.openai.azure.com",
        ]
        let azure = EnvAPIKeys.azure(env: env)
        #expect(azure?.apiKey == "az-key")
        #expect(azure?.baseURL == "https://contoso.openai.azure.com/openai/v1")
        #expect(azure?.apiVersion == EnvAPIKeys.azureDefaultAPIVersion)
    }

    @Test("Azure resolves base URL from resource name")
    func azureFromResource() {
        let env = [
            "AZURE_OPENAI_API_KEY": "k",
            "AZURE_OPENAI_RESOURCE_NAME": "myres",
            "AZURE_OPENAI_API_VERSION": "2024-10-01-preview",
        ]
        let azure = EnvAPIKeys.azure(env: env)
        #expect(azure?.baseURL == "https://myres.openai.azure.com/openai/v1")
        #expect(azure?.apiVersion == "2024-10-01-preview")
    }

    @Test("Azure returns nil without an API key")
    func azureNoKey() {
        #expect(EnvAPIKeys.azure(env: ["AZURE_OPENAI_BASE_URL": "https://x"]) == nil)
    }

    @Test("Azure returns nil with key but no endpoint")
    func azureNoEndpoint() {
        #expect(EnvAPIKeys.azure(env: ["AZURE_OPENAI_API_KEY": "k"]) == nil)
    }

    @Test("normalizeAzureBaseURL idempotent on /openai/v1 suffix")
    func azureNormalizeIdempotent() {
        #expect(EnvAPIKeys.normalizeAzureBaseURL("https://x.openai.azure.com/openai/v1/")
            == "https://x.openai.azure.com/openai/v1")
        #expect(EnvAPIKeys.normalizeAzureBaseURL("https://x.openai.azure.com/openai")
            == "https://x.openai.azure.com/openai/v1")
    }

    // MARK: - Cloudflare env resolution

    @Test("Cloudflare resolves key + account + gateway ids")
    func cloudflareFull() {
        let env = [
            "CLOUDFLARE_API_KEY": "cf-key",
            "CLOUDFLARE_ACCOUNT_ID": "acct",
            "CLOUDFLARE_GATEWAY_ID": "gw",
        ]
        let cf = EnvAPIKeys.cloudflare(env: env)
        #expect(cf?.apiKey == "cf-key")
        #expect(cf?.accountId == "acct")
        #expect(cf?.gatewayId == "gw")
    }

    @Test("Cloudflare returns nil without an API key")
    func cloudflareNoKey() {
        #expect(EnvAPIKeys.cloudflare(env: ["CLOUDFLARE_ACCOUNT_ID": "acct"]) == nil)
    }

    // MARK: - Provider variants

    @Test("Azure v1 variant builds /openai/v1/responses with api-version + api-key header")
    func azureV1URL() async throws {
        let client = StubSSEClient(body: Self.openaiResponsesSSE)
        let provider = ProviderVariants.azureOpenAIResponsesV1(
            endpoint: URL(string: "https://contoso.openai.azure.com/openai/v1")!,
            apiVersion: "v1",
            apiKey: "az-key",
            client: client
        )
        let model = Model(id: "gpt-5", name: "gpt-5", api: "azure-openai-responses", provider: "azure-openai-responses")
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(transport: .sse)
        )
        try? await Task.sleep(nanoseconds: 30_000_000)
        let u = client.lastRequest?.url.absoluteString ?? ""
        #expect(u == "https://contoso.openai.azure.com/openai/v1/responses?api-version=v1")
        #expect(client.lastRequest?.headers["api-key"] == "az-key")
        #expect(client.lastRequest?.headers["authorization"] == nil)
        #expect(client.lastRequest?.headers["Authorization"] == nil)
    }

    @Test("Cloudflare AI Gateway variant uses cf-aig-authorization, not Authorization")
    func cloudflareGatewayHeader() async throws {
        let client = StubSSEClient(body: Self.openaiCompletionsSSE)
        let provider = ProviderVariants.cloudflareAIGateway(apiKey: "cf-key", client: client)
        let model = Model(
            id: "gpt-4o-mini",
            name: "gpt-4o-mini",
            api: "cloudflare-ai-gateway",
            provider: "cloudflare-ai-gateway",
            baseUrl: "https://gateway.ai.cloudflare.com/v1/acct/gw/compat"
        )
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(transport: .sse)
        )
        try? await Task.sleep(nanoseconds: 30_000_000)
        let headers = client.lastRequest?.headers ?? [:]
        #expect(headers["cf-aig-authorization"] == "Bearer cf-key")
        #expect(headers["Authorization"] == nil)
        #expect(headers["authorization"] == nil)
    }

    @Test("Workers AI variant substitutes account id placeholder into request URL")
    func workersAIURLSubstitution() async throws {
        let client = StubSSEClient(body: Self.openaiCompletionsSSE)
        let provider = ProviderVariants.cloudflareWorkersAI(apiKey: "cf-key", client: client)
        // model.baseUrl carries the literal placeholder; urlBuilder must expand it.
        let model = Model(
            id: "@cf/x/y",
            name: "y",
            api: "cloudflare-workers-ai",
            provider: "cloudflare-workers-ai",
            baseUrl: "https://api.cloudflare.com/client/v4/accounts/acctABC/ai/v1"
        )
        _ = provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(transport: .sse)
        )
        try? await Task.sleep(nanoseconds: 30_000_000)
        let u = client.lastRequest?.url.absoluteString ?? ""
        #expect(u == "https://api.cloudflare.com/client/v4/accounts/acctABC/ai/v1/chat/completions")
        #expect(client.lastRequest?.headers["Authorization"] == "Bearer cf-key")
    }
}
