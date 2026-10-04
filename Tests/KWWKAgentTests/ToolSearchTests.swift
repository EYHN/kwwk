import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

private func namedTool(_ name: String, _ description: String, properties: [String: JSONValue] = [:]) -> AgentTool {
    AgentTool(
        name: name,
        label: name,
        description: description,
        parameters: .object(["type": "object", "properties": .object(properties)]),
        execute: { _, _, _, _ in AgentToolResult(content: [.text(TextContent(text: "\(name) ran"))]) }
    )
}

private struct TestFailure: Error {}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor ContextLog {
    var contexts: [Context] = []
    func record(_ context: Context) { contexts.append(context) }
}

@Suite("Tool search ranking")
struct ToolSearchRankingTests {
    @Test("tokenizer splits camelCase, drops stop words and singularizes")
    func tokenize() {
        #expect(ToolSearchRanker.tokenize("searchIssues in the HTTPServer") == ["search", "issue", "http", "server"])
        #expect(ToolSearchRanker.tokenize("mcp__github__list_pull_requests") == ["mcp", "github", "list", "pull", "request"])
    }

    @Test("BM25 ranks the most specific match first and ignores non-matches")
    func rank() {
        let documents = [
            ToolSearchDocument(tool: namedTool("mcp__gh__search_issues", "Search GitHub issues by query")),
            ToolSearchDocument(tool: namedTool("mcp__gh__create_issue", "Create a GitHub issue")),
            ToolSearchDocument(tool: namedTool("mcp__slack__post", "Post a Slack message")),
        ]
        let matches = ToolSearchRanker().rank(query: "search issues", documents: documents, limit: 5)
        #expect(matches.first?.name == "mcp__gh__search_issues")
        #expect(!matches.contains { $0.name == "mcp__slack__post" })
        #expect(ToolSearchRanker().rank(query: "the of", documents: documents, limit: 5).isEmpty)
        #expect(ToolSearchRanker().rank(query: "issue", documents: documents, limit: 1).count == 1)
    }

    @Test("schema property names and descriptions are searchable")
    func schemaText() {
        let tool = namedTool("mcp__db__run", "Run something", properties: [
            "sql": .object(["type": "string", "description": "PostgreSQL statement"]),
        ])
        let matches = ToolSearchRanker().rank(
            query: "sql statement",
            documents: [ToolSearchDocument(tool: tool), ToolSearchDocument(tool: namedTool("other", "unrelated"))],
            limit: 3
        )
        #expect(matches.map(\.name) == ["mcp__db__run"])
    }
}

@Suite("Tool catalog and transcript tool changes")
struct ToolCatalogTests {
    @Test("tool_search loads a deferred tool that the next request declares")
    func searchLoadsForNextRequest() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let log = ContextLog()
        faux.setResponses([
            .factory { context, _, _, _ in
                await log.record(context)
                return fauxAssistantMessage(
                    blocks: [fauxToolCall(name: toolSearchToolName, arguments: ["query": "github issues"], id: "search-1")],
                    stopReason: .toolUse
                )
            },
            .factory { context, _, _, _ in
                await log.record(context)
                return fauxAssistantMessage(
                    blocks: [fauxToolCall(name: "mcp__gh__search_issues", arguments: [:], id: "call-1")],
                    stopReason: .toolUse
                )
            },
            .factory { context, _, _, _ in
                await log.record(context)
                return fauxAssistantMessage("done")
            },
        ])

        let catalog = ToolCatalog()
        let agent = Agent(initialState: AgentInitialState(
            model: faux.getModel(),
            tools: [makeCalculateTool(), makeToolSearchTool(catalog: catalog)]
        ))
        catalog.setTools([
            namedTool("mcp__gh__search_issues", "Search GitHub issues"),
            namedTool("mcp__gh__get_file", "Read a file from a repository"),
            namedTool("mcp__docs__lookup", "Look up documentation"),
        ])
        catalog.bind(to: agent)

        try await agent.prompt("find the bug report")

