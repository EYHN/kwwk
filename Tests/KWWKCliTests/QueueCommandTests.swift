import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

@Suite("/queue command")
struct QueueCommandTests {

    @MainActor
    @Test("no args lists queued messages in FIFO order")
    func listsQueuedMessages() async {
        let (ctx, notifier) = await makeContext()
        ctx.agent.steer(.user(UserMessage(text: "first")))
        ctx.agent.steer(.user(UserMessage(text: "second")))

        await runQueueCommand(ctx: ctx, args: "")

        // Expect: header ("2 waiting…") + 2 entries + hint.
        #expect(notifier.joined.contains("2 waiting for the next turn"))
        #expect(notifier.joined.contains("1. first"))
        #expect(notifier.joined.contains("2. second"))
        #expect(notifier.joined.contains("/queue clear"))
        #expect(ctx.agent.queuedSteeringCount() == 2, "listing must not drain the queue")
    }

    @MainActor
    @Test("empty queue reports 'nothing queued' for both list and clear")
    func emptyQueueBehavior() async {
        let (ctx, notifier) = await makeContext()
        await runQueueCommand(ctx: ctx, args: "")
        #expect(notifier.joined.contains("nothing queued"))

        notifier.clear()
        await runQueueCommand(ctx: ctx, args: "clear")
        #expect(notifier.joined.contains("nothing queued"))
    }

    @MainActor
    @Test("`/queue clear` drops all pending messages")
    func clearDrains() async {
        let (ctx, notifier) = await makeContext()
        ctx.agent.steer(.user(UserMessage(text: "a")))
        ctx.agent.steer(.user(UserMessage(text: "b")))
        ctx.agent.steer(.user(UserMessage(text: "c")))

        await runQueueCommand(ctx: ctx, args: "clear")

        #expect(ctx.agent.queuedSteeringCount() == 0)
        #expect(notifier.joined.contains("cleared 3 queued messages"))
    }

    @MainActor
    @Test("`cancel` and `drop` are aliases for clear")
    func clearAliases() async {
        for alias in ["cancel", "drop"] {
            let (ctx, notifier) = await makeContext()
            ctx.agent.steer(.user(UserMessage(text: "x")))
            await runQueueCommand(ctx: ctx, args: alias)
            #expect(ctx.agent.queuedSteeringCount() == 0, "alias \(alias) should drain")
            #expect(notifier.joined.contains("cleared 1 queued message"))
        }
    }

    @MainActor
    @Test("unknown arg is reported with a hint")
    func unknownArg() async {
        let (ctx, notifier) = await makeContext()
        ctx.agent.steer(.user(UserMessage(text: "stays")))
        await runQueueCommand(ctx: ctx, args: "rewind")
        #expect(notifier.joined.contains("unknown arg 'rewind'"))
        #expect(ctx.agent.queuedSteeringCount() == 1, "malformed arg must not mutate the queue")
    }

    @MainActor
    @Test("long queued message previews are truncated in the listing")
    func longMessagePreview() async {
        let (ctx, notifier) = await makeContext()
        let long = String(repeating: "abc ", count: 40)  // ~160 chars
        ctx.agent.steer(.user(UserMessage(text: long)))
        await runQueueCommand(ctx: ctx, args: "")
        // Truncated with a trailing ellipsis so the listing doesn't wrap.
        #expect(notifier.joined.contains("…"))
        #expect(!notifier.joined.contains(long), "the full untruncated body shouldn't leak into the UI")
    }
}

@Suite("Agent queue introspection")
struct AgentQueueIntrospectionTests {

