import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Amazon Bedrock Converse Stream provider. Speaks the `ConverseStream`
/// operation directly over HTTPS + SigV4 + AWS event-stream framing, with no
/// AWS SDK dependency. Only long-term credentials (access key + secret) +
/// optional STS session token are supported here — callers using EC2 IAM
/// roles should fetch creds out-of-band and construct `Credentials`.
public final class BedrockProvider: APIProvider, @unchecked Sendable {
    public let api: String
    public let client: HTTPClient
    /// Fallback region used when neither the model ARN, the model `baseUrl`
    /// host, nor `AWS_REGION`/`AWS_DEFAULT_REGION` pin a region.
    public let region: String
    public let credentialsProvider: @Sendable () async -> AWSSigV4.Credentials?
    public let service: String
    /// Snapshot of the environment used for region/auth resolution. Captured at
    /// init so tests can inject a deterministic environment.
    let environment: [String: String]

    public init(
        api: String = "bedrock-converse-stream",
        client: HTTPClient = URLSessionHTTPClient(),
        region: String = ProcessInfo.processInfo.environment["AWS_REGION"]
            ?? ProcessInfo.processInfo.environment["AWS_DEFAULT_REGION"]
            ?? "us-east-1",
        service: String = "bedrock",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        credentialsProvider: (@Sendable () async -> AWSSigV4.Credentials?)? = nil
    ) {
        self.api = api
        self.client = client
        self.region = region
        self.service = service
        self.environment = environment
        self.credentialsProvider = credentialsProvider ?? {
            // IAM static keys, then best-effort AWS_PROFILE shared-credentials.
            if let creds = BedrockCredentials.fromEnv(environment) { return creds }
            if let profile = environment["AWS_PROFILE"], !profile.isEmpty {
                return BedrockCredentials.fromProfile(profile, env: environment)
            }
            return nil
        }
    }

    /// Bedrock API-key bearer token (`AWS_BEARER_TOKEN_BEDROCK`). When present we
    /// send `Authorization: Bearer …` and skip SigV4 entirely.
    var bearerToken: String? {
        guard let token = environment["AWS_BEARER_TOKEN_BEDROCK"], !token.isEmpty else { return nil }
        return token
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        Task.detached { await self.run(out: out, model: model, context: context, options: options) }
        return out
    }

    private func run(
        out: AssistantMessageStream,
        model: Model,
        context: Context,
        options: StreamOptions?
    ) async {
        // Region: ARN > configuredRegion (env) > endpoint host (gated) >
        // profile region > us-east-1. (pi precedence ladder.)
        let profileRegion: String? = {
            guard let p = environment["AWS_PROFILE"], !p.isEmpty else { return nil }
            return BedrockRegion.regionFromProfile(p, env: environment)
        }()
        let effectiveRegion = BedrockRegion.resolve(
            modelId: model.id,
            baseUrl: model.baseUrl,
            env: environment,
            profileRegion: profileRegion
        )

        // Auth: bearer wins unless AWS_BEDROCK_SKIP_AUTH=1. With skip-auth set,
        // sign with real env creds if present, else dummy SigV4. Otherwise SigV4
        // needs real IAM creds. (pi `useBearerToken = bearer && !skipAuth`.)
        let skipAuth = environment["AWS_BEDROCK_SKIP_AUTH"] == "1"
        let rawBearer = bearerToken
        let useBearer = rawBearer != nil && !skipAuth

        let creds: AWSSigV4.Credentials?
        if useBearer {
            creds = nil
        } else if skipAuth {
            creds = (await credentialsProvider()) ?? BedrockCredentials.dummy
        } else {
            guard let resolved = await credentialsProvider() else {
                let msg = Self.makeError(api: api, model: model, text: "AWS credentials unavailable")
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
                return
            }
            creds = resolved
        }

        let host = "bedrock-runtime.\(effectiveRegion).amazonaws.com"
        let modelPath = model.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model.id
        let path = "/model/\(modelPath)/converse-stream"
        guard let url = URL(string: "https://\(host)\(path)") else {
            let msg = Self.makeError(api: api, model: model, text: "Invalid Bedrock URL")
            out.push(.error(reason: .error, error: msg))
            out.end(msg)
            return
        }

        let body: Data
        do {
            body = try Self.encodeBody(model: model, context: context, options: options, env: environment)
        } catch {
            let msg = Self.makeError(api: api, model: model, text: "Failed to encode request: \(error)")
            out.push(.error(reason: .error, error: msg))
            out.end(msg)
            return
        }

        var headers: [String: String] = [
            "content-type": "application/json",
            "accept": "application/vnd.amazon.eventstream",
        ]
        // Merge caller-supplied headers BEFORE signing so SigV4 covers them, and
        // drop reserved headers that would corrupt the signature or routing.
        // Previously these were applied after signing, leaving them unsigned and
        // able to clobber `authorization`/`host`. (pi signs custom headers and
        // strips `x-amz-*`/`authorization`/`host`.)
        for (k, v) in options?.headers ?? [:] {
            let lk = k.lowercased()
            if lk == "authorization" || lk == "host" || lk.hasPrefix("x-amz-") { continue }
            headers[k] = v
        }
        if useBearer, let bearer = rawBearer {
            // Bedrock API-key auth: skip SigV4, send a bearer token.
            headers["authorization"] = "Bearer \(bearer)"
            headers["host"] = host
        } else if let creds {
            headers = AWSSigV4.signPOST(
                url: url,
                body: body,
                region: effectiveRegion,
                service: service,
                credentials: creds,
                extraHeaders: headers
            )
        }

        do {
            let (response, stream) = try await client.stream(
                url: url, method: "POST", headers: headers, body: body
            )
            if response.statusCode >= 400 {
                let msg = Self.makeError(
                    api: api, model: model,
                    text: "Bedrock returned status \(response.statusCode)"
                )
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
                return
            }
            let state = BedrockStreamState(api: api, provider: model.provider, modelId: model.id)
            state.signal = options?.cancellation
            try await drive(events: parseAWSEventStream(bytes: stream), out: out, state: state)
        } catch {
            let msg = Self.makeError(api: api, model: model, text: "\(error)")
            out.push(.error(reason: .error, error: msg))
            out.end(msg)
        }
    }

