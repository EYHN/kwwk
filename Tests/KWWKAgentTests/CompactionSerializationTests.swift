import Foundation
import KWWKAI
import Testing
@testable import KWWKAgent

@Suite("Compaction transcript serialization")
struct CompactionSerializationTests {
    @Test("preserves tool identifiers, arguments, errors, and details")
    func preservesToolStructure() {
        let messages: [Message] = [
            .assistant(AssistantMessage(
                content: [
                    .thinking(ThinkingContent(thinking: "checked the invariant")),
                    .toolCall(ToolCall(
                        id: "same-name-2",
                        name: "read",
                        arguments: .object(["path": .string("/tmp/a\"b.swift")])
                    )),
                ],
                api: "faux",
                provider: "faux",
                model: "faux",
                stopReason: .toolUse
            )),
            .toolResult(ToolResultMessage(
                toolCallId: "same-name-2",
                toolName: "read",
                content: [.text(TextContent(text: "permission denied"))],
                details: .object(["errno": .int(13)]),
                isError: true
            )),
        ]

        let serialized = CompactionTranscriptSerializer.serialize(messages)

        #expect(serialized.contains(#""id":"same-name-2""#))
        #expect(serialized.contains(#""name":"read""#))
        #expect(serialized.contains(#"/tmp/a\\\"b.swift"#))
        #expect(serialized.contains(#""toolCallId":"same-name-2""#))
        #expect(serialized.contains(#""isError":true"#))
        #expect(serialized.contains(#"errno"#))
        #expect(serialized.contains("checked the invariant"))
    }

    @Test("recursively removes child session ids from tool result details")
    func redactsChildSessionIdsFromToolDetails() {
        let message = Message.toolResult(ToolResultMessage(
            toolCallId: "agent-result",
            toolName: "agent",
            content: [.text(TextContent(text: "completed"))],
            details: .object([
                "child_session_id": .string("top-secret-child"),
                "task_id": .string("bg_visible"),
                "nested": .object([
                    "childSessionId": .string("nested-secret-child"),
                    "subagent_type": .string("explore"),
                ]),
                "items": .array([
                    .object([
                        "child_session_id": .string("array-secret-child"),
                        "status": .string("completed"),
                    ]),
                    .object([
                        "childSessionId": .string("array-camel-secret-child"),
                        "result": .string("kept-result"),
                    ]),
                ]),
            ])
        ))

        let serialized = CompactionTranscriptSerializer.serialize([message])

        #expect(!serialized.contains("child_session_id"))
        #expect(!serialized.contains("childSessionId"))
        #expect(!serialized.contains("top-secret-child"))
        #expect(!serialized.contains("nested-secret-child"))
        #expect(!serialized.contains("array-secret-child"))
        #expect(!serialized.contains("array-camel-secret-child"))
        #expect(serialized.contains("bg_visible"))
        #expect(serialized.contains("subagent_type"))
        #expect(serialized.contains("explore"))
        #expect(serialized.contains("completed"))
        #expect(serialized.contains("kept-result"))
    }

    @Test("bounds large tool output while retaining both ends")
    func truncatesToolOutputHeadAndTail() {
        let payload = "HEAD-" + String(repeating: "x", count: 1_000) + "-TAIL"
        let message = Message.toolResult(ToolResultMessage(
            toolCallId: "call-1",
            toolName: "bash",
            content: [.text(TextContent(text: payload))]
        ))

        let serialized = CompactionTranscriptSerializer.serialize(
            [message],
            limits: .init(toolResultBytes: 160)
        )

        #expect(serialized.contains("HEAD-"))
        #expect(serialized.contains("-TAIL"))
        #expect(serialized.contains("middle elided"))
        #expect(serialized.utf8.count < payload.utf8.count)
    }

    @Test("bounds ordinary message text while retaining both ends")
    func truncatesMessageTextHeadAndTail() {
        let payload = "REQUEST-HEAD-" + String(repeating: "中", count: 500) + "-REQUEST-TAIL"
        let serialized = CompactionTranscriptSerializer.serialize(
            [.user(UserMessage(text: payload))],
            limits: .init(messageTextBytes: 180)
        )

        #expect(serialized.contains("REQUEST-HEAD-"))
        #expect(serialized.contains("-REQUEST-TAIL"))
        #expect(serialized.contains("middle elided"))
    }

