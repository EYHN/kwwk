import Foundation

// MARK: - Faux helpers (public API matching pi-ai)

public func fauxText(_ text: String) -> AssistantBlock {
    .text(TextContent(text: text))
}

public func fauxThinking(_ thinking: String) -> AssistantBlock {
    .thinking(ThinkingContent(thinking: thinking))
}

public func fauxToolCall(
    name: String,
    arguments: JSONValue,
    id: String? = nil
) -> AssistantBlock {
    .toolCall(ToolCall(id: id ?? FauxProvider.randomId(prefix: "tool"), name: name, arguments: arguments))
}

public func fauxAssistantMessage(
    _ text: String,
    stopReason: StopReason = .stop,
    errorMessage: String? = nil,
    responseId: String? = nil,
    timestamp: Int64? = nil
) -> AssistantMessage {
    fauxAssistantMessage(
        blocks: [fauxText(text)],
        stopReason: stopReason,
        errorMessage: errorMessage,
        responseId: responseId,
        timestamp: timestamp
    )
}

public func fauxAssistantMessage(
    blocks: [AssistantBlock],
    stopReason: StopReason = .stop,
    errorMessage: String? = nil,
    responseId: String? = nil,
    timestamp: Int64? = nil
) -> AssistantMessage {
    AssistantMessage(
        content: blocks,
        api: FauxProvider.defaultAPI,
        provider: FauxProvider.defaultProvider,
        model: FauxProvider.defaultModelId,
        responseId: responseId,
        usage: FauxProvider.defaultUsage,
        stopReason: stopReason,
        errorMessage: errorMessage,
        timestamp: timestamp ?? Timestamp.now()
    )
}

// MARK: - Faux model definition

public struct FauxModelDefinition: Sendable {
    public var id: String
    public var name: String?
    public var reasoning: Bool?
    public var input: [InputModality]?
    public var cost: ModelCost?
    public var contextWindow: Int?
    public var maxTokens: Int?

    public init(
        id: String,
        name: String? = nil,
        reasoning: Bool? = nil,
        input: [InputModality]? = nil,
        cost: ModelCost? = nil,
        contextWindow: Int? = nil,
        maxTokens: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.reasoning = reasoning
        self.input = input
        self.cost = cost
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
    }
}

public struct FauxTokenSize: Sendable {
    public var min: Int?
    public var max: Int?
    public init(min: Int? = nil, max: Int? = nil) {
        self.min = min
        self.max = max
    }
}

public struct RegisterFauxProviderOptions: Sendable {
    public var api: String?
    public var provider: String?
    public var models: [FauxModelDefinition]?
    public var tokensPerSecond: Double?
    public var tokenSize: FauxTokenSize?

    public init(
        api: String? = nil,
        provider: String? = nil,
        models: [FauxModelDefinition]? = nil,
        tokensPerSecond: Double? = nil,
        tokenSize: FauxTokenSize? = nil
    ) {
        self.api = api
        self.provider = provider
        self.models = models
        self.tokensPerSecond = tokensPerSecond
        self.tokenSize = tokenSize
    }
}

// MARK: - Faux response factory

/// A single scripted response step: either a prebuilt message or a factory
/// that computes one lazily from the call context.
public enum FauxResponseStep: Sendable {
    case message(AssistantMessage)
    case factory(@Sendable (Context, StreamOptions?, FauxState, Model) async throws -> AssistantMessage)
}

public struct FauxState: Sendable {
    public var callCount: Int
}

// MARK: - Registration

/// Opaque handle returned from `registerFauxProvider`. Tests use this to
/// queue responses and inspect invocation counts.
public final class FauxProviderRegistration: @unchecked Sendable {
    public let api: String
    public let provider: String
    public let models: [Model]
    private let sourceId: String
    private let providerImpl: FauxProvider

    init(api: String, provider: String, models: [Model], sourceId: String, impl: FauxProvider) {
        self.api = api
        self.provider = provider
        self.models = models
        self.sourceId = sourceId
        self.providerImpl = impl
    }

    /// Default model — the first one declared at registration time.
    public func getModel() -> Model { models[0] }

