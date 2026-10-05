import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

private func deferredTool(_ name: String, _ description: String) -> AgentTool {
    AgentTool(
        name: name,
        label: name,
        description: description,
        parameters: .object(["type": "object", "properties": .object([:])]),
        execute: { _, _, _, _ in AgentToolResult(content: [.text(TextContent(text: "\(name) ran"))]) }
    )
}

@Suite("Tool catalog lifecycle")
struct ToolCatalogLifecycleTests {
    @Test("a bound catalog adds tool_search and its instructions to every request")
    func boundCatalogDefaults() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(systemPrompt: "base", model: faux.getModel(), tools: []))
        #expect(agent.state.effectiveTools.isEmpty)
        let catalog = ToolCatalog(instructions: "<servers/>")
        catalog.bind(to: agent)
        #expect(agent.state.effectiveTools.map(\.name) == [toolSearchToolName])
        #expect(agent.state.effectiveSystemPrompt == "base\n\n<servers/>")
        #expect(agent.state.systemPrompt == "base")
        let snapshot = agent.state.snapshotModelContext().context
        #expect(snapshot.systemPrompt == "base\n\n<servers/>")
        #expect(snapshot.tools.map(\.name) == [toolSearchToolName])
        catalog.setInstructions("<other/>")
        #expect(agent.state.effectiveSystemPrompt == "base\n\n<other/>")
        catalog.setInstructions(nil)
        #expect(agent.state.effectiveSystemPrompt == "base")
    }

    @Test("a loaded tool whose source goes away is unloaded; registering it again makes it searchable only")
    func sourceGoesAway() async {
        let catalog = ToolCatalog()
        let one = deferredTool("mcp__a__one", "issue search")
        catalog.setTools([one, deferredTool("mcp__a__two", "other")])
        _ = await catalog.search(query: "issue", limit: 5)
        #expect(catalog.tools.map(\.name) == ["mcp__a__one"])
        // A child loaded it too.
        let child = catalog.makeChild()
        _ = await child.search(query: "issue", limit: 5)
        #expect(child.tools.map(\.name) == ["mcp__a__one"])

        catalog.setTools([])
        #expect(catalog.tools.isEmpty)
        #expect(child.tools.isEmpty)

        catalog.setTools([one])
        #expect(catalog.tools.isEmpty)
        #expect(child.tools.isEmpty)
        let found = await catalog.search(query: "issue", limit: 5)
        #expect(found.map(\.name) == ["mcp__a__one"])
        #expect(catalog.tools.map(\.name) == ["mcp__a__one"])
    }

    @Test("a tool that stays registered stays loaded across tool list changes")
    func survivesUnrelatedChanges() async {
        let catalog = ToolCatalog()
        let one = deferredTool("mcp__a__one", "issue search")
        catalog.setTools([one])
        _ = await catalog.search(query: "issue", limit: 5)
        catalog.setTools([one, deferredTool("mcp__b__new", "new")])
        #expect(catalog.tools.map(\.name) == ["mcp__a__one"])
    }

    @Test("retainLoaded keeps only tools the messages call")
    func retainLoaded() async {
        let catalog = ToolCatalog()
        catalog.setTools([deferredTool("mcp__a__used", "alpha"), deferredTool("mcp__a__idle", "alpha")])
        _ = await catalog.search(query: "alpha", limit: 5)
        #expect(Set(catalog.tools.map(\.name)) == ["mcp__a__used", "mcp__a__idle"])
        let call = Message.assistant(AssistantMessage(
            content: [.toolCall(ToolCall(id: "c1", name: "mcp__a__used", arguments: .object([:])))],
            api: "test", provider: "test", model: "test"
        ))
        let unloaded = catalog.retainLoaded(usedIn: [.user(UserMessage(text: "hi")), call])
        #expect(unloaded == ["mcp__a__idle"])
        #expect(catalog.tools.map(\.name) == ["mcp__a__used"])
    }

    @Test("tools loaded since the last user message are kept even if not called yet")
    func keepsFreshLoads() async {
        let catalog = ToolCatalog()
        catalog.setTools([deferredTool("mcp__a__old", "alpha"), deferredTool("mcp__a__fresh", "beta")])
        _ = await catalog.search(query: "alpha", limit: 5)
        _ = await catalog.search(query: "beta", limit: 5)
        let messages: [Message] = [
            .system(SystemMessage(toolsAdded: [deferredTool("mcp__a__old", "alpha").toKWWKAITool()])),
            .user(UserMessage(text: "find the beta thing")),
            .system(SystemMessage(toolsAdded: [deferredTool("mcp__a__fresh", "beta").toKWWKAITool()])),
        ]
        #expect(catalog.unusedLoadedTools(in: messages) == ["mcp__a__old"])
    }

    @Test("tool_search names unavailable sources when it finds fewer tools than asked")
    func unavailableNote() async throws {
        let catalog = ToolCatalog(unavailableSources: {
            [ToolSourceStatus(name: "linear_work", reason: "requires authorization")]
        })
        catalog.setTools([deferredTool("mcp__a__one", "issue search")])
        let search = catalog.searchTool
        let partial = try await search.execute("s1", ["query": "issue", "limit": 5], nil, nil)
        guard case .text(let text)? = partial.content.first else { throw CancellationError() }
        #expect(text.text.contains("Loaded 1 tool"))
        #expect(text.text.hasSuffix("Not connected: linear_work (requires authorization)"))
        let none = try await search.execute("s2", ["query": "zzz"], nil, nil)
        guard case .text(let empty)? = none.content.first else { throw CancellationError() }
        #expect(empty.text == "No matching tools found.\n\nNot connected: linear_work (requires authorization)")

        let healthy = ToolCatalog()
        let result = try await healthy.searchTool.execute("s3", ["query": "zzz"], nil, nil)
        guard case .text(let plain)? = result.content.first else { throw CancellationError() }
        #expect(plain.text == "No matching tools found.")
    }

    @Test("compaction unloads catalog tools not called since the last compaction")
    func compactionUnloads() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("summary of prior work"))])
        let model = faux.getModel()
        let catalog = ToolCatalog()
        catalog.setTools([deferredTool("mcp__gh__used", "alpha"), deferredTool("mcp__gh__idle", "alpha")])
        _ = await catalog.search(query: "alpha", limit: 5)
        let call = Message.assistant(AssistantMessage(
            content: [.toolCall(ToolCall(id: "c1", name: "mcp__gh__used", arguments: .object([:])))],
            api: model.api, provider: model.provider, model: model.id
        ))
        let messages: [Message] = [
            .system(SystemMessage(toolsAdded: [
                deferredTool("mcp__gh__used", "alpha").toKWWKAITool(),
                deferredTool("mcp__gh__idle", "alpha").toKWWKAITool(),
            ])),
            .user(UserMessage(text: "please add feature X")),
            call,
            .toolResult(ToolResultMessage(
                toolCallId: "c1", toolName: "mcp__gh__used", content: [.text(TextContent(text: "ok"))], isError: false
            )),
            .user(UserMessage(text: "any update?")),
            .assistant(AssistantMessage(
                content: [.text(TextContent(text: "step one done"))], api: model.api, provider: model.provider, model: model.id
            )),
        ]
        let agent = Agent(initialState: AgentInitialState(model: model, messages: messages))
        catalog.bind(to: agent)
        let outcome = await AgentContextCompactor.compactAgent(agent: agent, sessionId: "catalog-compact")
        guard case .compacted = outcome else {
            Issue.record("compaction failed: \(outcome)")
            return
        }
        #expect(catalog.tools.map(\.name) == ["mcp__gh__used"])
        // The recap re-declares only what stayed loaded.
        let compacted = agent.state.messages
        #expect(compacted.filter { $0.role == .system }.count == 1)
        #expect(TranscriptTools.currentTools(in: compacted).map(\.name) == ["mcp__gh__used"])
    }
}