    private func drive(
        events: AsyncThrowingStream<AWSEventMessage, Error>,
        out: AssistantMessageStream,
        state: BedrockStreamState
    ) async throws {
        var emittedStart = false
        for try await event in events {
            if state.signal?.isCancelled == true {
                let aborted = state.asAborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
                return
            }
            let type = event.headers[":event-type"] ?? ""
            let messageType = event.headers[":message-type"] ?? "event"

            if messageType == "exception" {
                let text: String = {
                    guard let obj = parseJSONObject(String(data: event.payload, encoding: .utf8) ?? ""),
                          case .object(let dict) = obj,
                          case .string(let msg) = dict["message"] ?? .null else {
                        return "Bedrock exception: \(type)"
                    }
                    return msg
                }()
                let err = state.asError(text: text)
                out.push(.error(reason: .error, error: err))
                out.end(err)
                return
            }

            guard let obj = parseJSONObject(String(data: event.payload, encoding: .utf8) ?? ""),
                  case .object(let payload) = obj else { continue }

            switch type {
            case "messageStart":
                if !emittedStart {
                    out.push(.start(partial: state.snapshot()))
                    emittedStart = true
                }
            case "contentBlockStart":
                let blockIndex: Int = {
                    if case .int(let v) = payload["contentBlockIndex"] ?? .null { return v } else { return 0 }
                }()
                if case .object(let start) = payload["start"] ?? .null {
                    if case .object(let toolUse) = start["toolUse"] ?? .null {
                        let id: String = {
                            if case .string(let v) = toolUse["toolUseId"] ?? .null { return v } else { return "" }
                        }()
                        let name: String = {
                            if case .string(let v) = toolUse["name"] ?? .null { return v } else { return "" }
                        }()
                        let index = state.noteToolUseBlock(at: blockIndex, id: id, name: name)
                        if !emittedStart {
                            out.push(.start(partial: state.snapshot()))
                            emittedStart = true
                        }
                        out.push(.toolCallStart(contentIndex: index, partial: state.snapshot()))
                    }
                }
            case "contentBlockDelta":
                let blockIndex: Int = {
                    if case .int(let v) = payload["contentBlockIndex"] ?? .null { return v } else { return 0 }
                }()
                guard case .object(let delta) = payload["delta"] ?? .null else { break }
                if case .string(let text) = delta["text"] ?? .null {
                    let (index, firstSeen) = state.noteTextBlock(at: blockIndex)
                    if !emittedStart {
                        out.push(.start(partial: state.snapshot()))
                        emittedStart = true
                    }
                    if firstSeen {
                        out.push(.textStart(contentIndex: index, partial: state.snapshot()))
                    }
                    state.appendText(index: index, text: text)
                    out.push(.textDelta(contentIndex: index, delta: text, partial: state.snapshot()))
                }
                if case .object(let reasoning) = delta["reasoningContent"] ?? .null,
                   case .string(let text) = reasoning["text"] ?? .null {
                    let (index, firstSeen) = state.noteThinkingBlock(at: blockIndex)
                    if !emittedStart {
                        out.push(.start(partial: state.snapshot()))
                        emittedStart = true
                    }
                    if firstSeen {
                        out.push(.thinkingStart(contentIndex: index, partial: state.snapshot()))
                    }
                    state.appendThinking(index: index, text: text)
                    out.push(.thinkingDelta(contentIndex: index, delta: text, partial: state.snapshot()))
                }
                if case .object(let toolUse) = delta["toolUse"] ?? .null,
                   case .string(let input) = toolUse["input"] ?? .null {
                    if let index = state.toolCallIndex(at: blockIndex) {
                        state.appendToolCallArgs(index: index, chunk: input)
                        out.push(.toolCallDelta(contentIndex: index, delta: input, partial: state.snapshot()))
                    }
                }
            case "contentBlockStop":
                let blockIndex: Int = {
                    if case .int(let v) = payload["contentBlockIndex"] ?? .null { return v } else { return 0 }
                }()
                state.finishBlock(at: blockIndex) { event in out.push(event) }
            case "messageStop":
                if case .string(let reason) = payload["stopReason"] ?? .null {
                    state.stopReason = Self.mapStopReason(reason)
                }
            case "metadata":
                if case .object(let usage) = payload["usage"] ?? .null {
                    state.applyUsage(usage)
                }
            default:
                break
            }
        }

        state.finalizePending { event in out.push(event) }
        let final = state.finalize()
        out.push(.done(reason: final.stopReason, message: final))
        out.end(final)
    }

