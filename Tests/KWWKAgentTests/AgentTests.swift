import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

// Calculator tool used across several tests.
func makeCalculateTool() -> AgentTool {
    AgentTool(
        name: "calculate",
        label: "Calculate",
        description: "Evaluate a basic arithmetic expression.",
        parameters: [
            "type": "object",
            "properties": ["expression": ["type": "string"]],
            "required": ["expression"],
        ],
        execute: { _, args, _, _ in
            struct InvalidArgs: Error {}
            guard case .object(let obj) = args,
                  case .string(let expr) = obj["expression"] ?? .null else {
                throw InvalidArgs()
            }
            let cleaned = expr.replacingOccurrences(of: " ", with: "")
            let result: Int
            if let idx = cleaned.firstIndex(of: "*"),
               let a = Int(cleaned[..<idx]),
               let b = Int(cleaned[cleaned.index(after: idx)...]) {
                result = a * b
            } else if let idx = cleaned.firstIndex(of: "+"),
                      let a = Int(cleaned[..<idx]),
                      let b = Int(cleaned[cleaned.index(after: idx)...]) {
                result = a + b
            } else {
                result = 0
            }
            return AgentToolResult(
                content: [.text(TextContent(text: "\(expr) = \(result)"))],
                details: .object(["result": .int(result)])
            )
        }
    )
}

@Suite("Agent initialization and state")
struct AgentInitTests {
    @Test("creates an agent with default state")
    func defaultState() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        #expect(agent.state.systemPrompt == "")
        #expect(agent.state.thinkingLevel == .off)
        #expect(agent.state.verboseEnabled == false)
        #expect(agent.state.tools.isEmpty)
        #expect(agent.state.messages.isEmpty)
        #expect(agent.state.isStreaming == false)
        #expect(agent.state.streamingMessage == nil)
        #expect(agent.state.pendingToolCalls.isEmpty)
        #expect(agent.state.errorMessage == nil)
    }

    @Test("honours custom initial state")
    func customInitialState() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        let agent = Agent(initialState: AgentInitialState(
            systemPrompt: "You are helpful.",
            model: registration.getModel(),
            thinkingLevel: .low
        ))
        #expect(agent.state.systemPrompt == "You are helpful.")
        #expect(agent.state.thinkingLevel == .low)
    }

    @Test("state setters do not emit events")
    func settersAreQuiet() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        let counter = Counter()
        _ = agent.subscribe { _, _ in await counter.increment() }
        agent.state.systemPrompt = "New"
        try await Task.sleep(nanoseconds: 5_000_000)
        #expect(await counter.value == 0)
    }

    @Test("assigning tools and messages copies the array")
    func arraysAreCopied() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        var tools = [makeCalculateTool()]
        agent.state.tools = tools
        tools.append(makeCalculateTool())
        #expect(agent.state.tools.count == 1)

        var messages: [Message] = [.user(UserMessage(text: "hi"))]
        agent.state.messages = messages
        messages.append(.user(UserMessage(text: "again")))
        #expect(agent.state.messages.count == 1)
    }

    @Test("coding agent carries configured session id into stream options")
    func codingAgentKeepsSessionId() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        let agent = await makeCodingAgent(CodingAgentConfig(
            model: registration.getModel(),
            cwd: FileManager.default.temporaryDirectory.path,
            tools: [],
            sessionId: "stable-session"
        ))

        #expect(agent.sessionId == "stable-session")
    }
}

@Suite("Agent integration with faux provider")
struct AgentIntegrationTests {
    @Test("handles a basic text prompt")
    func basicPrompt() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([.message(fauxAssistantMessage("4"))])

        let agent = Agent(initialState: AgentInitialState(
            systemPrompt: "You are a helpful assistant.",
            model: registration.getModel()
        ))

        try await agent.prompt("What is 2+2?")

