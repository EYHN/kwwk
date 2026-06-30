import Foundation
import KWWKAI

public let agentCompactMinMessages = 4

public struct AgentContextUsage: Equatable, Sendable {
    public let tokens: Int
    public let window: Int

    public var ratio: Double {
        window > 0 ? Double(tokens) / Double(window) : 0
    }

    public init(tokens: Int, window: Int) {
        self.tokens = tokens
        self.window = window
    }
}

public struct AgentContextCompactionConfig: Sendable {
    public var minMessages: Int
    public var toolOutputCharacterLimit: Int
    public var summaryWordTarget: Int

    public init(
        minMessages: Int = agentCompactMinMessages,
        toolOutputCharacterLimit: Int = 500,
        summaryWordTarget: Int = 400
    ) {
        self.minMessages = minMessages
        self.toolOutputCharacterLimit = toolOutputCharacterLimit
        self.summaryWordTarget = summaryWordTarget
    }
}

public enum AgentContextCompactionOutcome: Sendable, Equatable {
    case compacted(messagesCompacted: Int, hasRunningTasksLedger: Bool)
    case refusedAgentBusy
    case refusedTooFewMessages(count: Int)
    case failed(String)
}

public enum AgentContextCompactor {
    public static func currentUsage(messages: [Message], model: Model) -> AgentContextUsage {
        let usage = messages.reversed().compactMap { message -> Usage? in
            if case .assistant(let assistant) = message {
                return assistant.usage
            }
            return nil
        }.first

        let tokens = (usage?.input ?? 0)
            + (usage?.output ?? 0)
            + (usage?.cacheRead ?? 0)
            + (usage?.cacheWrite ?? 0)
        return AgentContextUsage(tokens: tokens, window: model.contextWindow)
    }

    public static func shouldCompact(
        messages: [Message],
        model: Model,
        threshold: Double?
    ) -> Bool {
        guard let threshold, threshold > 0 else { return false }
        let usage = currentUsage(messages: messages, model: model)
        guard usage.window > 0 else { return false }
        return usage.ratio >= threshold
    }

    @discardableResult
    public static func compactAgent(
        agent: Agent,
        backgroundManager: BackgroundTaskManager? = nil,
        sessionId: String?,
        config: AgentContextCompactionConfig = .init(),
        ignoreStreaming: Bool = false,
        cancellation: CancellationHandle? = nil
    ) async -> AgentContextCompactionOutcome {
        if !ignoreStreaming && agent.state.isStreaming {
            return .refusedAgentBusy
        }

        let snapshot = agent.state.messages
        let result = await compactMessages(
            messages: snapshot,
            model: agent.state.model,
            backgroundManager: backgroundManager,
            sessionId: sessionId,
            config: config,
            authResolver: agent.authResolver,
            transformContext: agent.transformContext,
            convertToLlm: agent.convertToLlm,
            streamFn: { model, context, options in
                try await agent.streamForCompaction(
                    model: model,
                    context: context,
                    options: options
                )
            },
            cancellation: cancellation
        )

        switch result {
        case .success(let replacement):
            agent.state.messages = replacement.messages
            return .compacted(
                messagesCompacted: replacement.messagesCompacted,
                hasRunningTasksLedger: replacement.hasRunningTasksLedger
            )
        case .failure(let failure):
            return failure.outcome
        }
    }

    public static func compactInlineIfNeeded(
        agent: Agent,
        context: AgentContext,
        threshold: Double?,
        backgroundManager: BackgroundTaskManager? = nil,
        sessionId: String?,
        config: AgentContextCompactionConfig = .init(),
        cancellation: CancellationHandle? = nil
    ) async -> AgentContext? {
        guard shouldCompact(messages: context.messages, model: agent.state.model, threshold: threshold) else {
            return nil
        }

        agent.state.messages = context.messages
        let outcome = await compactAgent(
            agent: agent,
            backgroundManager: backgroundManager,
            sessionId: sessionId,
            config: config,
            ignoreStreaming: true,
            cancellation: cancellation
        )
        guard case .compacted = outcome else {
            return nil
        }

        var replaced = context
        replaced.messages = agent.state.messages
        return replaced
    }

