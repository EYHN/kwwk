import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAI

@Suite("Bedrock region derivation")
struct BedrockRegionTests {

    @Test("extracts region from an inference-profile ARN")
    func arnRegion() {
        #expect(BedrockRegion.fromARN(
            "arn:aws:bedrock:eu-west-1:123456789012:inference-profile/anthropic.claude-sonnet-4"
        ) == "eu-west-1")
        #expect(BedrockRegion.fromARN(
            "arn:aws:bedrock:ap-southeast-2:1:foundation-model/x"
        ) == "ap-southeast-2")
        // Partition-qualified (GovCloud).
        #expect(BedrockRegion.fromARN(
            "arn:aws-us-gov:bedrock:us-gov-west-1:1:inference-profile/x"
        ) == "us-gov-west-1")
    }

    @Test("returns nil for non-ARN / non-bedrock ids")
    func arnRegionNil() {
        #expect(BedrockRegion.fromARN("anthropic.claude-sonnet-4-20250514-v1:0") == nil)
        #expect(BedrockRegion.fromARN("arn:aws:s3:::bucket") == nil)
        #expect(BedrockRegion.fromARN("arn:aws:bedrock::1:x") == nil)
    }

    @Test("extracts region from a standard bedrock-runtime endpoint host")
    func endpointRegion() {
        #expect(BedrockRegion.fromEndpointHost(
            "https://bedrock-runtime.eu-central-1.amazonaws.com"
        ) == "eu-central-1")
        #expect(BedrockRegion.fromEndpointHost(
            "https://bedrock-runtime-fips.us-east-2.amazonaws.com/model/x"
        ) == "us-east-2")
        #expect(BedrockRegion.fromEndpointHost(
            "https://bedrock-runtime.cn-north-1.amazonaws.com.cn"
        ) == "cn-north-1")
        // Bare host without scheme.
        #expect(BedrockRegion.fromEndpointHost(
            "bedrock-runtime.ap-northeast-1.amazonaws.com"
        ) == "ap-northeast-1")
    }

    @Test("returns nil for custom / VPC / proxy endpoints")
    func endpointRegionNil() {
        #expect(BedrockRegion.fromEndpointHost("https://my-proxy.internal:8443") == nil)
        #expect(BedrockRegion.fromEndpointHost("https://bedrock.example.com") == nil)
        #expect(BedrockRegion.fromEndpointHost(nil) == nil)
        #expect(BedrockRegion.fromEndpointHost("") == nil)
    }

    @Test("resolution order: ARN > endpoint host > env > fallback")
    func resolutionOrder() {
        // ARN wins over everything.
        #expect(BedrockRegion.resolve(
            modelId: "arn:aws:bedrock:eu-west-3:1:inference-profile/x",
            baseUrl: "https://bedrock-runtime.us-east-1.amazonaws.com",
            env: ["AWS_REGION": "us-west-2"],
            fallback: "us-east-1"
        ) == "eu-west-3")

        // Endpoint host wins over env when no ARN.
        #expect(BedrockRegion.resolve(
            modelId: "anthropic.claude",
            baseUrl: "https://bedrock-runtime.ap-south-1.amazonaws.com",
            env: ["AWS_REGION": "us-west-2"],
            fallback: "us-east-1"
        ) == "ap-south-1")

        // Env wins when no ARN / standard host.
        #expect(BedrockRegion.resolve(
            modelId: "anthropic.claude",
            baseUrl: "https://proxy.internal",
            env: ["AWS_DEFAULT_REGION": "sa-east-1"],
            fallback: "us-east-1"
        ) == "sa-east-1")

        // Fallback when nothing pins a region.
        #expect(BedrockRegion.resolve(
            modelId: "anthropic.claude",
            baseUrl: nil,
            env: [:],
            fallback: "us-east-1"
        ) == "us-east-1")
    }
}

@Suite("Bedrock credentials resolution")
struct BedrockCredentialsTests {

