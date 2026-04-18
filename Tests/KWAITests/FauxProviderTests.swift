import Foundation
import Testing
@testable import KWAI

/// Drain a stream into an array of events.
func collectEvents(_ stream: AssistantMessageStream) async -> [AssistantMessageEvent] {
    var out: [AssistantMessageEvent] = []
    for await event in stream {
        out.append(event)
    }
    return out
}

@Suite("Faux provider")
struct FauxProviderTests {

    // MARK: - registration & simple completion

    @Test("registers a custom provider and estimates usage")
    func registersAndEstimatesUsage() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        registration.setResponses([.message(fauxAssistantMessage("hello world"))])

        let context = Context(
            systemPrompt: "Be concise.",
            messages: [.user(UserMessage(text: "hi there"))]
        )

        let response = try await complete(model: registration.getModel(), context: context)
        #expect(response.content == [.text(TextContent(text: "hello world"))])
        #expect(response.usage.input > 0)
        #expect(response.usage.output > 0)
        #expect(response.usage.totalTokens == response.usage.input + response.usage.output)
        #expect(registration.state.callCount == 1)
    }

    @Test("supports helper blocks for text, thinking, and tool calls")
    func helperBlocks() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        registration.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxThinking("think"),
                    fauxToolCall(name: "echo", arguments: ["text": "hi"]),
                    fauxText("done"),
                ],
                stopReason: .toolUse
            ))
        ])

        let response = try await complete(
            model: registration.getModel(),
            context: Context(messages: [.user(UserMessage(text: "hi"))])
        )

        #expect(response.content.count == 3)
        if case .thinking(let t) = response.content[0] {
            #expect(t.thinking == "think")
        } else { Issue.record("expected thinking first") }
        if case .toolCall(let tc) = response.content[1] {
            #expect(tc.name == "echo")
            #expect(tc.arguments == .object(["text": "hi"]))
            #expect(!tc.id.isEmpty)
        } else { Issue.record("expected tool call second") }
        if case .text(let t) = response.content[2] {
            #expect(t.text == "done")
        } else { Issue.record("expected text third") }
        #expect(response.stopReason == .toolUse)
    }

    @Test("supports multiple models with per-model reasoning")
    func multipleModels() async throws {
        let registration = await registerFauxProvider(
            RegisterFauxProviderOptions(
                models: [
                    FauxModelDefinition(id: "faux-fast", name: "Faux Fast", reasoning: false),
                    FauxModelDefinition(id: "faux-thinker", name: "Faux Thinker", reasoning: true),
                ]
            )
        )
        defer { registration.unregister() }

        registration.setResponses([
            .factory { _, _, _, model in fauxAssistantMessage("\(model.id):\(model.reasoning)") },
            .factory { _, _, _, model in fauxAssistantMessage("\(model.id):\(model.reasoning)") },
        ])

        #expect(registration.models.map { $0.id } == ["faux-fast", "faux-thinker"])
        #expect(registration.getModel().id == "faux-fast")
        #expect(registration.getModel(id: "faux-fast")?.reasoning == false)
        #expect(registration.getModel(id: "faux-thinker")?.reasoning == true)

        let fast = try await complete(
            model: registration.getModel(id: "faux-fast")!,
            context: Context(messages: [.user(UserMessage(text: "hi"))])
        )
        let thinker = try await complete(
            model: registration.getModel(id: "faux-thinker")!,
            context: Context(messages: [.user(UserMessage(text: "hi"))])
        )

        #expect(fast.content == [.text(TextContent(text: "faux-fast:false"))])
        #expect(thinker.content == [.text(TextContent(text: "faux-thinker:true"))])
    }

    @Test("rewrites api, provider, and model on returned messages")
    func rewritesIdentity() async throws {
        let registration = await registerFauxProvider(
            RegisterFauxProviderOptions(
                api: "faux:test",
                provider: "faux-provider",
                models: [FauxModelDefinition(id: "faux-model")]
            )
        )
        defer { registration.unregister() }

        registration.setResponses([.message(fauxAssistantMessage("hello"))])
        let response = try await complete(
            model: registration.getModel(),
            context: Context(messages: [.user(UserMessage(text: "hi"))])
        )
        #expect(response.api == "faux:test")
        #expect(response.provider == "faux-provider")
        #expect(response.model == "faux-model")
    }

    // MARK: - queue semantics

    @Test("consumes queued responses in order and errors when exhausted")
    func queueOrderingAndExhaustion() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        registration.setResponses([
            .message(fauxAssistantMessage("first")),
            .message(fauxAssistantMessage("second")),
        ])
        let context = Context(messages: [.user(UserMessage(text: "hi"))])

        let first = try await complete(model: registration.getModel(), context: context)
        let second = try await complete(model: registration.getModel(), context: context)
        let exhausted = try await complete(model: registration.getModel(), context: context)

        #expect(first.content == [.text(TextContent(text: "first"))])
        #expect(second.content == [.text(TextContent(text: "second"))])
        #expect(exhausted.stopReason == .error)
        #expect(exhausted.errorMessage == "No more faux responses queued")
        #expect(registration.getPendingResponseCount() == 0)
        #expect(registration.state.callCount == 3)
    }

    @Test("can replace and append queued responses")
    func replaceAndAppend() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        registration.setResponses([.message(fauxAssistantMessage("first"))])
        let context = Context(messages: [.user(UserMessage(text: "hi"))])

        let first = try await complete(model: registration.getModel(), context: context)
        #expect(first.content == [.text(TextContent(text: "first"))])
        #expect(registration.getPendingResponseCount() == 0)

        registration.setResponses([.message(fauxAssistantMessage("second"))])
        #expect(registration.getPendingResponseCount() == 1)
        let second = try await complete(model: registration.getModel(), context: context)
        #expect(second.content == [.text(TextContent(text: "second"))])

        registration.appendResponses([
            .message(fauxAssistantMessage("third")),
            .message(fauxAssistantMessage("fourth")),
        ])
        #expect(registration.getPendingResponseCount() == 2)
        let third = try await complete(model: registration.getModel(), context: context)
        #expect(third.content == [.text(TextContent(text: "third"))])
        let fourth = try await complete(model: registration.getModel(), context: context)
        #expect(fourth.content == [.text(TextContent(text: "fourth"))])
        #expect(registration.getPendingResponseCount() == 0)
    }

    @Test("supports async response factories")
    func asyncFactories() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        registration.setResponses([
            .factory { context, _, state, _ in
                fauxAssistantMessage("\(context.messages.count):\(state.callCount)")
            }
        ])

        let response = try await complete(
            model: registration.getModel(),
            context: Context(messages: [.user(UserMessage(text: "hi"))])
        )
        #expect(response.content == [.text(TextContent(text: "1:1"))])
    }

    @Test("emits an error when a response factory throws")
    func factoryThrows() async throws {
        struct Boom: Error {}
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        registration.setResponses([
            .factory { _, _, _, _ in throw Boom() }
        ])

        let events = await collectEvents(
            try await stream(
                model: registration.getModel(),
                context: Context(messages: [.user(UserMessage(text: "hi"))])
            )
        )
        #expect(events.count == 1)
        if case .error(_, let err) = events[0] {
            #expect(err.stopReason == .error)
            #expect(err.errorMessage?.isEmpty == false)
        } else {
            Issue.record("expected single error event")
        }
    }

    // MARK: - token estimation

    @Test("estimates prompt and output tokens from serialized context")
    func tokenEstimation() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        registration.setResponses([.message(fauxAssistantMessage("done"))])

        let tool = Tool(
            name: "echo",
            description: "Echo back text",
            parameters: [
                "type": "object",
                "properties": ["text": ["type": "string"]],
                "required": ["text"],
            ]
        )
        let user = UserMessage(
            content: [
                .text(TextContent(text: "hello")),
                .image(ImageContent(data: "abcd", mimeType: "image/png")),
            ],
            timestamp: 1
        )
        let context = Context(
            systemPrompt: "sys",
            messages: [
                .user(user),
                .assistant(fauxAssistantMessage("prior")),
                .toolResult(ToolResultMessage(
                    toolCallId: "tool-1",
                    toolName: "echo",
                    content: [.text(TextContent(text: "tool out"))],
                    isError: false,
                    timestamp: 2
                )),
            ],
            tools: [tool]
        )

        let response = try await complete(model: registration.getModel(), context: context)
        #expect(response.usage.input > 0)
        #expect(response.usage.output > 0)
        #expect(response.usage.cacheRead == 0)
        #expect(response.usage.cacheWrite == 0)
        #expect(response.usage.totalTokens == response.usage.input + response.usage.output)
    }

    // MARK: - prompt caching

    @Test("does not share cache across sessions without sessionId")
    func cacheNotSharedAcrossSessions() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        registration.setResponses([
            .message(fauxAssistantMessage("first")),
            .message(fauxAssistantMessage("second")),
            .message(fauxAssistantMessage("third")),
        ])
        var context = Context(messages: [.user(UserMessage(text: "hello"))])

        let first = try await complete(
            model: registration.getModel(),
            context: context,
            options: StreamOptions(cacheRetention: .short, sessionId: "session-1")
        )
        #expect(first.usage.cacheWrite > 0)

        context.messages.append(.assistant(first))
        context.messages.append(.user(UserMessage(text: "follow up")))

        let second = try await complete(
            model: registration.getModel(),
            context: context,
            options: StreamOptions(cacheRetention: .short, sessionId: "session-2")
        )
        #expect(second.usage.cacheRead == 0)
        #expect(second.usage.cacheWrite > 0)

        let third = try await complete(model: registration.getModel(), context: context)
        #expect(third.usage.cacheRead == 0)
        #expect(third.usage.cacheWrite == 0)
    }

    @Test("simulates prompt caching per sessionId")
    func cacheSharedWithinSession() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        registration.setResponses([
            .message(fauxAssistantMessage("first")),
            .message(fauxAssistantMessage("second")),
        ])
        var context = Context(
            systemPrompt: "Be concise.",
            messages: [.user(UserMessage(text: "hello"))]
        )

        let first = try await complete(
            model: registration.getModel(),
            context: context,
            options: StreamOptions(cacheRetention: .short, sessionId: "session-1")
        )
        #expect(first.usage.cacheRead == 0)
        #expect(first.usage.cacheWrite > 0)

        context.messages.append(.assistant(first))
        context.messages.append(.user(UserMessage(text: "follow up")))

        let second = try await complete(
            model: registration.getModel(),
            context: context,
            options: StreamOptions(cacheRetention: .short, sessionId: "session-1")
        )
        #expect(second.usage.cacheRead > 0)
    }

    @Test("does not simulate caching when cacheRetention is .none")
    func cacheNone() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        registration.setResponses([
            .message(fauxAssistantMessage("first")),
            .message(fauxAssistantMessage("second")),
        ])
        var context = Context(messages: [.user(UserMessage(text: "hello"))])

        _ = try await complete(
            model: registration.getModel(),
            context: context,
            options: StreamOptions(cacheRetention: CacheRetention.none, sessionId: "session-1")
        )
        context.messages.append(.assistant(fauxAssistantMessage("first")))
        context.messages.append(.user(UserMessage(text: "follow up")))
        let second = try await complete(
            model: registration.getModel(),
            context: context,
            options: StreamOptions(cacheRetention: CacheRetention.none, sessionId: "session-1")
        )
        #expect(second.usage.cacheRead == 0)
        #expect(second.usage.cacheWrite == 0)
    }

    // MARK: - streaming event emission

    @Test("streams thinking, text, and partial tool call deltas")
    func streamsAllBlockKinds() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        registration.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxThinking("thinking text"),
                    fauxText("answer text"),
                    fauxToolCall(name: "echo", arguments: ["text": "hi", "count": 12], id: "tool-1"),
                ],
                stopReason: .toolUse
            ))
        ])

        var types: [String] = []
        var toolCallDeltas: [String] = []
        let s = try await stream(
            model: registration.getModel(),
            context: Context(messages: [.user(UserMessage(text: "hi"))])
        )
        for await event in s {
            types.append(event.type)
            if case .toolCallDelta(_, let delta, _) = event {
                toolCallDeltas.append(delta)
            }
        }

        #expect(types.contains("thinking_start"))
        #expect(types.contains("thinking_delta"))
        #expect(types.contains("text_start"))
        #expect(types.contains("text_delta"))
        #expect(types.contains("toolcall_start"))
        #expect(types.contains("toolcall_delta"))
        #expect(types.contains("toolcall_end"))
        #expect(toolCallDeltas.count > 1)

        // Deltas concatenated should form the full JSON of arguments.
        let reassembled = toolCallDeltas.joined()
        let data = Data(reassembled.utf8)
        let parsed = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(parsed == JSONValue.object(["count": 12, "text": "hi"]))
    }

    @Test("streams an exact event order for fixed-size chunks")
    func exactEventOrder() async throws {
        let registration = await registerFauxProvider(
            RegisterFauxProviderOptions(tokenSize: FauxTokenSize(min: 1, max: 1))
        )
        defer { registration.unregister() }

        registration.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxThinking("go"),
                    fauxText("ok"),
                    fauxToolCall(name: "echo", arguments: .object([:]), id: "tool-1"),
                ],
                stopReason: .toolUse
            ))
        ])

        let events = await collectEvents(
            try await stream(
                model: registration.getModel(),
                context: Context(messages: [.user(UserMessage(text: "hi"))])
            )
        )

        #expect(events.map { $0.type } == [
            "start",
            "thinking_start", "thinking_delta", "thinking_end",
            "text_start", "text_delta", "text_end",
            "toolcall_start", "toolcall_delta", "toolcall_end",
            "done",
        ])
    }

    @Test("streams multiple tool calls in one message")
    func multipleToolCalls() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        registration.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxToolCall(name: "echo", arguments: ["text": "one"], id: "tool-1"),
                    fauxToolCall(name: "echo", arguments: ["text": "two"], id: "tool-2"),
                ],
                stopReason: .toolUse
            ))
        ])

        let events = await collectEvents(
            try await stream(
                model: registration.getModel(),
                context: Context(messages: [.user(UserMessage(text: "hi"))])
            )
        )

        let starts = events.filter { if case .toolCallStart = $0 { return true } else { return false } }
        let ends = events.filter { if case .toolCallEnd = $0 { return true } else { return false } }
        #expect(starts.count == 2)
        #expect(ends.count == 2)
    }

    @Test("streams an explicit assistant error message as a terminal error")
    func explicitErrorMessage() async throws {
        let registration = await registerFauxProvider(
            RegisterFauxProviderOptions(tokenSize: FauxTokenSize(min: 2, max: 2))
        )
        defer { registration.unregister() }

        var msg = fauxAssistantMessage("partial")
        msg.stopReason = .error
        msg.errorMessage = "upstream failed"
        registration.setResponses([.message(msg)])

        let events = await collectEvents(
            try await stream(
                model: registration.getModel(),
                context: Context(messages: [.user(UserMessage(text: "hi"))])
            )
        )
        #expect(events.map { $0.type } == ["start", "text_start", "text_delta", "text_end", "error"])
        if case .error(let reason, let err) = events.last {
            #expect(reason == .error)
            #expect(err.stopReason == .error)
            #expect(err.errorMessage == "upstream failed")
        } else {
            Issue.record("expected terminal error")
        }
    }

    @Test("streams an explicit aborted message as a terminal error")
    func explicitAbortedMessage() async throws {
        let registration = await registerFauxProvider(
            RegisterFauxProviderOptions(tokenSize: FauxTokenSize(min: 2, max: 2))
        )
        defer { registration.unregister() }

        var msg = fauxAssistantMessage("partial")
        msg.stopReason = .aborted
        msg.errorMessage = "Request was aborted"
        registration.setResponses([.message(msg)])

        let events = await collectEvents(
            try await stream(
                model: registration.getModel(),
                context: Context(messages: [.user(UserMessage(text: "hi"))])
            )
        )
        #expect(events.map { $0.type } == ["start", "text_start", "text_delta", "text_end", "error"])
        if case .error(let reason, let err) = events.last {
            #expect(reason == .aborted)
            #expect(err.stopReason == .aborted)
        } else {
            Issue.record("expected terminal aborted error")
        }
    }

    // MARK: - cancellation

    @Test("supports aborting before the first chunk")
    func abortBeforeFirstChunk() async throws {
        let registration = await registerFauxProvider(
            RegisterFauxProviderOptions(tokensPerSecond: 50, tokenSize: FauxTokenSize(min: 3, max: 3))
        )
        defer { registration.unregister() }

        registration.setResponses([.message(fauxAssistantMessage("abcdefghijklmnopqrstuvwxyz"))])

        let cancellation = CancellationHandle()
        cancellation.cancel()
        let events = await collectEvents(
            try await stream(
                model: registration.getModel(),
                context: Context(messages: [.user(UserMessage(text: "hi"))]),
                options: StreamOptions(cancellation: cancellation)
            )
        )

        #expect(events.count == 1)
        if case .error(let reason, let err) = events[0] {
            #expect(reason == .aborted)
            #expect(err.stopReason == .aborted)
        } else {
            Issue.record("expected single aborted error")
        }
    }

    @Test("supports aborting mid-text stream when paced")
    func abortMidText() async throws {
        let registration = await registerFauxProvider(
            RegisterFauxProviderOptions(tokensPerSecond: 100, tokenSize: FauxTokenSize(min: 3, max: 3))
        )
        defer { registration.unregister() }

        registration.setResponses([.message(fauxAssistantMessage("abcdefghijklmnopqrstuvwxyz"))])

        let cancellation = CancellationHandle()
        var types: [String] = []
        var textDeltas = 0

        let s = try await stream(
            model: registration.getModel(),
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(cancellation: cancellation)
        )
        for await event in s {
            types.append(event.type)
            if case .textDelta = event {
                textDeltas += 1
                cancellation.cancel()
            }
        }

        #expect(textDeltas == 1)
        #expect(types.contains("text_start"))
        #expect(types.contains("text_delta"))
        #expect(types.contains("error"))
        #expect(!types.contains("text_end"))
    }
}

@Suite("API registry")
struct APIRegistryTests {
    @Test("unregistering a provider removes it from the registry")
    func unregister() async throws {
        let registration = await registerFauxProvider()
        registration.setResponses([.message(fauxAssistantMessage("hello"))])
        await registration.unregisterAsync()

        await #expect(throws: ProviderNotFoundError.api(registration.api)) {
            _ = try await complete(
                model: registration.getModel(),
                context: Context(messages: [.user(UserMessage(text: "hi"))])
            )
        }
    }
}