    @Test("globally bounds transcripts with many individually bounded blocks")
    func globallyBoundsTranscript() {
        let calls = (0..<80).map { index in
            AssistantBlock.toolCall(ToolCall(
                id: "call-\(index)",
                name: "read",
                arguments: .object([
                    "path": .string("/tmp/\(index)-" + String(repeating: "x", count: 500)),
                ])
            ))
        }
        let message = Message.assistant(AssistantMessage(
            content: calls,
            api: "faux",
            provider: "faux",
            model: "faux",
            stopReason: .toolUse
        ))

        let serialized = CompactionTranscriptSerializer.serialize(
            [message],
            maxTokens: 120
        )

        #expect(ContextTokenEstimator.estimate(text: serialized) <= 120)
        #expect(serialized.contains("transcriptElision"))
    }

    @Test("summary requests reserve output space inside the model window")
    func summaryRequestFitsModelWindow() async throws {
        let model = Model(
            id: "summary-budget",
            api: "faux",
            provider: "faux",
            contextWindow: 1_200,
            maxTokens: 200
        )
        let capture = SummaryBudgetCapture()
        let messages = [Message.user(UserMessage(
            text: String(repeating: "large transcript payload ", count: 2_000)
        ))]

        _ = try await AgentContextCompactor.summarizeTranscript(
            messages: messages,
            model: model,
            sessionId: "summary-budget",
            config: AgentContextCompactionConfig(summaryMaxTokens: 100),
            streamFn: { model, context, options in
                await capture.record(
                    context: context,
                    maxTokens: options?.maxTokens,
                    sessionId: options?.sessionId
                )
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(AssistantMessage(
                    content: [.text(TextContent(text: "## Goal\nbounded"))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id
                ))
                return pair.stream
            }
        )

        let request = try #require(await capture.snapshot())
        let requestContext = AgentContext(
            systemPrompt: request.context.systemPrompt ?? "",
            messages: request.context.messages,
            tools: []
        )
        let inputTokens = ContextTokenEstimator.estimate(context: requestContext).locallyEstimated
        #expect(request.maxTokens == 100)
        #expect(inputTokens + request.maxTokens <= model.contextWindow)
        #expect(contextText(request.context).contains("transcriptElision"))
        #expect(request.sessionId?.hasPrefix("summary-budget::kwwk-compaction-summary::") == true)
        #expect(request.sessionId != "summary-budget")
    }

    @Test("default summary generation leaves maxTokens automatic while reserving model headroom")
    func defaultSummaryMaxTokensIsAutomatic() async throws {
        let model = Model(
            id: "summary-auto-budget",
            api: "faux",
            provider: "faux",
            contextWindow: 1_200,
            maxTokens: 200
        )
        let capture = SummaryBudgetCapture()
        let messages = [Message.user(UserMessage(
            text: String(repeating: "large automatic transcript ", count: 2_000)
        ))]

        _ = try await AgentContextCompactor.summarizeTranscript(
            messages: messages,
            model: model,
            sessionId: "summary-auto-budget",
            streamFn: { model, context, options in
                await capture.record(
                    context: context,
                    maxTokens: options?.maxTokens,
                    sessionId: options?.sessionId
                )
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(AssistantMessage(
                    content: [.text(TextContent(text: "## Goal\nautomatic"))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id
                ))
                return pair.stream
            }
        )

        let request = try #require(await capture.snapshot())
        let requestContext = AgentContext(
            systemPrompt: request.context.systemPrompt ?? "",
            messages: request.context.messages,
            tools: []
        )
        let inputTokens = ContextTokenEstimator.estimate(context: requestContext).locallyEstimated
        #expect(request.maxTokens == 0, "nil stream option is captured as the automatic sentinel")
        #expect(inputTokens + model.maxTokens <= model.contextWindow)
        #expect(contextText(request.context).contains("transcriptElision"))
    }

    @Test("an explicit summary cap works with missing non-omission model metadata")
    func explicitSummaryCapOverridesMissingModelDefault() async throws {
        let model = Model(
            id: "summary-explicit-without-default",
            api: "faux",
            provider: "custom",
            contextWindow: 10_000,
            maxTokens: 0
        )
        let capture = SummaryBudgetCapture()

        _ = try await AgentContextCompactor.summarizeTranscript(
            messages: [.user(UserMessage(text: "summarize me"))],
            model: model,
            sessionId: "summary-explicit-without-default",
            config: AgentContextCompactionConfig(summaryMaxTokens: 4_096),
            streamFn: { model, context, options in
                await capture.record(
                    context: context,
                    maxTokens: options?.maxTokens,
                    sessionId: options?.sessionId
                )
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(AssistantMessage(
                    content: [.text(TextContent(text: "summary"))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id
                ))
                return pair.stream
            }
        )

        #expect(try #require(await capture.snapshot()).maxTokens == 4_096)
    }

    @Test("summary provider sessions are isolated from live state and closed")
    func summaryProviderSessionLifecycle() async throws {
        let identifier = UUID().uuidString
        let api = "summary-lifecycle-\(identifier)"
        let sourceId = "summary-lifecycle-source-\(identifier)"
        let provider = SummaryLifecycleProvider(api: api)
        await APIRegistry.shared.register(provider, sourceId: sourceId)
        defer { Task { await APIRegistry.shared.unregisterSource(sourceId) } }
        let model = Model(
            id: "summary-lifecycle-model",
            api: api,
            provider: "summary-lifecycle-provider",
            contextWindow: 4_000,
            maxTokens: 200
        )

        _ = try await AgentContextCompactor.summarizeTranscript(
            messages: [.user(UserMessage(text: "summarize me"))],
            model: model,
            sessionId: "live-agent-session",
            config: AgentContextCompactionConfig(summaryMaxTokens: 100),
            authResolver: { _, sessionId in
                provider.recordAuthSession(sessionId)
                return nil
            }
        )

        let snapshot = provider.snapshot()
        let streamedSession = try #require(snapshot.streamedSessions.first)
        #expect(streamedSession != "live-agent-session")
        #expect(streamedSession.hasPrefix("live-agent-session::kwwk-compaction-summary::"))
        #expect(snapshot.authSessions == ["live-agent-session"])
        #expect(snapshot.closedSessions.contains(streamedSession))
        await APIRegistry.shared.unregisterSource(sourceId)
    }

    @Test("summary chunking is ordered and keeps tool call/result groups atomic")
    func chunkingPreservesOrderAndToolPairs() {
        let call = ToolCall(id: "paired", name: "read", arguments: ["path": "/tmp/a"])
        let messages: [Message] = [
            .user(UserMessage(text: String(repeating: "a", count: 180))),
            .assistant(AssistantMessage(
                content: [.toolCall(call)],
                api: "faux", provider: "faux", model: "faux", stopReason: .toolUse
            )),
            .toolResult(ToolResultMessage(
                toolCallId: call.id,
                toolName: call.name,
                content: [.text(TextContent(text: String(repeating: "b", count: 180)))]
            )),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: String(repeating: "c", count: 180)))],
                api: "faux", provider: "faux", model: "faux"
            )),
            .user(UserMessage(text: String(repeating: "d", count: 180))),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: String(repeating: "e", count: 180)))],
                api: "faux", provider: "faux", model: "faux"
            )),
        ]

        let chunks = CompactionSummaryChunker.chunks(
            messages,
            maxTokens: 100,
            limits: .init()
        )

        #expect(chunks.count > 1)
        #expect(chunks.flatMap { $0 } == messages)
        let pairedChunk = chunks.first(where: { $0.contains(messages[2]) })
        #expect(pairedChunk?.contains(messages[1]) == true)
        #expect(chunks.allSatisfy { chunk in
            guard let first = chunk.first else { return false }
            if case .toolResult = first { return false }
            return true
        })
    }

    @Test("oversized parallel tool batches expose every call and result to summary requests")
    func parallelToolBatchSummaryCoverage() async throws {
        let model = Model(
            id: "parallel-summary-coverage",
            api: "faux",
            provider: "faux",
            contextWindow: 1_200,
            maxTokens: 200
        )
        let calls = (0..<12).map { index in
            ToolCall(
                id: "parallel-call-\(index)",
                name: "read_\(index)",
                arguments: .object([
                    "path": .string("/tmp/unique-\(index)-" + String(repeating: "x", count: 2_000)),
                ])
            )
        }
        let assistant = Message.assistant(AssistantMessage(
            content: calls.map(AssistantBlock.toolCall),
            api: model.api,
            provider: model.provider,
            model: model.id,
            stopReason: .toolUse
        ))
        var results = calls.enumerated().map { index, call in
            Message.toolResult(ToolResultMessage(
                toolCallId: call.id,
                toolName: call.name,
                content: [.text(TextContent(
                    text: "RESULT-\(index)-" + String(repeating: "y", count: 2_000)
                ))],
                isError: index == 7
            ))
        }
        results.append(.toolResult(ToolResultMessage(
            toolCallId: "orphan-result",
            toolName: "orphan_tool",
            content: [.text(TextContent(text: String(repeating: "orphan", count: 500)))],
            isError: true
        )))
        let config = AgentContextCompactionConfig(summaryMaxTokens: 100)
        let chunks = CompactionSummaryChunker.chunks(
            [assistant] + results,
            maxTokens: 180,
            limits: config.transcriptLimits
        )
        #expect(chunks.count > 1)

        let requests = SummaryRequestLog()
        for chunk in chunks {
            _ = try await AgentContextCompactor.summarizeTranscript(
                messages: chunk,
                model: model,
                sessionId: "parallel-summary",
                config: config,
                streamFn: { model, context, _ in
                    await requests.append(contextText(context))
                    let pair = AssistantMessageStream.makeStream()
                    pair.continuation.end(AssistantMessage(
                        content: [.text(TextContent(text: "summary"))],
                        api: model.api,
                        provider: model.provider,
                        model: model.id
                    ))
                    return pair.stream
                }
            )
        }

        let transcript = await requests.joined()
        for (index, call) in calls.enumerated() {
            #expect(transcript.contains(#""id":"\#(call.id)""#))
            #expect(transcript.contains(#""toolCallId":"\#(call.id)""#))
            #expect(transcript.contains("read_\(index)"))
        }
        #expect(transcript.contains(#""isError":true"#))
        #expect(transcript.contains(#""toolCallId":"orphan-result""#))
    }

    @Test("large parallel batches preserve call order with indexed result lookup")
    func largeParallelBatchUsesIndexedResultLookup() {
        let count = 2_048
        let calls = (0..<count).map { index in
            ToolCall(
                id: "indexed-call-\(index)",
                name: "read",
                arguments: .object(["path": .string("/tmp/\(index)")])
            )
        }
        let assistant = Message.assistant(AssistantMessage(
            content: [.text(TextContent(text: "parallel narrative"))]
                + calls.map(AssistantBlock.toolCall),
            api: "faux",
            provider: "faux",
            model: "faux",
            stopReason: .toolUse
        ))
        let orphanIds = ["orphan-first", "orphan-last"]
        var results = calls.reversed().map { call in
            Message.toolResult(ToolResultMessage(
                toolCallId: call.id,
                toolName: call.name,
                content: [.text(TextContent(text: call.id))]
            ))
        }
        results.insert(.toolResult(ToolResultMessage(
            toolCallId: orphanIds[0],
            toolName: "orphan",
            content: [.text(TextContent(text: orphanIds[0]))]
        )), at: 0)
        results.append(.toolResult(ToolResultMessage(
            toolCallId: orphanIds[1],
            toolName: "orphan",
            content: [.text(TextContent(text: orphanIds[1]))]
        )))

        let projected = CompactionSummaryChunker.chunks(
            [assistant] + results,
            maxTokens: 32,
            limits: .init()
        ).flatMap { $0 }
        let projectedCallIds = projected.compactMap { message -> String? in
            guard case .assistant(let assistant) = message else { return nil }
            return assistant.content.compactMap { block -> String? in
                guard case .toolCall(let call) = block else { return nil }
                return call.id
            }.first
        }
        let projectedResultIds = projected.compactMap { message -> String? in
            guard case .toolResult(let result) = message else { return nil }
            return result.toolCallId
        }

        #expect(projectedCallIds.count == count)
        #expect(projectedResultIds.count == count + orphanIds.count)
        for (index, id) in projectedCallIds.enumerated() {
            #expect(id == calls[index].id)
        }
        for (index, id) in projectedResultIds.prefix(count).enumerated() {
            #expect(id == calls[index].id)
        }
        #expect(Array(projectedResultIds.suffix(orphanIds.count)) == orphanIds)
    }

    @Test("multi-chunk summaries replan around the growing accumulator without dropping turns")
    func multiChunkSummaryReplansAroundAccumulator() async throws {
        let model = Model(
            id: "adaptive-summary-budget",
            api: "faux",
            provider: "faux",
            contextWindow: 1_600,
            maxTokens: 300
        )
        let markers = (0..<12).map { "ADAPTIVE-TURN-\($0)" }
        let messages = markers.flatMap { marker -> [Message] in
            [
                .user(UserMessage(
                    text: "\(marker)-USER " + String(repeating: "request payload ", count: 24)
                )),
                .assistant(AssistantMessage(
                    content: [.text(TextContent(
                        text: "\(marker)-ASSISTANT " + String(repeating: "response payload ", count: 24)
                    ))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id
                )),
            ]
        }
        let requests = SummaryRequestLog()
        let longAccumulator = "## Goal\n" + String(repeating: "durable accumulated state ", count: 50)

        let result = await AgentContextCompactor.compactContext(
            context: AgentContext(systemPrompt: "", messages: messages, tools: []),
            model: model,
            sessionId: "adaptive-summary-budget",
            config: AgentContextCompactionConfig(
                minMessages: 1,
                summaryWordTarget: 250,
                keepRecentTokens: 1
            ),
            streamFn: { model, context, _ in
                await requests.append(contextText(context))
                let pair = AssistantMessageStream.makeStream()
                pair.continuation.end(AssistantMessage(
                    content: [.text(TextContent(text: longAccumulator))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id
                ))
                return pair.stream
            }
        )

        guard case .success = result else {
            Issue.record("expected adaptive multi-chunk compaction to succeed")
            return
        }
        let snapshot = await requests.snapshot()
        #expect(snapshot.count > 1)
        #expect(snapshot.allSatisfy { !$0.contains("transcriptElision") })
        let transcript = snapshot.joined(separator: "\n")
        for marker in markers.dropLast() {
            #expect(transcript.contains("\(marker)-USER"))
            #expect(transcript.contains("\(marker)-ASSISTANT"))
        }
    }
}

private actor SummaryBudgetCapture {
    private var request: (context: Context, maxTokens: Int, sessionId: String?)?

    func record(context: Context, maxTokens: Int?, sessionId: String?) {
        request = (context, maxTokens ?? 0, sessionId)
    }

    func snapshot() -> (context: Context, maxTokens: Int, sessionId: String?)? {
        request
    }
}

private actor SummaryRequestLog {
    private var requests: [String] = []

    func append(_ request: String) {
        requests.append(request)
    }

    func joined() -> String {
        requests.joined(separator: "\n")
    }

    func snapshot() -> [String] {
        requests
    }
}

private final class SummaryLifecycleProvider: APIProvider, APIProviderSessionLifecycle, @unchecked Sendable {
    let api: String
    private let lock = NSLock()
    private var authSessions: [String] = []
    private var streamedSessions: [String] = []
    private var closedSessions: [String] = []

    init(api: String) {
        self.api = api
    }

    func recordAuthSession(_ sessionId: String?) {
        guard let sessionId else { return }
        lock.withLock { authSessions.append(sessionId) }
    }

    func stream(
        model: Model,
        context: Context,
        options: StreamOptions?
    ) -> AssistantMessageStream {
        if let sessionId = options?.sessionId {
            lock.withLock { streamedSessions.append(sessionId) }
        }
        let pair = AssistantMessageStream.makeStream()
        pair.continuation.end(AssistantMessage(
            content: [.text(TextContent(text: "summary"))],
            api: model.api,
            provider: model.provider,
            model: model.id
        ))
        return pair.stream
    }

    func closeSession(sessionId: String) async {
        lock.withLock { closedSessions.append(sessionId) }
    }

    func snapshot() -> (
        authSessions: [String],
        streamedSessions: [String],
        closedSessions: [String]
    ) {
        lock.withLock { (authSessions, streamedSessions, closedSessions) }
    }
}

private func contextText(_ context: Context) -> String {
    context.messages.compactMap { message -> String? in
        guard case .user(let user) = message else { return nil }
        return user.content.compactMap { block -> String? in
            guard case .text(let text) = block else { return nil }
            return text.text
        }.joined(separator: "\n")
    }.joined(separator: "\n")
}
