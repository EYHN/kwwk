import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

@Suite("Rewind session ownership")
struct RewindSessionRaceTests {
    @MainActor
    @Test("a stale rewind cannot mutate or persist into a replacement session")
    func staleRewindStopsAtSessionGenerationBoundary() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let providerGate = RewindProviderGate()
        faux.setResponses([
            .factory { _, _, _, _ in
                await providerGate.enterAndWait()
                return fauxAssistantMessage("late old-session reply")
            },
        ])

        let oldSeed: [Message] = [
            .user(UserMessage(text: "old rewind target")),
            .assistant(fauxAssistantMessage("old answer")),
        ]
        let oldAgent = Agent(
            initialState: AgentInitialState(model: faux.getModel(), messages: oldSeed),
            sessionId: "rewind-old"
        )
        let newAgent = Agent(
            initialState: AgentInitialState(
                model: faux.getModel(),
                messages: [.user(UserMessage(text: "new session sentinel"))]
            ),
            sessionId: "rewind-new"
        )
        let agentBox = AgentSessionBox(CodingAgent(agent: oldAgent, detachBackground: nil))
        let expectedGeneration = agentBox.generation

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-rewind-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)

        let oldRecorder = SessionRecorder(
            store: store,
            sessionId: "rewind-old",
            cwd: dir.path,
            model: oldAgent.state.model.id,
            provider: oldAgent.state.model.provider
        )
        await oldRecorder.ensureCreated()
        await oldRecorder.flush(messages: oldSeed)
        let oldUnsubscribe = oldRecorder.attach(to: oldAgent)
        let recorderBox = RecorderBox(
            recorder: oldRecorder,
            unsubscribe: oldUnsubscribe,
            sessionId: "rewind-old"
        )
        defer { recorderBox.unsubscribe() }

        let newRecorder = SessionRecorder(
            store: store,
            sessionId: "rewind-new",
            cwd: dir.path,
            model: newAgent.state.model.id,
            provider: newAgent.state.model.provider
        )
        await newRecorder.ensureCreated()
        await newRecorder.flush(messages: newAgent.state.messages)

        let frame = CodingFrame()
        let retry = TurnRetryState()
        let modal = ModalHost(
            renderModalLines: { _ in },
            restoreTranscript: {},
            requestRender: {}
        )
        let rewinding = RewindMainActorRef(false)
        let transcriptReplacements = RewindMainActorRef(0)

        let oldRun = Task {
            try await oldAgent.prompt("in-flight old prompt")
        }
        await providerGate.waitUntilEntered()
        #expect(oldAgent.state.isStreaming)

        openRewindSelector(
            agent: oldAgent,
            modal: modal,
            frame: frame,
            sessionStore: store,
            recorderBox: recorderBox,
            retry: retry,
            attachments: AttachmentStore(),
            dequeueCycle: DequeueCycleState(),
            terminalWidth: { 80 },
            commit: { _ in },
            replaceTranscript: { _ in transcriptReplacements.value += 1 },
            recomputeTranscript: {},
            updateFrameStatus: {},
            requestRender: {},
            isCurrentSession: {
                agentBox.isCurrent(agent: oldAgent, generation: expectedGeneration)
            },
            setRewinding: { rewinding.value = $0 }
        )
        modal.routeConfirm()
        #expect(rewinding.value)

        // Let the rewind task abort the old run and suspend in waitForIdle,
        // then rotate both Agent identity and recorder while it is asleep.
        await Task.yield()
        agentBox.replace(with: CodingAgent(agent: newAgent, detachBackground: nil))
        recorderBox.unsubscribe()
        recorderBox.recorder = newRecorder
        recorderBox.unsubscribe = {}
        recorderBox.sessionId = "rewind-new"
        frame.input.value = "new session draft"
        retry.failed = true
        retry.lastText = "new session retry"

        await providerGate.release()
        _ = try? await oldRun.value
        for _ in 0..<200 where rewinding.value {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(!rewinding.value)
        #expect(frame.input.value == "new session draft")
        #expect(retry.failed)
        #expect(retry.lastText == "new session retry")
        #expect(transcriptReplacements.value == 0)
        #expect(oldAgent.state.messages.contains(where: {
            rewindRaceText($0) == "in-flight old prompt"
        }), "the stale operation must not truncate the outgoing Agent")

        let loadedNew = try await store.load(id: "rewind-new")
        #expect(loadedNew.messages.count == 1)
        #expect(rewindRaceText(loadedNew.messages[0]) == "new session sentinel")
    }
}

@MainActor
private final class RewindMainActorRef<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

private actor RewindProviderGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private func rewindRaceText(_ message: Message) -> String {
    switch message {
    case .user(let user):
        return user.content.compactMap { block in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined(separator: "\n")
    case .assistant(let assistant):
        return assistant.content.compactMap { block in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined(separator: "\n")
    case .toolResult:
        return ""
    }
}