    @Test("reads static IAM keys from env, including session token")
    func envKeys() {
        let creds = BedrockCredentials.fromEnv([
            "AWS_ACCESS_KEY_ID": "AKID",
            "AWS_SECRET_ACCESS_KEY": "SECRET",
            "AWS_SESSION_TOKEN": "TOKEN",
        ])
        #expect(creds?.accessKeyId == "AKID")
        #expect(creds?.secretAccessKey == "SECRET")
        #expect(creds?.sessionToken == "TOKEN")
    }

    @Test("returns nil when keys are missing or empty")
    func envKeysMissing() {
        #expect(BedrockCredentials.fromEnv([:]) == nil)
        #expect(BedrockCredentials.fromEnv(["AWS_ACCESS_KEY_ID": ""]) == nil)
        #expect(BedrockCredentials.fromEnv(["AWS_ACCESS_KEY_ID": "k"]) == nil)
    }

    @Test("parses the named profile from a shared credentials file")
    func profileParsing() {
        let ini = """
        [default]
        aws_access_key_id = DEFAULTKEY
        aws_secret_access_key = DEFAULTSECRET

        [work]
        aws_access_key_id = WORKKEY
        aws_secret_access_key = WORKSECRET
        aws_session_token = WORKTOKEN
        """
        let def = BedrockCredentials.iniSection(named: "default", in: ini)
        #expect(def?["aws_access_key_id"] == "DEFAULTKEY")
        let work = BedrockCredentials.iniSection(named: "work", in: ini)
        #expect(work?["aws_secret_access_key"] == "WORKSECRET")
        #expect(work?["aws_session_token"] == "WORKTOKEN")
        #expect(BedrockCredentials.iniSection(named: "missing", in: ini) == nil)
    }

    @Test("handles `[profile name]` headers used in ~/.aws/config")
    func profileHeaderForm() {
        let ini = """
        [profile staging]
        aws_access_key_id = STAGEKEY
        aws_secret_access_key = STAGESECRET
        """
        let section = BedrockCredentials.iniSection(named: "staging", in: ini)
        #expect(section?["aws_access_key_id"] == "STAGEKEY")
    }

    @Test("loads credentials from an env-pointed shared credentials file")
    func profileFromFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bedrock-creds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("credentials")
        try """
        [default]
        aws_access_key_id = FILEKEY
        aws_secret_access_key = FILESECRET
        """.write(to: file, atomically: true, encoding: .utf8)

        let creds = BedrockCredentials.fromProfile(
            "default",
            env: ["AWS_SHARED_CREDENTIALS_FILE": file.path]
        )
        #expect(creds?.accessKeyId == "FILEKEY")
        #expect(creds?.secretAccessKey == "FILESECRET")
        #expect(creds?.sessionToken == nil)
    }
}

@Suite("Bedrock cache points + bearer auth")
struct BedrockCacheAndAuthTests {

    static let model = Model(
        id: "anthropic.claude-sonnet-4-20250514-v1:0",
        name: "claude",
        api: "bedrock-converse-stream",
        provider: "amazon-bedrock",
        contextWindow: 200_000,
        maxTokens: 8192
    )

    private static func longCacheModel() -> Model {
        var m = model
        var compat = ModelCompat()
        compat.supportsLongCacheRetention = true
        m.compat = compat
        return m
    }

    private static func frames(_ pairs: [(String, String)]) -> Data {
        var out = Data()
        for (type, payload) in pairs {
            out.append(encodeAWSEventFrame(
                headers: [":event-type": type, ":message-type": "event"],
                payload: Data(payload.utf8)
            ))
        }
        return out
    }

    private static func endFrames() -> Data {
        frames([
            ("messageStart", "{\"role\":\"assistant\"}"),
            ("messageStop", "{\"stopReason\":\"end_turn\"}"),
        ])
    }