    public func getModel(id: String) -> Model? { models.first(where: { $0.id == id }) }

    public var state: FauxState {
        providerImpl.snapshotState()
    }

    public func setResponses(_ steps: [FauxResponseStep]) {
        providerImpl.setResponses(steps)
    }

    public func appendResponses(_ steps: [FauxResponseStep]) {
        providerImpl.appendResponses(steps)
    }

    public func getPendingResponseCount() -> Int {
        providerImpl.getPendingResponseCount()
    }

    public func unregister() {
        let sourceId = self.sourceId
        Task { await APIRegistry.shared.unregisterSource(sourceId) }
    }

    /// Async variant of `unregister` that blocks until the registry has
    /// actually removed this provider. Useful in test teardown.
    public func unregisterAsync() async {
        await APIRegistry.shared.unregisterSource(sourceId)
    }
}

public func registerFauxProvider(_ options: RegisterFauxProviderOptions = .init()) async -> FauxProviderRegistration {
    let api = options.api ?? FauxProvider.randomId(prefix: "faux")
    let provider = options.provider ?? FauxProvider.defaultProvider
    let sourceId = FauxProvider.randomId(prefix: "faux-provider")
    let minSize = max(1, min(options.tokenSize?.min ?? FauxProvider.defaultMinTokenSize,
                              options.tokenSize?.max ?? FauxProvider.defaultMaxTokenSize))
    let maxSize = max(minSize, options.tokenSize?.max ?? FauxProvider.defaultMaxTokenSize)

    let modelDefs: [FauxModelDefinition] = options.models?.isEmpty == false
        ? options.models!
        : [FauxModelDefinition(
            id: FauxProvider.defaultModelId,
            name: FauxProvider.defaultModelName,
            reasoning: false,
            input: [.text, .image],
            cost: .init(),
            contextWindow: 128_000,
            maxTokens: 16_384
          )]

    let models: [Model] = modelDefs.map { def in
        Model(
            id: def.id,
            name: def.name ?? def.id,
            api: api,
            provider: provider,
            baseURL: FauxProvider.defaultBaseURL,
            reasoning: def.reasoning ?? false,
            input: def.input ?? [.text, .image],
            cost: def.cost ?? .init(),
            contextWindow: def.contextWindow ?? 128_000,
            maxTokens: def.maxTokens ?? 16_384
        )
    }

    let impl = FauxProvider(
        api: api,
        provider: provider,
        models: models,
        minTokenSize: minSize,
        maxTokenSize: maxSize,
        tokensPerSecond: options.tokensPerSecond
    )
    let registration = FauxProviderRegistration(
        api: api, provider: provider, models: models, sourceId: sourceId, impl: impl
    )
    await APIRegistry.shared.register(impl, sourceId: sourceId)
    return registration
}

// MARK: - Faux provider implementation

public final class FauxProvider: APIProvider, @unchecked Sendable {
    static let defaultAPI = "faux"
    static let defaultProvider = "faux"
    static let defaultModelId = "faux-1"
    static let defaultModelName = "Faux Model"
    static let defaultBaseURL = "http://localhost:0"
    static let defaultMinTokenSize = 3
    static let defaultMaxTokenSize = 5
    static let defaultUsage = Usage()

    public let api: String
    public let providerName: String
    private let models: [Model]
    private let minTokenSize: Int
    private let maxTokenSize: Int
    private let tokensPerSecond: Double?

    private let lock = NSLock()
    private var pendingResponses: [FauxResponseStep] = []
    private var callCount = 0
    private var promptCache: [String: String] = [:]

    init(
        api: String,
        provider: String,
        models: [Model],
        minTokenSize: Int,
        maxTokenSize: Int,
        tokensPerSecond: Double?
    ) {
        self.api = api
        self.providerName = provider
        self.models = models
        self.minTokenSize = minTokenSize
        self.maxTokenSize = maxTokenSize
        self.tokensPerSecond = tokensPerSecond
    }

    // MARK: Registration API

