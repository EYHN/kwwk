import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

@Suite("Subagent transcripts")
struct SubagentTranscriptTests {
    @Test("child session ids map to valid transcript file ids")
    func transcriptSessionIds() {
        let id = subagentTranscriptSessionId(
            "bot.developer.f5e349073aebf74d:subagent:general:C8FBFC20-1870-4FC4-B134-3712E36E2F01"
        )
        #expect(id == "bot.developer.f5e349073aebf74d.subagent.general.C8FBFC20-1870-4FC4-B134-3712E36E2F01")
        #expect(SessionStore.isValidSessionId(id))

        let unparented = subagentTranscriptSessionId("subagent:code reviewer:ABC")
        #expect(unparented == "subagent.code.reviewer.ABC")
        #expect(SessionStore.isValidSessionId(unparented))

        #expect(subagentTranscriptSessionId("::x::") == "x")
        #expect(subagentTranscriptSessionId(":::") == "subagent")
    }

    @Test("transcripts live in a subagents directory beside persistent sessions only")
    func transcriptStoreDirectory() async throws {
        #expect(SessionStore().subagentTranscripts == nil)
        let root = URL(fileURLWithPath: "/tmp/kwwk-sessions")
        let store = try #require(SessionStore(directory: root).subagentTranscripts)
        #expect(await store.isPersistent)
        let directory = await store.directory
        #expect(directory.standardizedFileURL.path == root.appendingPathComponent("subagents").standardizedFileURL.path)
    }

    @Test("a child run is written to its own file, outside the parent listing")
    func childRunIsRecorded() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(transcriptYield("first deliverable"))])
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parentStore = SessionStore(directory: root)
        let transcripts = try #require(parentStore.subagentTranscripts)
        let toolset = transcriptToolset(
            model: faux.getModel(),
            sessionId: "bot.developer.parent",
            transcriptStore: transcripts
        )

        let result = try await tool(toolset, "agent").execute("launch", launchArgs(), nil, nil)
        #expect(detail(result, "agent_id") == "mini-1")

        let sessions = await transcripts.list()
        #expect(sessions.count == 1)
        let info = try #require(sessions.first)
        #expect(info.id.hasPrefix("bot.developer.parent.subagent.mini."))
        #expect(info.title == "mini-1 (mini): transcript test")
        #expect(info.model == faux.getModel().id)

        let loaded = try await transcripts.load(id: info.id)
        let texts = loaded.messages.flatMap(texts)
        #expect(texts.contains { $0.contains("do the transcript test") })
        #expect(loaded.messages.contains { message in
            guard case .assistant(let assistant) = message else { return false }
            return assistant.content.contains { block in
                if case .toolCall(let call) = block { return call.name == "subagent_yield" }
                return false
            }
        })
        #expect(loaded.messages.contains { message in
            if case .toolResult(let result) = message { return result.toolName == "subagent_yield" }
            return false
        })

        // The parent store lists only parent sessions.
        #expect(await parentStore.list().isEmpty)
    }

    @Test("a resumed child appends its new run to the same file")
    func resumedChildAppends() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(transcriptYield("first deliverable")),
            .message(transcriptYield("second deliverable")),
        ])
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcripts = try #require(SessionStore(directory: root).subagentTranscripts)
        let toolset = transcriptToolset(
            model: faux.getModel(),
            sessionId: "resume-parent",
            transcriptStore: transcripts
        )

        _ = try await tool(toolset, "agent").execute("launch", launchArgs(), nil, nil)
        let firstCount = try await transcripts.load(id: #require(transcripts.list().first).id).messages.count

        let resumed = try await tool(toolset, "agent_send").execute(
            "follow-up",
            .object([
                "agent_id": .string("mini-1"),
                "message": .string("now do the second part"),
            ]),
            nil,
            nil
        )
        #expect(detail(resumed, "status") == "completed")

        let sessions = await transcripts.list()
        #expect(sessions.count == 1)
        let loaded = try await transcripts.load(id: #require(sessions.first).id)
        let allTexts = loaded.messages.flatMap(texts)
        #expect(allTexts.filter { $0.contains("do the transcript test") }.count == 1)
        #expect(allTexts.contains(subagentFollowUpMessageText("now do the second part")))
        #expect(loaded.messages.count > firstCount)
        // The title is written once, by the first run.
        #expect(sessions.first?.title == "mini-1 (mini): transcript test")
    }

    @Test("without a transcript store nothing is written")
    func noStoreWritesNothing() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(transcriptYield("done"))])
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let toolset = transcriptToolset(
            model: faux.getModel(),
            sessionId: "memory-only",
            transcriptStore: nil
        )

        _ = try await tool(toolset, "agent").execute("launch", launchArgs(), nil, nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kwwk-subagent-transcripts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func transcriptToolset(
    model: Model,
    sessionId: String,
    transcriptStore: SessionStore?
) -> SubagentToolset {
    createSubagentToolset(
        cwd: FileManager.default.currentDirectoryPath,
        model: model,
        childTools: .readOnly,
        subagents: [SubagentDefinition(
            name: "mini",
            description: "Transcript test child.",
            prompt: "Complete the test and use the required yield tool.",
            tools: .readOnly
        )],
        sessionId: sessionId,
        bashEnvironment: testBashEnvironment,
        transcriptStore: transcriptStore
    )
}

private func tool(_ toolset: SubagentToolset, _ name: String) throws -> AgentTool {
    try #require(toolset.tools.first { $0.name == name })
}

private func launchArgs() -> JSONValue {
    .object([
        "description": .string("transcript test"),
        "prompt": .string("do the transcript test"),
        "subagent_type": .string("mini"),
    ])
}

private func transcriptYield(_ result: String) -> AssistantMessage {
    fauxAssistantMessage(
        blocks: [fauxToolCall(
            name: "subagent_yield",
            arguments: .object([
                "status": .string("complete"),
                "result": .string(result),
            ]),
            id: UUID().uuidString
        )],
        stopReason: .toolUse
    )
}

private func detail(_ result: AgentToolResult, _ key: String) -> String? {
    guard case .object(let details) = result.details ?? .null,
          case .string(let value) = details[key] ?? .null else {
        return nil
    }
    return value
}

private func texts(_ message: Message) -> [String] {
    switch message {
    case .user(let user):
        return user.content.compactMap { block in
            if case .text(let text) = block { return text.text }
            return nil
        }
    default:
        return []
    }
}