    @Test("queuedSteeringCount and snapshot round-trip")
    func roundTrip() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))
        #expect(agent.queuedSteeringCount() == 0)
        #expect(agent.queuedSteeringMessages().isEmpty)

        agent.steer(.user(UserMessage(text: "one")))
        agent.steer(.user(UserMessage(text: "two")))

        #expect(agent.queuedSteeringCount() == 2)
        let snapshot = agent.queuedSteeringMessages()
        #expect(snapshot.count == 2)
        // Snapshots are read-only copies — draining won't affect the array
        // we were handed. (The queue does drain during agent.prompt but
        // we're just pinning the copy-on-read semantics here.)
        agent.clearSteeringQueue()
        #expect(agent.queuedSteeringCount() == 0)
        #expect(snapshot.count == 2, "prior snapshot must not reflect the clear")
    }

    @MainActor
    @Test("popLastSteeringMessage removes the most recent queued prompt (LIFO)")
    func popLastIsLIFO() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))

        #expect(agent.popLastSteeringMessage() == nil, "empty queue pops nil")

        agent.steer(.user(UserMessage(text: "first")))
        agent.steer(.user(UserMessage(text: "second")))

        let popped = agent.popLastSteeringMessage()
        #expect(queuedMessageBodyText(popped!) == "second")
        #expect(agent.queuedSteeringCount() == 1)
        // The earlier message survives and stays at the head.
        #expect(queuedMessageBodyText(agent.queuedSteeringMessages()[0]) == "first")
    }

    @MainActor
    @Test("pushFrontSteeringMessage inserts at the FIFO head")
    func pushFrontIsHead() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))

        agent.steer(.user(UserMessage(text: "b")))
        agent.steer(.user(UserMessage(text: "c")))
        agent.pushFrontSteeringMessage(.user(UserMessage(text: "a")))

        let snapshot = agent.queuedSteeringMessages().map { queuedMessageBodyText($0) }
        #expect(snapshot == ["a", "b", "c"], "front-push must land at the head, not the tail")
    }

    @MainActor
    @Test("Alt+↑ dequeue-cycle rotates through every queued prompt without loss")
    func dequeueCycleRotates() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))

        agent.steer(.user(UserMessage(text: "a")))
        agent.steer(.user(UserMessage(text: "b")))
        agent.steer(.user(UserMessage(text: "c")))

        // First press: pop the most recent (LIFO). No front-push yet because
        // the editor was empty.
        var last = agent.popLastSteeringMessage()
        #expect(queuedMessageBodyText(last!) == "c")

        // Each subsequent press returns the unedited prompt to the front, then
        // pops the next — walking c → b → a → c without dropping anything.
        var seen: [String] = [queuedMessageBodyText(last!)]
        for _ in 0..<3 {
            agent.pushFrontSteeringMessage(last!)
            last = agent.popLastSteeringMessage()
            seen.append(queuedMessageBodyText(last!))
        }
        #expect(seen == ["c", "b", "a", "c"], "cycle should rotate in reverse and wrap")
        // The queue still holds all three prompts the whole time.
        #expect(agent.queuedSteeringCount() == 2)
        let remaining = Set(agent.queuedSteeringMessages().map { queuedMessageBodyText($0) } + [queuedMessageBodyText(last!)])
        #expect(remaining == ["a", "b", "c"], "no prompt is ever lost during cycling")
    }

    @MainActor
    @Test("dequeueCycleStep rotates through every queued prompt without loss")
    func dequeueCycleStepRotates() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))
        agent.steer(.user(UserMessage(text: "a")))
        agent.steer(.user(UserMessage(text: "b")))
        agent.steer(.user(UserMessage(text: "c")))

        let state = DequeueCycleState()
        var input = ""
        var seen: [String] = []
        // Four presses: pop c, then rotate c→b→a→c, feeding each returned value
        // back as the editor contents (the unedited-draft path).
        for _ in 0..<4 {
            guard let next = dequeueCycleStep(input: input, state: state, agent: agent) else { break }
            input = next
            seen.append(next)
        }
        #expect(seen == ["c", "b", "a", "c"], "cycle rotates in reverse and wraps")
        let remaining = Set(agent.queuedSteeringMessages().map { queuedMessageBodyText($0) } + [input])
        #expect(remaining == ["a", "b", "c"], "no prompt is lost across the cycle")
    }

    @MainActor
    @Test("dequeueCycleStep refuses to clobber an edited draft")
    func dequeueCycleStepBlocksEditedDraft() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))
        agent.steer(.user(UserMessage(text: "only")))

        let state = DequeueCycleState()
        // First press on an empty editor pops the queued prompt.
        #expect(dequeueCycleStep(input: "", state: state, agent: agent) == "only")
        #expect(agent.queuedSteeringCount() == 0)

        // The user edits the draft → the next press is a no-op and the queue is
        // left untouched.
        #expect(dequeueCycleStep(input: "my own new draft", state: state, agent: agent) == nil)
        #expect(agent.queuedSteeringCount() == 0, "blocked cycle must not mutate the queue")
    }

    @MainActor
    @Test("dequeueCycleStep flattens multi-line queued prompts to spaces")
    func dequeueCycleStepFlattensNewlines() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))
        agent.steer(.user(UserMessage(text: "line1\nline2\nline3")))

        let state = DequeueCycleState()
        #expect(dequeueCycleStep(input: "", state: state, agent: agent) == "line1 line2 line3")
    }

    @MainActor
    @Test("dequeueCycleStep no-ops on an empty queue")
    func dequeueCycleStepEmptyQueue() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))
        let state = DequeueCycleState()
        #expect(dequeueCycleStep(input: "", state: state, agent: agent) == nil)
    }
}

// MARK: - Helpers

@MainActor
private func makeContext() async -> (SlashContext, NotifyRecorder) {
    let faux = await registerFauxProvider()
    // Caller's responsibility to keep using `faux` alive for the test
    // duration; we leak the registration into the context so it stays
    // in scope. That's fine: these tests don't care about the faux
    // side-channel, only that Agent instances can be built.
    _ = faux
    let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))
    let notifier = NotifyRecorder()
    let outputDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("kwwk-queue-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let ctx = SlashContext(
        agent: agent,
        modal: ModalHost(
            renderModalLines: { _ in },
            restoreTranscript: {},
            requestRender: {}
        ),
        backgroundManager: BackgroundTaskManager(outputDir: outputDir),
        sessionId: "sess",
        notifyBlock: { lines in for l in lines { notifier.append(l) } },
        commitScrollback: { _ in },
        refreshTranscript: {}
    )
    return (ctx, notifier)
}

@MainActor
private func runQueueCommand(ctx: SlashContext, args: String) async {
    let registry = SlashCommandRegistry()
    registerBuiltinSlashCommands(registry)
    await registry.find("queue")?.handler(ctx, args)
}

@MainActor
private final class NotifyRecorder {
    private(set) var lines: [String] = []
    func append(_ s: String) { lines.append(s) }
    func clear() { lines.removeAll() }
    var joined: String { lines.joined(separator: "\n") }
}