        let contexts = await log.contexts
        try #require(contexts.count == 3)
        let first = Set((contexts[0].tools ?? []).map(\.name))
        #expect(first == ["calculate", toolSearchToolName])
        let second = Set((contexts[1].tools ?? []).map(\.name))
        #expect(second.contains("mcp__gh__search_issues"))
        #expect(!second.contains("mcp__gh__get_file"))

        // The transcript replays to exactly the tools of every request.
        let declarations = agent.state.messages.compactMap { message -> SystemMessage? in
            if case .system(let system) = message { return system }
            return nil
        }
        #expect(declarations.count == 2)
        #expect(declarations.last?.toolsAdded?.map(\.name) == ["mcp__gh__search_issues"])
        #expect(TranscriptTools.currentTools(in: agent.state.messages).map(\.name).sorted()
            == agent.state.effectiveTools.map(\.name).sorted())
        // The catalog feeds the request; the caller's own tools are untouched.
        #expect(agent.state.tools.map(\.name) == ["calculate", toolSearchToolName])
        // The loaded tool really ran.
        #expect(agent.state.messages.contains { message in
            if case .toolResult(let result) = message { return result.toolName == "mcp__gh__search_issues" && !result.isError }
            return false
        })
        // The first declaration directly follows the first prompt, before any
        // answer, so providers anchor the top-level tool list on it.
        #expect(TranscriptTools.initialDeclarationIndex(in: agent.state.messages) == 1)
    }

    @Test("an unchanged tool set adds no declarations on later prompts")
    func noRedundantDeclarations() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("one")), .message(fauxAssistantMessage("two"))])
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel(), tools: [makeCalculateTool()]))
        try await agent.prompt("first")
        try await agent.prompt("second")
        let count = agent.state.messages.filter { $0.role == .system }.count
        #expect(count == 1)
    }

    @Test("removing a tool records a removal")
    func removalIsDeclared() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("one")), .message(fauxAssistantMessage("two"))])
        let agent = Agent(initialState: AgentInitialState(
            model: faux.getModel(),
            tools: [makeCalculateTool(), namedTool("extra", "extra tool")]
        ))
        try await agent.prompt("first")
        agent.state.tools = [makeCalculateTool()]
        try await agent.prompt("second")
        guard case .system(let last)? = agent.state.messages.last(where: { $0.role == .system }) else {
            Issue.record("missing declaration")
            return
        }
        #expect(last.toolsRemoved == ["extra"])
        #expect(TranscriptTools.currentTools(in: agent.state.messages).map(\.name) == ["calculate"])
    }

    @Test("a restored tool keeps its transcript definition and runs once its source registers it")
    func restoredTools() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel(), tools: [makeCalculateTool()]))
        let gate = Gate()
        let catalog = ToolCatalog(owns: { $0.hasPrefix("mcp__") }, prepare: { _ in await gate.wait() })
        let declared = namedTool("mcp__a__one", "one").toKWWKAITool()
        // Builtins in the transcript are not the catalog's to restore.
        catalog.restore(from: [
            .system(SystemMessage(toolsAdded: [makeCalculateTool().toKWWKAITool(), declared])),
        ])
        catalog.bind(to: agent)

        // Before the server connects the tool is already declared, unchanged.
        #expect(agent.state.effectiveTools.map(\.name) == ["calculate", "mcp__a__one"])
        let restored = try #require(agent.state.effectiveTools.last)
        #expect(restored.toKWWKAITool() == declared)

        // A call waits for the source, then runs the registered tool.
        let call = Task { try await restored.execute("c1", .object([:]), nil, nil) }
        catalog.setTools([namedTool("mcp__a__one", "one"), namedTool("mcp__a__other", "other")])
        await gate.open()
        let result = try await call.value
        guard case .text(let text)? = result.content.first else { throw TestFailure() }
        #expect(text.text == "mcp__a__one ran")

        // A new session starts with nothing loaded.
        catalog.restore(from: [])
        #expect(agent.state.effectiveTools.map(\.name) == ["calculate"])
    }

    @Test("a restored tool its source never provides fails when called")
    func restoredToolWithoutSource() async throws {
        let catalog = ToolCatalog(owns: { _ in true })
        catalog.restore(from: [.system(SystemMessage(toolsAdded: [namedTool("mcp__gone__tool", "gone").toKWWKAITool()]))])
        let tool = try #require(catalog.tools.first)
        await #expect(throws: CodingToolError.self) {
            _ = try await tool.execute("c1", .object([:]), nil, nil)
        }
    }

    @Test("loading tools is not a context edit, so it never invalidates compaction")
    func loadingKeepsRevision() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel(), tools: [makeCalculateTool()]))
        let catalog = ToolCatalog()
        catalog.bind(to: agent)
        let before = agent.state.snapshotModelContext().revision
        catalog.setTools([namedTool("mcp__a__one", "issue search")])
        _ = await catalog.search(query: "issue", limit: 5)
        let after = agent.state.snapshotModelContext()
        #expect(after.revision == before)
        #expect(after.context.tools.map(\.name) == ["calculate", "mcp__a__one"])
    }

    @Test("compaction re-declares the tool state right after the recap")
    func compactionRedeclaresTools() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("summary of prior work"))])
        let model = faux.getModel()
        let reply = { (text: String) in
            Message.assistant(AssistantMessage(
                content: [.text(TextContent(text: text))], api: model.api, provider: model.provider, model: model.id
            ))
        }
        let calculate = makeCalculateTool().toKWWKAITool()
        let loaded = namedTool("mcp__gh__search", "search").toKWWKAITool()
        let messages: [Message] = [
            .system(SystemMessage(toolsAdded: [calculate])),
            .user(UserMessage(text: "please add feature X")),
            reply("working on it"),
            .system(SystemMessage(toolsAdded: [loaded])),
            .user(UserMessage(text: "any update?")),
            reply("step one done"),
        ]
        let agent = Agent(initialState: AgentInitialState(model: model, messages: messages))

        let outcome = await AgentContextCompactor.compactAgent(agent: agent, sessionId: "tool-compact")
        guard case .compacted = outcome else {
            Issue.record("compaction failed: \(outcome)")
            return
        }
        let compacted = agent.state.messages
        guard case .user? = compacted.first, case .system(let declaration) = compacted[1] else {
            Issue.record("expected recap then declaration, got \(compacted.map(\.role))")
            return
        }
        #expect(declaration.toolsAdded?.map(\.name) == ["calculate", "mcp__gh__search"])
        #expect(compacted.filter { $0.role == .system }.count == 1)
        #expect(TranscriptTools.initialDeclarationIndex(in: compacted) == 1)
        #expect(TranscriptTools.currentTools(in: compacted) == TranscriptTools.currentTools(in: messages))
    }

    @Test("resuming from a compaction marker restores the tool state without older entries")
    func resumeFromCompaction() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-tool-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let id = UUID().uuidString
        _ = try await store.create(id: id, cwd: "/tmp")
        let early = namedTool("mcp__early__tool", "early").toKWWKAITool()
        let late = namedTool("mcp__late__tool", "late").toKWWKAITool()
        try await store.append(id: id, cwd: "/tmp", messages: [
            .system(SystemMessage(toolsAdded: [early])),
            .user(UserMessage(text: "old history")),
        ])
        try await store.appendCompaction(
            id: id,
            cwd: "/tmp",
            replacementMessages: [
                .user(UserMessage(text: "recap")),
                .system(SystemMessage(toolsAdded: [early])),
            ],
            messagesCompacted: 2,
            reason: .compact
        )
        try await store.append(id: id, cwd: "/tmp", messages: [
            .user(UserMessage(text: "new prompt")),
            .system(SystemMessage(toolsAdded: [late])),
        ])

        let loaded = try await store.load(id: id, scope: .context)
        #expect(TranscriptTools.currentTools(in: loaded.messages).map(\.name) == ["mcp__early__tool", "mcp__late__tool"])
        #expect(loaded.messages.count == 4)
    }
}