    // MARK: - Encoding

    private static let emptyTextPlaceholder = "<empty>"

    private static func encodeBody(
        model: Model, context: Context, options: StreamOptions?, env: [String: String] = [:]
    ) throws -> Data {
        let retention = options?.cacheRetention ?? CacheRetention.none
        let cachePoint: [String: Any]? = retention != .none && supportsPromptCaching(model: model, env: env)
            ? makeCachePoint(retention: retention)
            : nil
        var context = context
        context.messages = normalizeToolCallIds(TransformMessages.normalize(context.messages, model: model))

        var root: [String: Any] = [
            "messages": encodeMessages(model: model, context: context, cachePoint: cachePoint),
        ]
        if let sys = context.systemPrompt, !sys.isEmpty {
            var system: [[String: Any]] = [["text": sys]]
            if let cachePoint { system.append(cachePoint) }
            root["system"] = system
        }
        var inference: [String: Any] = [:]
        if let t = options?.temperature { inference["temperature"] = t }
        let maxTokens = options?.maxTokens ?? (model.maxTokens > 0 ? model.maxTokens : nil)
        if let m = maxTokens { inference["maxTokens"] = m }
        if !inference.isEmpty { root["inferenceConfig"] = inference }
        if let tools = context.tools, !tools.isEmpty {
            var toolConfig: [String: Any] = [
                "tools": tools.map { tool -> [String: Any] in
                    let schema: Any = anyFromJSONValue(tool.parameters) ?? [String: Any]()
                    return [
                        "toolSpec": [
                            "name": tool.name,
                            "description": tool.description,
                            "inputSchema": ["json": schema],
                        ] as [String: Any],
                    ]
                },
            ]
            if let choice = encodeToolChoice(options?.toolChoice) {
                toolConfig["toolChoice"] = choice
            }
            root["toolConfig"] = toolConfig
        }
        // Only Anthropic Claude models accept the `thinking` field via Bedrock
        // Converse; injecting it for Nova/Llama/Titan/etc. is a 400. (pi gates
        // this on `isAnthropicClaudeModel`.)
        if let extras = buildAdditionalModelRequestFields(model: model, options: options, env: env) {
            root["additionalModelRequestFields"] = extras
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Lowercased id+name plus a normalized variant where runs of whitespace /
    /// `.` / `_` / `:` collapse to a single `-` (so `claude-opus-4.8` matches
    /// `opus-4-8`). Mirrors pi `getModelMatchCandidates`.
    private static func modelMatchCandidates(_ model: Model) -> [String] {
        [model.id, model.name].flatMap { value -> [String] in
            let lower = value.lowercased()
            let normalized = lower.replacingOccurrences(
                of: "[\\s_.:]+", with: "-", options: .regularExpression)
            return [lower, normalized]
        }
    }

    private static func supportsAdaptiveThinking(_ model: Model) -> Bool {
        let c = modelMatchCandidates(model)
        return c.contains { $0.contains("opus-4-6") || $0.contains("opus-4-7")
            || $0.contains("opus-4-8") || $0.contains("sonnet-4-6") || $0.contains("fable-5") }
    }

    private static func supportsNativeXhighEffort(_ model: Model) -> Bool {
        let c = modelMatchCandidates(model)
        return c.contains { $0.contains("opus-4-7") || $0.contains("opus-4-8") || $0.contains("fable-5") }
    }

    private static func mapThinkingLevelToEffort(_ model: Model, _ level: ReasoningLevel) -> String {
        if level == .xhigh, supportsNativeXhighEffort(model) { return "xhigh" }
        if let mapped = model.thinkingLevelMap?[level.rawValue], let m = mapped { return m }
        switch level {
        case .minimal, .low: return "low"
        case .medium: return "medium"
        case .high, .xhigh: return "high"
        }
    }

    /// Whether the resolved Bedrock target is GovCloud (us-gov-*). pi uses the
    /// configured region (option/AWS_REGION/AWS_DEFAULT_REGION); kwwk has no
    /// option.region so it uses env region plus the model-id partition prefix.
    private static func isGovCloudBedrockTarget(model: Model, env: [String: String]) -> Bool {
        if let r = BedrockRegion.fromEnv(env)?.lowercased(), r.hasPrefix("us-gov-") { return true }
        let id = model.id.lowercased()
        return id.hasPrefix("us-gov.") || id.hasPrefix("arn:aws-us-gov:")
    }

    /// Builds `additionalModelRequestFields` for reasoning. Returns nil unless
    /// the caller requested reasoning, the model declares `reasoning`, and it is
    /// an Anthropic Claude model. Mirrors pi `buildAdditionalModelRequestFields`.
    static func buildAdditionalModelRequestFields(
        model: Model, options: StreamOptions?, env: [String: String]
    ) -> [String: Any]? {
        guard let reasoning = options?.reasoning, model.reasoning else { return nil }
        guard isAnthropicClaudeModel(model) else { return nil }

        let display: String? = isGovCloudBedrockTarget(model: model, env: env)
            ? nil
            : (options?.thinkingDisplay?.rawValue ?? "summarized")

        var result: [String: Any]
        if supportsAdaptiveThinking(model) {
            var thinking: [String: Any] = ["type": "adaptive"]
            if let display { thinking["display"] = display }
            result = [
                "thinking": thinking,
                "output_config": ["effort": mapThinkingLevelToEffort(model, reasoning)],
            ]
        } else {
            let defaults: [ReasoningLevel: Int] = [
                .minimal: 1024, .low: 2048, .medium: 8192, .high: 16384, .xhigh: 16384,
            ]
            let budgetLevel: ReasoningLevel = reasoning == .xhigh ? .high : reasoning
            let budget = options?.thinkingBudgets?.budget(for: budgetLevel) ?? defaults[reasoning]!
            var thinking: [String: Any] = ["type": "enabled", "budget_tokens": budget]
            if let display { thinking["display"] = display }
            result = ["thinking": thinking]
            if options?.interleavedThinking ?? true {
                result["anthropic_beta"] = ["interleaved-thinking-2025-05-14"]
            }
        }
        return result
    }

    /// Whether a Bedrock model is an Anthropic Claude model (plain id, regional
    /// `us.`/`eu.`/`apac.` prefix, or inference-profile ARN all carry the name).
    private static func isAnthropicClaudeModel(_ model: Model) -> Bool {
        let id = model.id.lowercased()
        return id.contains("claude") || id.contains("anthropic")
    }

    /// Builds the `cachePoint` content block. `{"cachePoint":{"type":"default"}}`,
    /// plus a 1h ttl for long retention on Bedrock's cache-capable Claude models.
    private static func makeCachePoint(retention: CacheRetention) -> [String: Any] {
        var point: [String: Any] = ["type": "default"]
        if retention == .long {
            point["ttl"] = "1h"
        }
        return ["cachePoint": point]
    }

    private static func encodeMessages(
        model: Model, context: Context, cachePoint: [String: Any]? = nil
    ) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var index = 0
        while index < context.messages.count {
            let message = context.messages[index]
            switch message {
            case .user(let u):
                var parts: [[String: Any]] = []
                for block in u.content {
                    switch block {
                    case .text(let t):
                        if let text = nonBlankText(t.text) { parts.append(text) }
                    case .image(let i):
                        parts.append([
                            "image": [
                                "format": Self.imageFormat(i.mimeType),
                                "source": ["bytes": i.data],
                            ],
                        ])
                    }
                }
                if parts.isEmpty { parts.append(["text": emptyTextPlaceholder]) }
                out.append(["role": "user", "content": parts])

            case .assistant(let a):
                var parts: [[String: Any]] = []
                for block in a.content {
                    switch block {
                    case .text(let t):
                        if let text = nonBlankText(t.text) { parts.append(text) }
                    case .thinking(let th):
                        if !th.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let thinking = th.thinking
                            if supportsThinkingSignature(model: model),
                               let signature = th.thinkingSignature,
                               !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                parts.append([
                                    "reasoningContent": [
                                        "reasoningText": [
                                            "text": thinking,
                                            "signature": signature,
                                        ],
                                    ],
                                ])
                            } else if supportsThinkingSignature(model: model) {
                                parts.append(["text": thinking])
                            } else {
                                parts.append([
                                    "reasoningContent": [
                                        "reasoningText": ["text": thinking],
                                    ],
                                ])
                            }
                        }
                    case .toolCall(let tc):
                        let input: Any = anyFromJSONValue(tc.arguments) ?? [String: Any]()
                        parts.append([
                            "toolUse": [
                                "toolUseId": tc.id,
                                "name": tc.name,
                                "input": input,
                            ] as [String: Any],
                        ])
                    }
                }
                if !parts.isEmpty {
                    out.append(["role": "assistant", "content": parts])
                }

            case .toolResult:
                var content: [[String: Any]] = []
                var j = index
                while j < context.messages.count {
                    guard case .toolResult(let tr) = context.messages[j] else { break }
                    content.append(makeToolResultEntry(tr))
                    j += 1
                }
                out.append(["role": "user", "content": content])
                index = j
                continue
            }
            index += 1
        }
        // Append a cache point to the last user message so Bedrock caches the
        // full prefix up to and including the latest turn.
        if let cachePoint,
           let lastIndex = out.indices.reversed().first(where: { out[$0]["role"] as? String == "user" }),
           var content = out[lastIndex]["content"] as? [[String: Any]] {
            content.append(cachePoint)
            out[lastIndex]["content"] = content
        }
        return out
    }

    private static func makeToolResultEntry(_ tr: ToolResultMessage) -> [String: Any] {
        var content: [[String: Any]] = []
        for block in tr.content {
            switch block {
            case .text(let t):
                if let text = nonBlankText(t.text) { content.append(text) }
            case .image(let i):
                content.append([
                    "image": [
                        "format": imageFormat(i.mimeType),
                        "source": ["bytes": i.data],
                    ],
                ])
            }
        }
        if content.isEmpty { content.append(["text": emptyTextPlaceholder]) }
        let toolResult: [String: Any] = [
            "toolUseId": tr.toolCallId,
            "content": content,
            "status": tr.isError ? "error" : "success",
        ]
        return ["toolResult": toolResult]
    }

    private static func nonBlankText(_ text: String) -> [String: Any]? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ["text": text]
    }

    private static func normalizeToolCallIds(_ messages: [Message]) -> [Message] {
        var map: [String: String] = [:]
        func normalize(_ id: String) -> String {
            if let existing = map[id] { return existing }
            let sanitized = id.map { ch -> Character in
                if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" { return ch }
                return "_"
            }
            let value = String(sanitized.prefix(64))
            let resolved = value.isEmpty ? "tool_use" : value
            map[id] = resolved
            return resolved
        }

        return messages.map { message in
            switch message {
            case .assistant(var a):
                a.content = a.content.map { block in
                    guard case .toolCall(var tc) = block else { return block }
                    tc.id = normalize(tc.id)
                    return .toolCall(tc)
                }
                return .assistant(a)
            case .toolResult(var tr):
                tr.toolCallId = normalize(tr.toolCallId)
                return .toolResult(tr)
            case .user:
                return message
            }
        }
    }

    private static func supportsPromptCaching(model: Model, env: [String: String]) -> Bool {
        let candidates = [model.id, model.name].map { $0.lowercased() }
        guard candidates.contains(where: { $0.contains("claude") }) else {
            return env["AWS_BEDROCK_FORCE_CACHE"] == "1"
        }
        return candidates.contains(where: {
            $0.contains("-4-")
                || $0.contains("claude-3-7-sonnet")
                || $0.contains("claude-3-5-haiku")
        })
    }

    private static func supportsThinkingSignature(model: Model) -> Bool {
        [model.id, model.name].map { $0.lowercased() }.contains { value in
            value.contains("anthropic.claude")
                || value.contains("anthropic/claude")
                || value.contains("claude")
        }
    }

    private static func encodeToolChoice(_ choice: ToolChoice?) -> Any? {
        guard let choice else { return nil }
        switch choice {
        case .auto: return ["auto": [:] as [String: Any]]
        case .none: return nil // Converse doesn't expose a `none` — drop.
        case .required: return ["any": [:] as [String: Any]]
        case .tool(let name): return ["tool": ["name": name]]
        }
    }

    private static func imageFormat(_ mimeType: String) -> String {
        switch mimeType {
        case "image/png": return "png"
        case "image/jpeg": return "jpeg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "png"
        }
    }

    private static func mapStopReason(_ raw: String) -> StopReason {
        switch raw {
        case "end_turn", "stop_sequence": return .stop
        case "max_tokens", "model_context_window_exceeded": return .length
        case "tool_use": return .toolUse
        default: return .error
        }
    }

    private static func makeError(api: String, model: Model, text: String) -> AssistantMessage {
        AssistantMessage(
            content: [],
            api: api,
            provider: model.provider,
            model: model.id,
            usage: Usage(),
            stopReason: .error,
            errorMessage: text,
            timestamp: Timestamp.now()
        )
    }
}