    private final class ByteStubClient: HTTPClient, @unchecked Sendable {
        let body: Data
        var lastRequest: (url: URL, method: String, headers: [String: String], body: Data?)?
        init(body: Data) { self.body = body }
        func stream(
            url: URL, method: String, headers: [String: String], body requestBody: Data?
        ) async throws -> (HTTPURLResponse, AsyncThrowingStream<UInt8, Error>) {
            lastRequest = (url, method, headers, requestBody)
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["content-type": "application/vnd.amazon.eventstream"]
            )!
            let bytes = Array(body)
            let stream = AsyncThrowingStream<UInt8, Error> { cont in
                Task { for b in bytes { cont.yield(b) }; cont.finish() }
            }
            return (response, stream)
        }
    }

    private static func send(
        model: Model,
        options: StreamOptions?,
        env: [String: String] = [:],
        context: Context? = nil
    ) async -> ByteStubClient {
        let client = ByteStubClient(body: endFrames())
        let provider = BedrockProvider(
            client: client,
            region: "us-east-1",
            environment: env,
            credentialsProvider: { AWSSigV4.Credentials(accessKeyId: "k", secretAccessKey: "s") }
        )
        _ = provider.stream(
            model: model,
            context: context ?? Context(systemPrompt: "Be concise.", messages: [.user(UserMessage(text: "hi"))]),
            options: options
        )
        for _ in 0..<200 where client.lastRequest == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return client
    }

    private static func decode(_ client: ByteStubClient) throws -> [String: Any] {
        let data = client.lastRequest?.body ?? Data()
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @Test("no cache points when cacheRetention is nil/none")
    func noCachePoints() async throws {
        let client = await Self.send(model: Self.model, options: nil)
        let json = try Self.decode(client)
        let system = json["system"] as? [[String: Any]] ?? []
        #expect(system.allSatisfy { $0["cachePoint"] == nil })
        let messages = json["messages"] as? [[String: Any]] ?? []
        let lastContent = messages.last?["content"] as? [[String: Any]] ?? []
        #expect(lastContent.allSatisfy { $0["cachePoint"] == nil })
    }

    @Test("emits default cache points on system + last message for short retention")
    func shortCachePoints() async throws {
        let client = await Self.send(
            model: Self.model,
            options: StreamOptions(cacheRetention: .short)
        )
        let json = try Self.decode(client)

        let system = json["system"] as? [[String: Any]] ?? []
        let sysCache = system.compactMap { $0["cachePoint"] as? [String: Any] }
        #expect(sysCache.count == 1)
        #expect(sysCache.first?["type"] as? String == "default")
        #expect(sysCache.first?["ttl"] == nil)

        let messages = json["messages"] as? [[String: Any]] ?? []
        let lastContent = messages.last?["content"] as? [[String: Any]] ?? []
        let msgCache = lastContent.compactMap { $0["cachePoint"] as? [String: Any] }
        #expect(msgCache.count == 1)
        #expect(msgCache.first?["type"] as? String == "default")
        #expect(msgCache.first?["ttl"] == nil)
    }

    @Test("long retention adds 1h ttl on cache-capable Claude models")
    func longCacheTTL() async throws {
        let plain = await Self.send(
            model: Self.model,
            options: StreamOptions(cacheRetention: .long)
        )
        let plainJSON = try Self.decode(plain)
        let plainSys = (plainJSON["system"] as? [[String: Any]] ?? [])
            .compactMap { $0["cachePoint"] as? [String: Any] }
        #expect(plainSys.first?["type"] as? String == "default")
        #expect(plainSys.first?["ttl"] as? String == "1h")

        let long = await Self.send(
            model: Self.longCacheModel(),
            options: StreamOptions(cacheRetention: .long)
        )
        let longJSON = try Self.decode(long)
        let longSys = (longJSON["system"] as? [[String: Any]] ?? [])
            .compactMap { $0["cachePoint"] as? [String: Any] }
        #expect(longSys.first?["ttl"] as? String == "1h")
        let longMsg = ((longJSON["messages"] as? [[String: Any]] ?? []).last?["content"] as? [[String: Any]] ?? [])
            .compactMap { $0["cachePoint"] as? [String: Any] }
        #expect(longMsg.first?["ttl"] as? String == "1h")
    }

    @Test("cache points are gated to supported Claude models unless forced")
    func promptCacheModelGate() async throws {
        var nonClaude = Self.model
        nonClaude.id = "cohere.command-r-plus-v1:0"
        nonClaude.name = "Command R+"

        let gated = await Self.send(
            model: nonClaude,
            options: StreamOptions(cacheRetention: .short)
        )
        let gatedJSON = try Self.decode(gated)
        let gatedSystem = gatedJSON["system"] as? [[String: Any]] ?? []
        #expect(gatedSystem.allSatisfy { $0["cachePoint"] == nil })
        let gatedMessageContent = ((gatedJSON["messages"] as? [[String: Any]] ?? []).last?["content"] as? [[String: Any]]) ?? []
        #expect(gatedMessageContent.allSatisfy { $0["cachePoint"] == nil })

        let forced = await Self.send(
            model: nonClaude,
            options: StreamOptions(cacheRetention: .short),
            env: ["AWS_BEDROCK_FORCE_CACHE": "1"]
        )
        let forcedJSON = try Self.decode(forced)
        let forcedSystem = (forcedJSON["system"] as? [[String: Any]] ?? [])
            .compactMap { $0["cachePoint"] as? [String: Any] }
        #expect(forcedSystem.first?["type"] as? String == "default")
    }

    @Test("consecutive tool results are grouped into one user message")
    func consecutiveToolResultsGrouped() async throws {
        let assistant = AssistantMessage(
            content: [
                .toolCall(ToolCall(id: "call.1|raw", name: "first", arguments: ["x": 1])),
                .toolCall(ToolCall(id: "call.2|raw", name: "second", arguments: ["y": 2])),
            ],
            api: "bedrock-converse-stream",
            provider: "amazon-bedrock",
            model: Self.model.id,
            stopReason: .toolUse
        )
        let context = Context(messages: [
            .user(UserMessage(text: "run tools")),
            .assistant(assistant),
            .toolResult(ToolResultMessage(
                toolCallId: "call.1|raw",
                toolName: "first",
                content: [.text(TextContent(text: "one"))]
            )),
            .toolResult(ToolResultMessage(
                toolCallId: "call.2|raw",
                toolName: "second",
                content: [.text(TextContent(text: "two"))],
                isError: true
            )),
        ])
        let client = await Self.send(model: Self.model, options: nil, context: context)
        let json = try Self.decode(client)
        let messages = json["messages"] as? [[String: Any]] ?? []
        #expect(messages.count == 3)
        #expect(messages.last?["role"] as? String == "user")
        let content = messages.last?["content"] as? [[String: Any]] ?? []
        #expect(content.count == 2)
        let first = content.first?["toolResult"] as? [String: Any]
        let second = content.last?["toolResult"] as? [String: Any]
        #expect(first?["toolUseId"] as? String == "call_1_raw")
        #expect(first?["status"] as? String == "success")
        #expect(second?["toolUseId"] as? String == "call_2_raw")
        #expect(second?["status"] as? String == "error")
    }

    @Test("bearer token auth sends Authorization: Bearer and skips SigV4")
    func bearerAuth() async throws {
        let client = ByteStubClient(body: Self.endFrames())
        let provider = BedrockProvider(
            client: client,
            region: "us-east-1",
            environment: ["AWS_BEARER_TOKEN_BEDROCK": "abc123"],
            // No IAM creds available — bearer path must not require them.
            credentialsProvider: { nil }
        )
        _ = provider.stream(
            model: Self.model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: nil
        )
        for _ in 0..<200 where client.lastRequest == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let h = client.lastRequest?.headers ?? [:]
        #expect(h["authorization"] == "Bearer abc123")
        // SigV4-only headers must be absent.
        #expect(h["x-amz-date"] == nil)
        #expect(h["x-amz-content-sha256"] == nil)
    }

    @Test("EU model id with ARN routes to the EU endpoint host")
    func euRegionRouting() async throws {
        var euModel = Self.model
        euModel.id = "arn:aws:bedrock:eu-west-1:1:inference-profile/anthropic.claude-sonnet-4"
        let client = await Self.send(model: euModel, options: nil)
        let url = client.lastRequest?.url.absoluteString ?? ""
        #expect(url.contains("bedrock-runtime.eu-west-1.amazonaws.com"))
    }
}