        #expect(agent.state.isStreaming == false)
        #expect(agent.state.messages.count == 2)
        #expect(agent.state.messages[0].role == .user)
        #expect(agent.state.messages[1].role == .assistant)
        if case .assistant(let msg) = agent.state.messages[1] {
            let text = msg.content.compactMap { block -> String? in
                if case .text(let t) = block { return t.text } else { return nil }
            }.joined()
            #expect(text.contains("4"))
        } else {
            Issue.record("expected assistant final message")
        }
    }

    @Test("executes tools and tracks pendingToolCalls lifecycle")
    func toolExecution() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxText("Let me calculate that."),
                    fauxToolCall(name: "calculate", arguments: ["expression": "123 * 456"], id: "calc-1"),
                ],
                stopReason: .toolUse
            )),
            .message(fauxAssistantMessage("The result is 56088.")),
        ])

        let agent = Agent(initialState: AgentInitialState(
            systemPrompt: "Always use the calculator tool.",
            model: registration.getModel(),
            tools: [makeCalculateTool()]
        ))

        let recorder = PendingToolCallRecorder()
        _ = agent.subscribe { event, _ in
            if case .toolExecutionStart = event {
                await recorder.record(type: "tool_execution_start", ids: Array(agent.state.pendingToolCalls))
            }
            if case .toolExecutionEnd = event {
                await recorder.record(type: "tool_execution_end", ids: Array(agent.state.pendingToolCalls))
            }
        }

        try await agent.prompt("Calculate 123 * 456.")

        #expect(agent.state.isStreaming == false)
        #expect(agent.state.messages.count >= 4)
        let toolResult = agent.state.messages.first { $0.role == .toolResult }
        if case .toolResult(let tr) = toolResult ?? .user(UserMessage(text: "")) {
            let text = tr.content.compactMap { block -> String? in
                if case .text(let t) = block { return t.text } else { return nil }
            }.joined()
            #expect(text.contains("56088"))
        } else {
            Issue.record("expected a tool result message")
        }
        #expect(agent.state.pendingToolCalls.isEmpty)
        let records = await recorder.snapshot()
        #expect(records.count == 2)
        #expect(records[0].type == "tool_execution_start")
        #expect(records[0].ids == ["calc-1"])
        #expect(records[1].type == "tool_execution_end")
        #expect(records[1].ids.isEmpty)
    }

    @Test("abort sets stopReason aborted and errorMessage")
    func abortExecution() async throws {
        let registration = await registerFauxProvider(
            RegisterFauxProviderOptions(tokensPerSecond: 20, tokenSize: FauxTokenSize(min: 2, max: 2))
        )
        defer { registration.unregister() }
        registration.setResponses([
            .message(fauxAssistantMessage("one two three four five six seven eight nine ten"))
        ])

        let agent = Agent(initialState: AgentInitialState(
            systemPrompt: "Count slowly.",
            model: registration.getModel()
        ))

        Task { @Sendable in
            try? await Task.sleep(nanoseconds: 30_000_000)
            agent.abort()
        }
        try await agent.prompt("Count slowly from 1 to 20.")

        #expect(agent.state.isStreaming == false)
        #expect(agent.state.messages.count >= 2)
        if case .assistant(let msg) = agent.state.messages.last {
            #expect(msg.stopReason == .aborted)
            #expect(msg.errorMessage != nil)
            #expect(agent.state.errorMessage == msg.errorMessage)
        } else {
            Issue.record("expected assistant last message")
        }
    }

    @Test("emits lifecycle events in the documented order")
    func lifecycleEventOrder() async throws {
        let registration = await registerFauxProvider(
            RegisterFauxProviderOptions(tokenSize: FauxTokenSize(min: 1, max: 1))
        )
        defer { registration.unregister() }
        registration.setResponses([.message(fauxAssistantMessage("1 2 3 4 5"))])

        let agent = Agent(initialState: AgentInitialState(
            systemPrompt: "Short replies.",
            model: registration.getModel()
        ))

        let events = EventLog()
        _ = agent.subscribe { event, _ in await events.append(event.type) }
        try await agent.prompt("Count 1-5.")

        let collected = await events.values()
        #expect(collected.contains("agent_start"))
        #expect(collected.contains("turn_start"))
        #expect(collected.contains("message_start"))
        #expect(collected.contains("message_update"))
        #expect(collected.contains("message_end"))
        #expect(collected.contains("turn_end"))
        #expect(collected.contains("agent_end"))

        let idx: (String) -> Int = { name in collected.firstIndex(of: name) ?? -1 }
        #expect(idx("agent_start") < idx("message_start"))
        #expect(idx("message_start") < idx("message_end"))
        #expect(idx("message_end") < idx("agent_end"))
        #expect(agent.state.messages.count == 2)
    }

    @Test("maintains context across multiple turns")
    func multiTurnConversation() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([
            .message(fauxAssistantMessage("Nice to meet you, Alice.")),
            .factory { context, _, _, _ in
                let seenAlice = context.messages.contains { message in
                    guard case .user(let u) = message else { return false }
                    return u.content.contains { block in
                        if case .text(let t) = block { return t.text.contains("Alice") } else { return false }
                    }
                }
                return fauxAssistantMessage(seenAlice ? "Your name is Alice." : "I do not know your name.")
            },
        ])

        let agent = Agent(initialState: AgentInitialState(
            systemPrompt: "You are a helpful assistant.",
            model: registration.getModel()
        ))

        try await agent.prompt("My name is Alice.")
        #expect(agent.state.messages.count == 2)

        try await agent.prompt("What is my name?")
        #expect(agent.state.messages.count == 4)

        if case .assistant(let msg) = agent.state.messages[3] {
            let text = msg.content.compactMap { block -> String? in
                if case .text(let t) = block { return t.text } else { return nil }
            }.joined()
            #expect(text.lowercased().contains("alice"))
        } else {
            Issue.record("expected assistant message")
        }
    }

    @Test("preserves thinking content blocks in the transcript")
    func preservesThinking() async throws {
        let registration = await registerFauxProvider(
            RegisterFauxProviderOptions(
                models: [FauxModelDefinition(id: "faux-reasoning", reasoning: true)]
            )
        )
        defer { registration.unregister() }
        registration.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxThinking("step by step"), fauxText("4")]))
        ])

        let agent = Agent(initialState: AgentInitialState(
            systemPrompt: "You are a helpful assistant.",
            model: registration.getModel(),
            thinkingLevel: .low
        ))
        try await agent.prompt("What is 2+2?")

        if case .assistant(let msg) = agent.state.messages[1] {
            #expect(msg.content == [
                .thinking(ThinkingContent(thinking: "step by step")),
                .text(TextContent(text: "4")),
            ])
        } else {
            Issue.record("expected assistant message with thinking block")
        }
    }

    @Test("bridges StreamOptions verbose callback into AgentEvent.verbose")
    func bridgesVerboseEvents() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        let streamFn: StreamFn = { model, _, options in
            await options?.emitVerbose(
                source: "test.provider",
                message: "connected",
                metadata: ["attempt": .int(1)]
            )
            let message = AssistantMessage(
                content: [.text(TextContent(text: "ok"))],
                api: model.api,
                provider: model.provider,
                model: model.id
            )
            let stream = AssistantMessageStream()
            stream.push(.start(partial: message))
            stream.push(.textStart(contentIndex: 0, partial: message))
            stream.push(.textDelta(contentIndex: 0, delta: "ok", partial: message))
            stream.push(.textEnd(contentIndex: 0, content: "ok", partial: message))
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
            return stream
        }
        let agent = Agent(
            initialState: AgentInitialState(
                model: registration.getModel(),
                verboseEnabled: true
            ),
            streamFn: streamFn
        )
        let recorder = VerboseEventLog()
        _ = agent.subscribe { event, _ in
            if case .verbose(let verbose) = event {
                await recorder.append(verbose)
            }
        }

        try await agent.prompt("hi")

        let events = await recorder.values()
        #expect(events.count == 1)
        #expect(events.first?.source == "test.provider")
        #expect(events.first?.message == "connected")
        #expect(events.first?.metadata["attempt"] == .int(1))
    }

    @Test("resolves provider auth per session before streaming")
    func resolvesProviderAuthBeforeStreaming() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        let capture = StreamAuthCapture()
        let streamFn: StreamFn = { model, _, options in
            await capture.record(model: model, options: options)
            let message = AssistantMessage(
                content: [.text(TextContent(text: "ok"))],
                api: model.api,
                provider: model.provider,
                model: model.id
            )
            let stream = AssistantMessageStream()
            stream.push(.start(partial: message))
            stream.push(.textStart(contentIndex: 0, partial: message))
            stream.push(.textDelta(contentIndex: 0, delta: "ok", partial: message))
            stream.push(.textEnd(contentIndex: 0, content: "ok", partial: message))
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
            return stream
        }
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(model: registration.getModel()),
            streamFn: streamFn,
            sessionId: "session-auth",
            authResolver: { model, sessionId in
                await capture.recordResolver(model: model, sessionId: sessionId)
                return ResolvedProviderAuth(
                    token: "resolved-token",
                    scheme: .bearer,
                    baseURL: "https://proxy.example",
                    metadata: ["deployment": .string("prod")]
                )
            }
        ))

        try await agent.prompt("hi")

        let resolved = await capture.resolved
        let streamed = await capture.streamed
        #expect(resolved?.model.id == registration.getModel().id)
        #expect(resolved?.sessionId == "session-auth")
        #expect(streamed?.model.baseUrl == "https://proxy.example")
        #expect(streamed?.options?.apiKey == "resolved-token")
        #expect(streamed?.options?.sessionId == "session-auth")
        #expect(streamed?.options?.resolvedAuth?.scheme == .bearer)
        #expect(streamed?.options?.resolvedAuth?.token == "resolved-token")
        #expect(streamed?.options?.metadata?["deployment"] == .string("prod"))
    }
}