// MARK: - Mutable state

final class BedrockStreamState: @unchecked Sendable {
    let api: String
    let provider: String
    let modelId: String
    var signal: CancellationHandle?
    var usage = Usage()
    var stopReason: StopReason = .stop
    var errorMessage: String?

    enum Block {
        case text(TextContent)
        case thinking(ThinkingContent)
        case toolUse(id: String, name: String, json: String)
    }

    private let lock = NSLock()
    private var blocks: [Int: Block] = [:]
    /// Bedrock's `contentBlockIndex` → our ordinal index in `order`.
    private var blockByIndex: [Int: Int] = [:]
    private var order: [Int] = []
    private var endedIndices: Set<Int> = []

    init(api: String, provider: String, modelId: String) {
        self.api = api
        self.provider = provider
        self.modelId = modelId
    }

    func noteTextBlock(at blockIndex: Int) -> (index: Int, firstSeen: Bool) {
        lock.withLock {
            if let existing = blockByIndex[blockIndex] { return (existing, false) }
            let idx = order.count
            blockByIndex[blockIndex] = idx
            order.append(idx)
            blocks[idx] = .text(TextContent(text: ""))
            return (idx, true)
        }
    }

    func noteThinkingBlock(at blockIndex: Int) -> (index: Int, firstSeen: Bool) {
        lock.withLock {
            if let existing = blockByIndex[blockIndex] { return (existing, false) }
            let idx = order.count
            blockByIndex[blockIndex] = idx
            order.append(idx)
            blocks[idx] = .thinking(ThinkingContent(thinking: ""))
            return (idx, true)
        }
    }