    func snapshotState() -> FauxState {
        lock.lock(); defer { lock.unlock() }
        return FauxState(callCount: callCount)
    }

    func setResponses(_ steps: [FauxResponseStep]) {
        lock.lock(); defer { lock.unlock() }
        pendingResponses = steps
    }

    func appendResponses(_ steps: [FauxResponseStep]) {
        lock.lock(); defer { lock.unlock() }
        pendingResponses.append(contentsOf: steps)
    }

    func getPendingResponseCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return pendingResponses.count
    }

    private func popResponse() -> FauxResponseStep? {
        lock.lock(); defer { lock.unlock() }
        callCount += 1
        guard !pendingResponses.isEmpty else { return nil }
        return pendingResponses.removeFirst()
    }

    private func cachedPrompt(for sessionId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return promptCache[sessionId]
    }

    private func setCachedPrompt(_ prompt: String, for sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        promptCache[sessionId] = prompt
    }

    // MARK: APIProvider

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let outStream = AssistantMessageStream()
        let step = popResponse()
        let currentCall = { [weak self] in self?.snapshotState().callCount ?? 0 }()
        let api = self.api
        let provider = self.providerName
        let minTokenSize = self.minTokenSize
        let maxTokenSize = self.maxTokenSize
        let tokensPerSecond = self.tokensPerSecond
        let getCached: @Sendable (String) -> String? = { [weak self] id in self?.cachedPrompt(for: id) }
        let setCached: @Sendable (String, String) -> Void = { [weak self] prompt, id in self?.setCachedPrompt(prompt, for: id) }

        if tokensPerSecond == nil {
            switch step {
            case nil:
                var errorMessage = FauxProvider.makeErrorMessage(
                    reason: "No more faux responses queued",
                    api: api, provider: provider, modelId: model.id
                )
                errorMessage = FauxProvider.estimateUsage(
                    message: errorMessage,
                    context: context,
                    options: options,
                    cached: getCached,
                    setCached: setCached
                )
                outStream.push(.error(reason: .error, error: errorMessage))
                outStream.end(errorMessage)
                return outStream

            case .message(let resolved)?:
                var message = FauxProvider.clone(
                    resolved, api: api, provider: provider, modelId: model.id
                )
                message = FauxProvider.estimateUsage(
                    message: message,
                    context: context,
                    options: options,
                    cached: getCached,
                    setCached: setCached
                )
                FauxProvider.streamDeltasImmediately(
                    to: outStream,
                    message: message,
                    minTokenSize: minTokenSize,
                    maxTokenSize: maxTokenSize,
                    cancellation: options?.cancellation
                )
                return outStream

            case .factory?:
                break
            }
        }

        Task {
            guard let step else {
                var errorMessage = FauxProvider.makeErrorMessage(
                    reason: "No more faux responses queued",
                    api: api, provider: provider, modelId: model.id
                )
                errorMessage = FauxProvider.estimateUsage(
                    message: errorMessage,
                    context: context,
                    options: options,
                    cached: getCached,
                    setCached: setCached
                )
                outStream.push(.error(reason: .error, error: errorMessage))
                outStream.end(errorMessage)
                return
            }
            do {
                let resolved: AssistantMessage
                switch step {
                case .message(let m):
                    resolved = m
                case .factory(let f):
                    resolved = try await f(context, options, FauxState(callCount: currentCall), model)
                }
                var message = FauxProvider.clone(
                    resolved, api: api, provider: provider, modelId: model.id
                )
                message = FauxProvider.estimateUsage(
                    message: message,
                    context: context,
                    options: options,
                    cached: getCached,
                    setCached: setCached
                )
                await FauxProvider.streamDeltas(
                    to: outStream,
                    message: message,
                    minTokenSize: minTokenSize,
                    maxTokenSize: maxTokenSize,
                    tokensPerSecond: tokensPerSecond,
                    cancellation: options?.cancellation
                )
            } catch {
                let message = FauxProvider.makeErrorMessage(
                    reason: "\(error)",
                    api: api, provider: provider, modelId: model.id
                )
                outStream.push(.error(reason: .error, error: message))
                outStream.end(message)
            }
        }

        return outStream
    }

    // MARK: Streaming

    static func streamDeltasImmediately(
        to stream: AssistantMessageStream,
        message: AssistantMessage,
        minTokenSize: Int,
        maxTokenSize: Int,
        cancellation: CancellationHandle?
    ) {
        var partial = message
        partial.content = []

        if cancellation?.isCancelled == true {
            let aborted = abortedMessage(from: partial)
            stream.push(.error(reason: .aborted, error: aborted))
            stream.end(aborted)
            return
        }

        stream.push(.start(partial: partial))

        for (index, block) in message.content.enumerated() {
            if cancellation?.isCancelled == true {
                let aborted = abortedMessage(from: partial)
                stream.push(.error(reason: .aborted, error: aborted))
                stream.end(aborted)
                return
            }
            switch block {
            case .thinking(let t):
                partial.content.append(.thinking(ThinkingContent(thinking: "")))
                stream.push(.thinkingStart(contentIndex: index, partial: partial))
                for chunk in splitByTokenSize(t.thinking, min: minTokenSize, max: maxTokenSize) {
                    if cancellation?.isCancelled == true {
                        let aborted = abortedMessage(from: partial)
                        stream.push(.error(reason: .aborted, error: aborted))
                        stream.end(aborted)
                        return
                    }
                    if case .thinking(var current) = partial.content[index] {
                        current.thinking += chunk
                        partial.content[index] = .thinking(current)
                    }
                    stream.push(.thinkingDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                stream.push(.thinkingEnd(contentIndex: index, content: t.thinking, partial: partial))

            case .text(let t):
                partial.content.append(.text(TextContent(text: "")))
                stream.push(.textStart(contentIndex: index, partial: partial))
                for chunk in splitByTokenSize(t.text, min: minTokenSize, max: maxTokenSize) {
                    if cancellation?.isCancelled == true {
                        let aborted = abortedMessage(from: partial)
                        stream.push(.error(reason: .aborted, error: aborted))
                        stream.end(aborted)
                        return
                    }
                    if case .text(var current) = partial.content[index] {
                        current.text += chunk
                        partial.content[index] = .text(current)
                    }
                    stream.push(.textDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                stream.push(.textEnd(contentIndex: index, content: t.text, partial: partial))

            case .toolCall(let call):
                partial.content.append(.toolCall(ToolCall(id: call.id, name: call.name, arguments: .object([:]))))
                stream.push(.toolCallStart(contentIndex: index, partial: partial))
                let argsJSON = (try? JSONValueEncoder.encode(call.arguments)) ?? "{}"
                for chunk in splitByTokenSize(argsJSON, min: minTokenSize, max: maxTokenSize) {
                    if cancellation?.isCancelled == true {
                        let aborted = abortedMessage(from: partial)
                        stream.push(.error(reason: .aborted, error: aborted))
                        stream.end(aborted)
                        return
                    }
                    stream.push(.toolCallDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                partial.content[index] = .toolCall(call)
                stream.push(.toolCallEnd(contentIndex: index, toolCall: call, partial: partial))
            }
        }

        if message.stopReason == .error || message.stopReason == .aborted {
            stream.push(.error(reason: message.stopReason, error: message))
            stream.end(message)
            return
        }
        stream.push(.done(reason: message.stopReason, message: message))
        stream.end(message)
    }

    static func streamDeltas(
        to stream: AssistantMessageStream,
        message: AssistantMessage,
        minTokenSize: Int,
        maxTokenSize: Int,
        tokensPerSecond: Double?,
        cancellation: CancellationHandle?
    ) async {
        var partial = message
        partial.content = []

        if cancellation?.isCancelled == true {
            let aborted = abortedMessage(from: partial)
            stream.push(.error(reason: .aborted, error: aborted))
            stream.end(aborted)
            return
        }

        stream.push(.start(partial: partial))

        for (index, block) in message.content.enumerated() {
            if cancellation?.isCancelled == true {
                let aborted = abortedMessage(from: partial)
                stream.push(.error(reason: .aborted, error: aborted))
                stream.end(aborted)
                return
            }
            switch block {
            case .thinking(let t):
                partial.content.append(.thinking(ThinkingContent(thinking: "")))
                stream.push(.thinkingStart(contentIndex: index, partial: partial))
                for chunk in splitByTokenSize(t.thinking, min: minTokenSize, max: maxTokenSize) {
                    await scheduleChunk(chunk, tokensPerSecond: tokensPerSecond)
                    if cancellation?.isCancelled == true {
                        let aborted = abortedMessage(from: partial)
                        stream.push(.error(reason: .aborted, error: aborted))
                        stream.end(aborted)
                        return
                    }
                    if case .thinking(var current) = partial.content[index] {
                        current.thinking += chunk
                        partial.content[index] = .thinking(current)
                    }
                    stream.push(.thinkingDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                stream.push(.thinkingEnd(contentIndex: index, content: t.thinking, partial: partial))

            case .text(let t):
                partial.content.append(.text(TextContent(text: "")))
                stream.push(.textStart(contentIndex: index, partial: partial))
                for chunk in splitByTokenSize(t.text, min: minTokenSize, max: maxTokenSize) {
                    await scheduleChunk(chunk, tokensPerSecond: tokensPerSecond)
                    if cancellation?.isCancelled == true {
                        let aborted = abortedMessage(from: partial)
                        stream.push(.error(reason: .aborted, error: aborted))
                        stream.end(aborted)
                        return
                    }
                    if case .text(var current) = partial.content[index] {
                        current.text += chunk
                        partial.content[index] = .text(current)
                    }
                    stream.push(.textDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                stream.push(.textEnd(contentIndex: index, content: t.text, partial: partial))

            case .toolCall(let call):
                partial.content.append(.toolCall(ToolCall(id: call.id, name: call.name, arguments: .object([:]))))
                stream.push(.toolCallStart(contentIndex: index, partial: partial))
                let argsJSON = (try? JSONValueEncoder.encode(call.arguments)) ?? "{}"
                for chunk in splitByTokenSize(argsJSON, min: minTokenSize, max: maxTokenSize) {
                    await scheduleChunk(chunk, tokensPerSecond: tokensPerSecond)
                    if cancellation?.isCancelled == true {
                        let aborted = abortedMessage(from: partial)
                        stream.push(.error(reason: .aborted, error: aborted))
                        stream.end(aborted)
                        return
                    }
                    stream.push(.toolCallDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                partial.content[index] = .toolCall(call)
                stream.push(.toolCallEnd(contentIndex: index, toolCall: call, partial: partial))
            }
        }

        if message.stopReason == .error || message.stopReason == .aborted {
            stream.push(.error(reason: message.stopReason, error: message))
            stream.end(message)
            return
        }
        stream.push(.done(reason: message.stopReason, message: message))
        stream.end(message)
    }

    // MARK: Helpers

    static func estimateTokens(_ text: String) -> Int {
        Int((Double(text.utf8.count) / 4.0).rounded(.up))
    }

    static func randomId(prefix: String) -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let suffix = String(UInt64.random(in: 0..<UInt64.max), radix: 36)
        return "\(prefix):\(now):\(suffix)"
    }

    static func abortedMessage(from partial: AssistantMessage) -> AssistantMessage {
        var m = partial
        m.stopReason = .aborted
        m.errorMessage = "Request was aborted"
        m.timestamp = Timestamp.now()
        return m
    }

    static func makeErrorMessage(
        reason: String, api: String, provider: String, modelId: String
    ) -> AssistantMessage {
        AssistantMessage(
            content: [],
            api: api,
            provider: provider,
            model: modelId,
            usage: defaultUsage,
            stopReason: .error,
            errorMessage: reason,
            timestamp: Timestamp.now()
        )
    }

    static func clone(
        _ message: AssistantMessage, api: String, provider: String, modelId: String
    ) -> AssistantMessage {
        var m = message
        m.api = api
        m.provider = provider
        m.model = modelId
        if m.timestamp == 0 { m.timestamp = Timestamp.now() }
        return m
    }

    static func estimateUsage(
        message: AssistantMessage,
        context: Context,
        options: StreamOptions?,
        cached: @Sendable (String) -> String?,
        setCached: @Sendable (String, String) -> Void
    ) -> AssistantMessage {
        let prompt = serializeContext(context)
        let promptTokens = estimateTokens(prompt)
        let outputTokens = estimateTokens(assistantContentToText(message.content))
        var input = promptTokens
        var cacheRead = 0
        var cacheWrite = 0
        if let sessionId = options?.sessionId, options?.cacheRetention != CacheRetention.none {
            if let previous = cached(sessionId) {
                let shared = commonPrefixLength(previous, prompt)
                cacheRead = estimateTokens(String(previous.prefix(shared)))
                cacheWrite = estimateTokens(String(prompt.dropFirst(shared)))
                input = max(0, promptTokens - cacheRead)
            } else {
                cacheWrite = promptTokens
            }
            setCached(prompt, sessionId)
        }
        var m = message
        m.usage = Usage(
            input: input,
            output: outputTokens,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            totalTokens: input + outputTokens + cacheRead + cacheWrite,
            cost: Cost()
        )
        return m
    }

    static func serializeContext(_ context: Context) -> String {
        var parts: [String] = []
        if let p = context.systemPrompt { parts.append("system:\(p)") }
        for message in context.messages {
            switch message {
            case .user(let u):
                parts.append("user:\(userContentToText(u.content))")
            case .assistant(let a):
                parts.append("assistant:\(assistantContentToText(a.content))")
            case .toolResult(let t):
                parts.append("toolResult:\(toolResultToText(t))")
            }
        }
        if let tools = context.tools, !tools.isEmpty {
            if let encoded = try? JSONValueEncoder.encode(tools) {
                parts.append("tools:\(encoded)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    static func userContentToText(_ blocks: [UserBlock]) -> String {
        blocks.map { block in
            switch block {
            case .text(let t): return t.text
            case .image(let i): return "[image:\(i.mimeType):\(i.data.utf8.count)]"
            }
        }.joined(separator: "\n")
    }

    static func assistantContentToText(_ blocks: [AssistantBlock]) -> String {
        blocks.map { block in
            switch block {
            case .text(let t): return t.text
            case .thinking(let th): return th.thinking
            case .toolCall(let tc):
                let encoded = (try? JSONValueEncoder.encode(tc.arguments)) ?? "{}"
                return "\(tc.name):\(encoded)"
            }
        }.joined(separator: "\n")
    }

    static func toolResultToText(_ message: ToolResultMessage) -> String {
        var parts: [String] = [message.toolName]
        for block in message.content {
            switch block {
            case .text(let t): parts.append(t.text)
            case .image(let i): parts.append("[image:\(i.mimeType):\(i.data.utf8.count)]")
            }
        }
        return parts.joined(separator: "\n")
    }

    static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        let ai = Array(a)
        let bi = Array(b)
        let len = min(ai.count, bi.count)
        var i = 0
        while i < len && ai[i] == bi[i] { i += 1 }
        return i
    }

    static func splitByTokenSize(_ text: String, min: Int, max: Int) -> [String] {
        guard !text.isEmpty else { return [""] }
        var chunks: [String] = []
        var remaining = Substring(text)
        while !remaining.isEmpty {
            let tokenSize = min + Int.random(in: 0...Swift.max(0, max - min))
            let charSize = Swift.max(1, tokenSize * 4)
            let end = remaining.index(remaining.startIndex, offsetBy: Swift.min(charSize, remaining.count))
            chunks.append(String(remaining[remaining.startIndex..<end]))
            remaining = remaining[end...]
        }
        return chunks.isEmpty ? [""] : chunks
    }

    static func scheduleChunk(_ chunk: String, tokensPerSecond: Double?) async {
        guard let rate = tokensPerSecond, rate > 0 else { return }
        let delayMs = Double(estimateTokens(chunk)) / rate * 1000
        try? await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
    }
}

// Small JSON encoder helper to serialize JSONValue / Tool arrays deterministically.
enum JSONValueEncoder {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