@Suite("Agent.continue")
struct AgentContinueTests {
    @Test("throws when there are no messages")
    func noMessages() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        await #expect(throws: AgentError.noMessagesToContinue) {
            try await agent.continue()
        }
    }

    @Test("throws when last message is an assistant message")
    func lastIsAssistant() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        let assistant = AssistantMessage(
            content: [.text(TextContent(text: "Hello"))],
            api: registration.api,
            provider: "faux",
            model: "faux-1"
        )
        agent.state.messages = [.assistant(assistant)]
        await #expect(throws: AgentError.cannotContinueFromRole("assistant")) {
            try await agent.continue()
        }
    }

    @Test("continues from a user message")
    func continueFromUser() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([.message(fauxAssistantMessage("HELLO WORLD"))])

        let agent = Agent(initialState: AgentInitialState(
            systemPrompt: "Follow instructions.",
            model: registration.getModel()
        ))
        agent.state.messages = [.user(UserMessage(text: "Say exactly HELLO WORLD"))]
        try await agent.continue()
        #expect(agent.state.messages.count == 2)
        #expect(agent.state.messages[0].role == .user)
        #expect(agent.state.messages[1].role == .assistant)
    }
}

@Suite("Agent subscription async settlement")
struct AgentSubscriptionTests {
    @Test("prompt awaits async subscribers before resolving")
    func awaitsAsyncSubscribers() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([.message(fauxAssistantMessage("ok"))])

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        let barrier = AsyncBarrier()