    func noteToolUseBlock(at blockIndex: Int, id: String, name: String) -> Int {
        lock.withLock {
            if let existing = blockByIndex[blockIndex] { return existing }
            let idx = order.count
            blockByIndex[blockIndex] = idx
            order.append(idx)
            blocks[idx] = .toolUse(id: id, name: name, json: "")
            return idx
        }
    }

    func toolCallIndex(at blockIndex: Int) -> Int? {
        lock.withLock { blockByIndex[blockIndex] }
    }

    func appendText(index: Int, text: String) {
        lock.withLock {
            if case .text(var t) = blocks[index] { t.text += text; blocks[index] = .text(t) }
        }
    }
    func appendThinking(index: Int, text: String) {
        lock.withLock {
            if case .thinking(var th) = blocks[index] { th.thinking += text; blocks[index] = .thinking(th) }
        }
    }
    func appendToolCallArgs(index: Int, chunk: String) {
        lock.withLock {
            if case .toolUse(let id, let name, let json) = blocks[index] {
                blocks[index] = .toolUse(id: id, name: name, json: json + chunk)
            }
        }
    }

    func finishBlock(at blockIndex: Int, emit: (AssistantMessageEvent) -> Void) {
        let idx: Int? = lock.withLock { blockByIndex[blockIndex] }
        guard let idx, !endedIndices.contains(idx) else { return }
        let partial = snapshot()
        guard let block = lock.withLock({ blocks[idx] }) else { return }
        switch block {
        case .text(let t):
            emit(.textEnd(contentIndex: idx, content: t.text, partial: partial))
        case .thinking(let th):
            emit(.thinkingEnd(contentIndex: idx, content: th.thinking, partial: partial))
        case .toolUse(let id, let name, let json):
            let call = ToolCall(id: id, name: name, arguments: parseArgs(json))
            emit(.toolCallEnd(contentIndex: idx, toolCall: call, partial: partial))
        }
        _ = lock.withLock { endedIndices.insert(idx) }
    }

