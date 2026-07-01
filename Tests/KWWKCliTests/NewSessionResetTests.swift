import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

@Suite("performNewSession reset")
struct NewSessionResetTests {

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
