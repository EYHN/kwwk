import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

@Suite("AgentLoop runtime policy")
struct AgentLoopPolicyTests {
    @Test("before-tool rewrites are revalidated before execution")
    func rewrittenArgumentsAreRevalidated() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxToolCall(
                        name: "typed",
                        arguments: ["value": .string("valid")],
                        id: "rewrite-invalid"
                    ),
                ],
                stopReason: .toolUse
            )),
            .message(fauxAssistantMessage("done")),
        ])

        let executions = ToolCallRecorder()
        let tool = AgentTool(
            name: "typed",
            label: "typed",
            description: "accepts one string",
            parameters: [
                "type": "object",
                "properties": ["value": ["type": "string"]],
                "required": ["value"],
            ],
            execute: { id, _, _, _ in
                await executions.record(id)
                return AgentToolResult(content: [.text(TextContent(text: "executed"))])
            }
        )
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), tools: [tool]),
            beforeToolCall: { _, _ in
                BeforeToolCallResult(modifiedArgs: ["value": .bool(true)])
            }
        ))

        try await agent.prompt("rewrite with the wrong type")

        #expect(await executions.snapshot().isEmpty)
        let result = toolResult(in: agent.state.messages, id: "rewrite-invalid")
        #expect(result?.isError == true)
        #expect(toolResultText(result).contains("$.value: expected string, got boolean"))
    }

    @Test("the fifth limited call is rejected in sequential and parallel batches")
    func perTurnLimitCoversNormalExecutionModes() async throws {
        for mode in [ToolExecutionMode.sequential, .parallel] {
            let faux = await registerFauxProvider()
            defer { faux.unregister() }
            let calls = (1...5).map { index in
                fauxToolCall(name: "limited", arguments: [:], id: "\(mode.rawValue)-\(index)")
            }
            faux.setResponses([
                .message(fauxAssistantMessage(blocks: calls, stopReason: .toolUse)),
                .message(fauxAssistantMessage("done")),
            ])

            let executions = ToolCallRecorder()
            var tool = AgentTool(
                name: "limited",
                label: "limited",
                description: "limited test tool",
                parameters: ["type": "object"],
                execute: { id, _, _, _ in
                    await executions.record(id)
                    return AgentToolResult(content: [.text(TextContent(text: id))])
                }
            )
            tool.turnLimitKey = "delegation"
            tool.maxCallsPerTurn = 4
            let agent = Agent(options: AgentOptions(
                initialState: AgentInitialState(model: faux.getModel(), tools: [tool]),
                toolExecution: mode
            ))

            try await agent.prompt("run five calls")

            #expect(await executions.snapshot().count == 4)
            let fifth = toolResult(in: agent.state.messages, id: "\(mode.rawValue)-5")
            #expect(fifth?.isError == true)
            #expect(toolResultText(fifth).contains("per-turn call limit of 4"))
            guard case .object(let details) = fifth?.details ?? .null else {
                Issue.record("expected structured turn-limit details for \(mode.rawValue)")
                continue
            }
            #expect(details["error"] == .string("turn_call_limit_exceeded"))
            #expect(details["limit_key"] == .string("delegation"))
            #expect(details["max_calls_per_turn"] == .int(4))
        }
    }

    @Test("duplicate tool-call ids reject every occurrence before execution")
    func duplicateToolCallIdsFailClosed() async throws {
        for mode in [ToolExecutionMode.sequential, .parallel] {
            let faux = await registerFauxProvider()
            defer { faux.unregister() }
            faux.setResponses([
                .message(fauxAssistantMessage(
                    blocks: [
                        fauxToolCall(name: "limited", arguments: [:], id: "duplicate"),
                        fauxToolCall(name: "limited", arguments: [:], id: "duplicate"),
                    ],
                    stopReason: .toolUse
                )),
                .message(fauxAssistantMessage("done")),
            ])
            let executions = ToolCallRecorder()
            var tool = AgentTool(
                name: "limited",
                label: "limited",
                description: "limited duplicate-id test tool",
                parameters: ["type": "object"],
                execute: { id, _, _, _ in
                    await executions.record(id)
                    return AgentToolResult(content: [.text(TextContent(text: id))])
                }
            )
            tool.turnLimitKey = "delegation"
            tool.maxCallsPerTurn = 1
            let agent = Agent(options: AgentOptions(
                initialState: AgentInitialState(model: faux.getModel(), tools: [tool]),
                toolExecution: mode
            ))

            try await agent.prompt("emit duplicate ids")

            #expect(await executions.snapshot().isEmpty)
            let duplicates = agent.state.messages.compactMap { message -> ToolResultMessage? in
                guard case .toolResult(let result) = message,
                      result.toolCallId == "duplicate" else { return nil }
                return result
            }
            #expect(duplicates.count == 2)
            #expect(duplicates.allSatisfy { $0.isError })
            #expect(duplicates.allSatisfy { result in
                guard case .object(let details) = result.details ?? .null else { return false }
                return details["error"] == .string("duplicate_tool_call_id")
            })
        }
    }

    @Test("Cursor retry preserves quota and repeated ids cannot execute twice")
    func cursorRetryPreservesTurnLimit() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let attempts = RetryAttemptCounter()
        let executions = ToolCallRecorder()
        let repeatedCalls = ["a", "b", "c", "d"].map {
            ToolCall(
                id: $0,
                name: "limited",
                arguments: [:],
                cursorExecResolved: true
            )
        }
        let newCall = ToolCall(
            id: "e",
            name: "limited",
            arguments: [:],
            cursorExecResolved: true
        )
        let streamFn: StreamFn = { model, _, options in
            guard let bridge = options?.cursorExecBridge else {
                throw AgentLoopPolicyTestError.missingCursorBridge
            }
            let attempt = await attempts.next()
            let calls = attempt == 1 ? repeatedCalls : repeatedCalls + [newCall]
            let failed = attempt == 1
            let message = AssistantMessage(
                content: calls.map(AssistantBlock.toolCall),
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: failed ? .error : .stop,
                errorMessage: failed ? "HTTP 503: retry this stream" : nil
            )
            let pair = AssistantMessageStream.makeStream()
            Task {
                pair.continuation.push(.start(partial: message))
                for call in calls {
                    _ = await bridge.execute(call)
                }
                pair.continuation.push(.done(reason: message.stopReason, message: message))
                pair.continuation.end(message)
            }
            return pair.stream
        }

        var tool = AgentTool(
            name: "limited",
            label: "limited",
            description: "limited Cursor test tool",
            parameters: ["type": "object"],
            execute: { id, _, _, _ in
                await executions.record(id)
                return AgentToolResult(content: [.text(TextContent(text: id))])
            }
        )
        tool.turnLimitKey = "delegation"
        tool.maxCallsPerTurn = 4
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel(), tools: [tool]),
            streamFn: streamFn
        ))
        agent.retryBaseDelayMs = 1

        try await agent.prompt("retry inline calls")

        #expect(await attempts.snapshot() == 2)
        #expect(await executions.snapshot() == ["a", "b", "c", "d"])
        let retained = agent.state.messages.compactMap { message -> ToolResultMessage? in
            guard case .toolResult(let result) = message else { return nil }
            return result
        }
        #expect(retained.count == 5)
        #expect(retained.allSatisfy { $0.isError })
        for repeatedId in ["a", "b", "c", "d"] {
            let result = retained.first { $0.toolCallId == repeatedId }
            guard case .object(let details) = result?.details ?? .null else {
                Issue.record("expected duplicate-id details for \(repeatedId)")
                continue
            }
            #expect(details["error"] == .string("duplicate_tool_call_id"))
        }
        let newResult = retained.first { $0.toolCallId == "e" }
        #expect(toolResultText(newResult).contains("per-turn call limit of 4"))
    }

    @Test("a blocking job poll mixed with another tool rejects the entire batch")
    func mixedBlockingPollBatchIsRejected() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxToolCall(
                        name: "job",
                        arguments: .object([
                            "poll": .array([.string("bg-does-not-need-to-exist")]),
                            "timeout_seconds": .int(600),
                        ]),
                        id: "mixed-poll"
                    ),
                    fauxToolCall(name: "slow", arguments: [:], id: "mixed-slow"),
                ],
                stopReason: .toolUse
            )),
            .message(fauxAssistantMessage("batch rejected")),
        ])
        let manager = BackgroundTaskManager()
        let job = createJobTool(manager: manager, sessionId: "mixed-poll-parent")
        let executions = ToolCallRecorder()
        let slow = AgentTool(
            name: "slow",
            label: "slow",
            description: "would be non-interruptible and slow",
            parameters: ["type": "object"],
            execute: { id, _, _, _ in
                await executions.record(id)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return AgentToolResult(content: [.text(TextContent(text: "slow done"))])
            }
        )
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                model: faux.getModel(),
                tools: [job, slow]
            ),
            toolExecution: .parallel
        ))

        let startedAt = Date()
        try await agent.prompt("emit a mixed blocking batch")

        #expect(Date().timeIntervalSince(startedAt) < 1)
        #expect(await executions.snapshot().isEmpty)
        for id in ["mixed-poll", "mixed-slow"] {
            let result = toolResult(in: agent.state.messages, id: id)
            #expect(result?.isError == true)
            #expect(toolResultText(result).contains("issue it alone"))
        }
    }

    @Test("abort interrupts thrown-error retry backoff")
    func retryBackoffIsCancellationAware() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let attempts = RetryAttemptCounter()
        let streamFn: StreamFn = { _, _, _ in
            _ = await attempts.next()
            throw AgentLoopPolicyTestError.retryableTransport
        }
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: faux.getModel()),
            streamFn: streamFn
        ))
        agent.retryBaseDelayMs = 5_000
        let run = Task { try await agent.prompt("retry until aborted") }
        #expect(await awaitUntil(1_000) { await attempts.snapshot() == 1 })

        let abortedAt = Date()
        agent.abort()
        _ = try await run.value

        #expect(Date().timeIntervalSince(abortedAt) < 1)
        #expect(await attempts.snapshot() == 1)
        guard case .assistant(let failure) = agent.state.messages.last else {
            Issue.record("expected aborted terminal message")
            return
        }
        #expect(failure.stopReason == .aborted)
    }
}

private actor ToolCallRecorder {
    private var ids: [String] = []

    func record(_ id: String) {
        ids.append(id)
    }

    func snapshot() -> [String] {
        ids
    }
}

private actor RetryAttemptCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }

    func snapshot() -> Int {
        value
    }
}

private func toolResult(in messages: [Message], id: String) -> ToolResultMessage? {
    messages.lazy.compactMap { message -> ToolResultMessage? in
        guard case .toolResult(let result) = message, result.toolCallId == id else { return nil }
        return result
    }.first
}

private func toolResultText(_ result: ToolResultMessage?) -> String {
    result?.content.compactMap { block -> String? in
        guard case .text(let text) = block else { return nil }
        return text.text
    }.joined(separator: "\n") ?? ""
}

private enum AgentLoopPolicyTestError: Error {
    case missingCursorBridge
    case retryableTransport
}

extension AgentLoopPolicyTestError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingCursorBridge:
            return "missing Cursor bridge"
        case .retryableTransport:
            return "connection reset by peer"
        }
    }
}