        _ = agent.subscribe { event, _ in
            if case .agentEnd = event { await barrier.wait() }
        }

        let resolvedFlag = Holder<Bool>()
        await resolvedFlag.set(false)
        let task = Task { try await agent.prompt("hello") }
        let watcher = Task {
            _ = try? await task.value
            await resolvedFlag.set(true)
        }
        try? await Task.sleep(nanoseconds: 15_000_000)
        #expect(await resolvedFlag.value == false)
        await barrier.release()
        _ = try? await task.value
        _ = await watcher.value
    }

    @Test("waitForIdle waits for async subscribers")
    func waitForIdleWaits() async throws {
        let registration = await registerFauxProvider()
        defer { registration.unregister() }
        registration.setResponses([.message(fauxAssistantMessage("ok"))])

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        let barrier = AsyncBarrier()
        _ = agent.subscribe { event, _ in
            if case .messageEnd = event { await barrier.wait() }
        }

        let promptTask = Task { try await agent.prompt("hello") }
        let idleTask = Task { await agent.waitForIdle() }
        try? await Task.sleep(nanoseconds: 15_000_000)
        #expect(idleTask.isCancelled == false)
        await barrier.release()
        _ = try? await promptTask.value
        await idleTask.value
    }

    @Test("passes the active cancellation handle to subscribers")
    func passesSignal() async throws {
        let registration = await registerFauxProvider(
            RegisterFauxProviderOptions(tokensPerSecond: 50, tokenSize: FauxTokenSize(min: 2, max: 2))
        )
        defer { registration.unregister() }
        registration.setResponses([.message(fauxAssistantMessage("slow slow slow"))])

        let agent = Agent(initialState: AgentInitialState(model: registration.getModel()))
        let holder = Holder<CancellationHandle>()
        _ = agent.subscribe { event, signal in
            if case .agentStart = event, let signal { await holder.set(signal) }
        }

        let task = Task { try await agent.prompt("hi") }
        try? await Task.sleep(nanoseconds: 15_000_000)
        let handle = await holder.value
        #expect(handle != nil)
        #expect(handle?.isCancelled == false)
        agent.abort()
        _ = try? await task.value
        #expect(handle?.isCancelled == true)
    }
}

// MARK: - Test helpers

actor Counter {
    var value: Int = 0
    func increment() { value += 1 }
}

actor EventLog {
    var log: [String] = []
    func append(_ s: String) { log.append(s) }
    func values() -> [String] { log }
}

actor VerboseEventLog {
    var log: [VerboseEvent] = []
    func append(_ event: VerboseEvent) { log.append(event) }
    func values() -> [VerboseEvent] { log }
}

actor StreamAuthCapture {
    var resolved: (model: Model, sessionId: String?)?
    var streamed: (model: Model, options: StreamOptions?)?

    func recordResolver(model: Model, sessionId: String?) {
        resolved = (model, sessionId)
    }

    func record(model: Model, options: StreamOptions?) {
        streamed = (model, options)
    }
}

actor AsyncBarrier {
    var pendingContinuations: [CheckedContinuation<Void, Never>] = []
    var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { cont in
            pendingContinuations.append(cont)
        }
    }

    func release() {
        released = true
        let conts = pendingContinuations
        pendingContinuations.removeAll()
        for c in conts { c.resume() }
    }
}

actor Holder<T> {
    var value: T?
    func set(_ v: T) { value = v }
}

actor PendingToolCallRecorder {
    struct Entry: Equatable { var type: String; var ids: [String] }
    var entries: [Entry] = []
    func record(type: String, ids: [String]) {
        entries.append(Entry(type: type, ids: ids.sorted()))
    }
    func snapshot() -> [Entry] { entries }
}