    public static func compactMessages(
        messages: [Message],
        model: Model,
        backgroundManager: BackgroundTaskManager? = nil,
        sessionId: String?,
        config: AgentContextCompactionConfig = .init(),
        authResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)? = nil,
        transformContext: TransformContextHook? = nil,
        convertToLlm: ConvertToLlmHook? = nil,
        streamFn: StreamFn? = nil,
        cancellation: CancellationHandle? = nil
    ) async -> Result<AgentContextCompactionResult, AgentContextCompactionFailure> {
        guard messages.count >= config.minMessages else {
            return .failure(.tooFewMessages(count: messages.count))
        }

        let runningTasks = await backgroundManager?
            .runningTasksSummary(sessionId: sessionId)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        do {
            var summaryMessages = messages
            if let transformContext {
                summaryMessages = await transformContext(summaryMessages, cancellation)
            }
            if let convertToLlm {
                summaryMessages = await convertToLlm(summaryMessages)
            }
            let summary = try await summarizeTranscript(
                messages: summaryMessages,
                model: model,
                sessionId: sessionId,
                config: config,
                authResolver: authResolver,
                streamFn: streamFn,
                cancellation: cancellation
            )
            var body = """
            <previous-session-summary>
            \(summary)
            </previous-session-summary>
            """
            if !runningTasks.isEmpty {
                body += "\n\n<running-background-tasks>\n\(runningTasks)\n</running-background-tasks>"
            }
            let recap = Message.user(UserMessage(content: [.text(TextContent(text: body))]))
            return .success(AgentContextCompactionResult(
                messages: [recap],
                messagesCompacted: messages.count,
                hasRunningTasksLedger: !runningTasks.isEmpty
            ))
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return .failure(.failed(reason))
        }
    }

    public static func renderForSummary(
        _ messages: [Message],
        toolOutputCharacterLimit: Int = AgentContextCompactionConfig().toolOutputCharacterLimit
    ) -> String {
        messages.compactMap { message -> String? in
            switch message {
            case .user(let user):
                let text = user.content.compactMap { block -> String? in
                    switch block {
                    case .text(let text): return text.text
                    case .image(let image): return "[image: \(image.mimeType), \(image.data.count) base64 chars]"
                    }
                }.joined(separator: "\n")
                return text.isEmpty ? nil : "User:\n\(text)"

            case .assistant(let assistant):
                var parts: [String] = []
                for block in assistant.content {
                    switch block {
                    case .text(let text):
                        if !text.text.isEmpty { parts.append(text.text) }
                    case .toolCall(let toolCall):
                        parts.append("<tool-call name=\"\(toolCall.name)\" />")
                    case .thinking:
                        continue
                    }
                }
                return parts.isEmpty ? nil : "Assistant:\n\(parts.joined(separator: "\n"))"

            case .toolResult(let result):
                let text = result.content.compactMap { block -> String? in
                    switch block {
                    case .text(let text): return text.text
                    case .image(let image): return "[image: \(image.mimeType), \(image.data.count) base64 chars]"
                    }
                }.joined(separator: "\n")
                let capped = cappedText(text, limit: toolOutputCharacterLimit)
                return "Tool(\(result.toolName)):\n\(capped)"
            }
        }.joined(separator: "\n\n")
    }

    public static func summarizeTranscript(
        messages: [Message],
        model: Model,
        sessionId: String?,
        config: AgentContextCompactionConfig = .init(),
        authResolver: (@Sendable (Model, String?) async -> ResolvedProviderAuth?)? = nil,
        streamFn: StreamFn? = nil,
        cancellation: CancellationHandle? = nil
    ) async throws -> String {
        let transcript = renderForSummary(
            messages,
            toolOutputCharacterLimit: config.toolOutputCharacterLimit
        )

        let systemPrompt = """
        You are summarizing an agent conversation so it can be resumed with compressed context.

        Preserve:
        - the user's goal and any decisions already agreed on
        - concrete file paths, apps, windows, entities, and module names referenced
        - tool results that changed the plan or revealed important state
        - in-flight work, failing tests, open questions, and outstanding asks

        Omit:
        - pleasantries and rhetorical framing
        - verbose tool output unless a specific line is load-bearing
        - step-by-step reasoning; keep conclusions and facts

        Write for a future agent resuming the same session. Target under \(config.summaryWordTarget) words.
        """

        let userPrompt = """
        Conversation to summarize:

        \(transcript)
        """

        let context = Context(
            systemPrompt: systemPrompt,
            messages: [.user(UserMessage(content: [.text(TextContent(text: userPrompt))]))],
            tools: []
        )

        let resolvedAuth = await authResolver?(model, sessionId)
        var requestModel = model
        if let baseURL = resolvedAuth?.baseURL, !baseURL.isEmpty {
            requestModel.baseUrl = baseURL
        }
        let metadata: [String: JSONValue]? = {
            guard let authMetadata = resolvedAuth?.metadata, !authMetadata.isEmpty else { return nil }
            return authMetadata
        }()
        let options = StreamOptions(
            apiKey: resolvedAuth?.token,
            sessionId: sessionId,
            metadata: metadata,
            resolvedAuth: resolvedAuth,
            cancellation: cancellation
        )

        let requestStream = streamFn ?? { model, context, options in
            try await stream(model: model, context: context, options: options)
        }
        let response = try await requestStream(requestModel, context, options)
        let result = await response.result()

        if result.stopReason == .error {
            throw AgentContextCompactionError.summarizationFailed(result.errorMessage ?? "unknown")
        }
        let texts = result.content.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }
        let summary = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty {
            throw AgentContextCompactionError.emptySummary
        }
        return summary
    }

    private static func cappedText(_ text: String, limit: Int) -> String {
        guard limit >= 0, text.count > limit else {
            return text
        }
        return String(text.prefix(limit)) + "... [\(text.count - limit) chars elided]"
    }

    // MARK: - Shake (non-LLM tool-output trim)

    /// Default character ceiling for `shakeToolOutputs`. Tool results whose
    /// joined `.text` exceeds this are collapsed into a placeholder.
    public static let shakeToolOutputCharacterLimit = 1000

    /// Leading marker on a collapsed tool result. Used to keep
    /// `shakeToolOutputs` idempotent — a result already carrying this prefix
    /// is left alone so repeated `/shake` calls don't recount or re-elide.
    static let shakePlaceholderPrefix = "[tool result elided to reclaim context"

    /// Strip heavy tool-result output from a live transcript without any LLM
    /// call (unlike `compactMessages`, which summarizes via the model). Walks
    /// `messages`; for each `.toolResult` whose joined `.text` blocks exceed
    /// `limit`, the text is replaced by a single short placeholder. Every
    /// other field on the `ToolResultMessage` (toolName, toolCallId, isError,
    /// details, timestamp) is preserved, and `.image` blocks are kept — only
    /// the oversized text is collapsed.
    ///
    /// Idempotent: a result already collapsed by a previous pass (detected by
    /// `shakePlaceholderPrefix`) is skipped, so calling this repeatedly is a
    /// no-op after the first trim. Pure: no I/O, no model round-trip.
    ///
    /// Returns the rewritten messages and how many tool results were elided.
    public static func shakeToolOutputs(
        _ messages: [Message],
        keepingUnder limit: Int = shakeToolOutputCharacterLimit
    ) -> (messages: [Message], elidedCount: Int) {
        var elidedCount = 0
        let rewritten = messages.map { message -> Message in
            guard case .toolResult(var result) = message else { return message }
            // Idempotent: leave an already-collapsed result untouched.
            if isShakePlaceholder(result.content) { return message }

            let joined = result.content.compactMap { block -> String? in
                if case .text(let text) = block { return text.text }
                return nil
            }.joined(separator: "\n")
            guard joined.count > limit else { return message }

            // Collapse the bulky text into one placeholder block; carry any
            // images through unchanged (they don't hold the bulk).
            var rebuilt: [ToolResultBlock] = [
                .text(TextContent(text: "\(shakePlaceholderPrefix) — was \(joined.count) chars]"))
            ]
            for block in result.content {
                if case .image = block { rebuilt.append(block) }
            }
            result.content = rebuilt
            elidedCount += 1
            return .toolResult(result)
        }
        return (rewritten, elidedCount)
    }

    private static func isShakePlaceholder(_ content: [ToolResultBlock]) -> Bool {
        for block in content {
            if case .text(let text) = block, text.text.hasPrefix(shakePlaceholderPrefix) {
                return true
            }
        }
        return false
    }
}

public struct AgentContextCompactionResult: Sendable, Equatable {
    public let messages: [Message]
    public let messagesCompacted: Int
    public let hasRunningTasksLedger: Bool

    public init(messages: [Message], messagesCompacted: Int, hasRunningTasksLedger: Bool) {
        self.messages = messages
        self.messagesCompacted = messagesCompacted
        self.hasRunningTasksLedger = hasRunningTasksLedger
    }
}

public enum AgentContextCompactionFailure: Error, Sendable, Equatable {
    case tooFewMessages(count: Int)
    case failed(String)

    public var outcome: AgentContextCompactionOutcome {
        switch self {
        case .tooFewMessages(let count): return .refusedTooFewMessages(count: count)
        case .failed(let reason): return .failed(reason)
        }
    }
}

public enum AgentContextCompactionError: Error, LocalizedError {
    case summarizationFailed(String)
    case emptySummary

    public var errorDescription: String? {
        switch self {
        case .summarizationFailed(let reason): return "summarization failed: \(reason)"
        case .emptySummary: return "LLM returned an empty summary"
        }
    }
}
