import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

@Suite("performNewSession reset")
struct NewSessionResetTests {

    @Test("Enter contention preserves the cleared prompt exactly once")
    func promptContentionFallback() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("handled"))])
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))
        let gate = SessionMaintenanceGate()
        let maintenance = Task {
            try await agent.withMaintenance {
                await gate.enterAndWait()
            }
        }
        await gate.waitUntilEntered()

        let submission = Task {
            try await promptPreservingContention(
                agent: agent,
                text: "do not lose me",
                images: []
            )
        }
        for _ in 0..<100 {
            if agent.queuedSteeringCount() > 0 { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(agent.queuedSteeringCount() == 1)
        await gate.release()
        try await maintenance.value
        try await submission.value
        await agent.waitForIdle()

        let copies = agent.state.messages.filter { message in
            guard case .user(let user) = message,
                  case .text(let text) = user.content.first else { return false }
            return text.text == "do not lose me"
        }
        #expect(copies.count == 1)
    }

    @MainActor
    @Test("production replacement path records only the new Agent identity")
    func replacementUsesFreshAgentIdentity() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("new session reply"))])

        let outgoing = Agent(
            initialState: AgentInitialState(
                model: faux.getModel(),
                messages: [.user(UserMessage(text: "outgoing transcript"))]
            ),
            sessionId: "old-session"
        )
        let replacement = Agent(
            initialState: AgentInitialState(model: faux.getModel()),
            sessionId: "new-session"
        )
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-newidentity-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let initialRecorder = SessionRecorder(
            store: store,
            sessionId: "old-session",
            cwd: dir.path,
            model: outgoing.state.model.id,
            provider: outgoing.state.model.provider
        )
        await initialRecorder.ensureCreated()
        let recorderBox = RecorderBox(
            recorder: initialRecorder,
            unsubscribe: initialRecorder.attach(to: outgoing),
            sessionId: "old-session"
        )
        defer { recorderBox.unsubscribe() }

        await performNewSession(
            newId: "new-session",
            recorderBox: recorderBox,
            sessionStore: store,
            agent: outgoing,
            replaceSessionAgent: { id, messages in
                #expect(id == "new-session")
                replacement.state.messages = messages
                return replacement
            },
            cwd: dir.path,
            attachments: AttachmentStore(),
            retry: TurnRetryState(),
            dequeueCycle: DequeueCycleState(),
            frame: CodingFrame(),
            width: 60,
            commit: { _ in },
            recompute: {},
            updateStatus: {},
            requestRender: {}
        )

        #expect(outgoing.sessionId == "old-session")
        #expect(outgoing.state.messages.count == 1)
        #expect(replacement.sessionId == "new-session")
        #expect(replacement.state.messages.isEmpty)
        #expect(recorderBox.sessionId == "new-session")

        try await replacement.prompt("belongs to new session")
        let loaded = try await store.resolveResume(.id("new-session"), cwd: dir.path)
        #expect(loaded.messages.contains { message in
            guard case .user(let user) = message,
                  case .text(let text) = user.content.first else { return false }
            return text.text == "belongs to new session"
        })
        #expect(!loaded.messages.contains { message in
            guard case .user(let user) = message,
                  case .text(let text) = user.content.first else { return false }
            return text.text == "outgoing transcript"
        })
    }

    @MainActor
    @Test("clears messages, queue, retry, attachments and repoints the recorder")
    func resetsEverything() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))

        // Seed live state that /new must wipe.
        agent.state.messages = [
            .user(UserMessage(text: "old conversation")),
        ]
        agent.steer(.user(UserMessage(text: "queued one")))
        agent.steer(.user(UserMessage(text: "queued two")))

        let attachments = AttachmentStore()
        _ = attachments.addPastedText("a long pasted blob that should be dropped on /new")

        let retry = TurnRetryState()
        retry.failed = true
        retry.lastText = "stale prompt"
        retry.lastImages = []
        retry.trackedActive = true

        // A stale dequeue cursor from the outgoing session must also be cleared.
        let dequeueCycle = DequeueCycleState()
        dequeueCycle.last = .user(UserMessage(text: "queued one"))

        let frame = CodingFrame()
        frame.input.value = "draft in progress"

        // Real on-disk store in an isolated temp dir.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-newsession-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SessionStore(directory: dir)

        let originalId = "original-session"
        let initialRecorder = SessionRecorder(
            store: store,
            sessionId: originalId,
            cwd: dir.path,
            model: agent.state.model.id,
            provider: agent.state.model.provider
        )
        await initialRecorder.ensureCreated()
        let recorderBox = RecorderBox(
            recorder: initialRecorder,
            unsubscribe: initialRecorder.attach(to: agent),
            sessionId: originalId
        )
        defer { recorderBox.unsubscribe() }

        let committed = CommitRecorder()
        let newId = "fresh-session"

        await performNewSession(
            newId: newId,
            recorderBox: recorderBox,
            sessionStore: store,
            agent: agent,
            cwd: dir.path,
            attachments: attachments,
            retry: retry,
            dequeueCycle: dequeueCycle,
            frame: frame,
            width: 60,
            commit: { lines in committed.lines.append(contentsOf: lines) },
            recompute: {},
            updateStatus: {},
            requestRender: {}
        )

        #expect(agent.state.messages.isEmpty, "live transcript is cleared")
        #expect(agent.queuedSteeringCount() == 0, "steering queue is drained")
        #expect(retry.failed == false)
        #expect(retry.lastText == nil)
        #expect(retry.lastImages.isEmpty)
        #expect(retry.trackedActive == false, "the in-flight tracking flag is cleared")
        #expect(dequeueCycle.last == nil, "the dequeue cursor is forgotten")
        #expect(frame.input.value == "", "the in-progress draft is discarded")
        #expect(recorderBox.sessionId == newId, "persistence repointed at the new id")
        #expect(committed.joined.contains("new session \(newId.prefix(8))"),
                "a labeled separator is committed to scrollback")
    }
}

@MainActor
private final class CommitRecorder {
    var lines: [String] = []
    var joined: String { lines.joined(separator: "\n") }
}

private actor SessionMaintenanceGate {
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