    func finalizePending(emit: (AssistantMessageEvent) -> Void) {
        let indices = lock.withLock { order }
        for idx in indices where !endedIndices.contains(idx) {
            let partial = snapshot()
            guard let block = lock.withLock({ blocks[idx] }) else { continue }
            switch block {
            case .text(let t):
                emit(.textEnd(contentIndex: idx, content: t.text, partial: partial))
            case .thinking(let th):
                emit(.thinkingEnd(contentIndex: idx, content: th.thinking, partial: partial))
            case .toolUse(let id, let name, let json):
                let call = ToolCall(id: id, name: name, arguments: parseArgs(json))
                emit(.toolCallEnd(contentIndex: idx, toolCall: call, partial: partial))
            }
            _ = lock.withLock { endedIndices.insert(idx) }
        }
    }

    func applyUsage(_ obj: [String: JSONValue]) {
        if case .int(let v) = obj["inputTokens"] ?? .null { usage.input = v }
        if case .int(let v) = obj["outputTokens"] ?? .null { usage.output = v }
        if case .int(let v) = obj["cacheReadInputTokens"] ?? .null { usage.cacheRead = v }
        if case .int(let v) = obj["cacheWriteInputTokens"] ?? .null { usage.cacheWrite = v }
        // pi: prefer the upstream totalTokens (truthy ⇒ > 0); else input+output,
        // and do NOT sum cacheRead/cacheWrite into the total.
        if case .int(let v) = obj["totalTokens"] ?? .null, v > 0 {
            usage.totalTokens = v
        } else {
            usage.totalTokens = usage.input + usage.output
        }
    }

    func snapshot() -> AssistantMessage {
        lock.withLock {
            AssistantMessage(
                content: order.compactMap { idx -> AssistantBlock? in
                    switch blocks[idx] {
                    case .text(let t): return .text(t)
                    case .thinking(let th): return .thinking(th)
                    case .toolUse(let id, let name, let json):
                        return .toolCall(ToolCall(id: id, name: name, arguments: parseArgs(json)))
                    case .none: return nil
                    }
                },
                api: api,
                provider: provider,
                model: modelId,
                usage: usage,
                stopReason: stopReason,
                errorMessage: errorMessage,
                timestamp: Timestamp.now()
            )
        }
    }

    func finalize() -> AssistantMessage { snapshot() }

    func asAborted() -> AssistantMessage {
        stopReason = .aborted
        errorMessage = "Request was aborted"
        return snapshot()
    }

    func asError(text: String) -> AssistantMessage {
        stopReason = .error
        errorMessage = text
        return snapshot()
    }

    private func parseArgs(_ json: String) -> JSONValue {
        if json.isEmpty { return .object([:]) }
        if let data = json.data(using: .utf8),
           let v = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return v
        }
        return .object([:])
    }
}
