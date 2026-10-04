import Foundation
import Testing
@testable import KWWKCli
@testable import KWWKAgent
@testable import KWWKAI

#if os(macOS) || os(Linux)
/// Explicit opt-in only (`KWWK_LIVE_MCP=1`). Drives the TUI's MCP runtime
/// against a local fake MCP server with the logins stored in
/// `~/.kwwk/oauth.json`. Prints model, tool calls and cache usage per
/// request, and the provider's error message on failure; never prints
/// credentials.
///
/// `KWWK_LIVE_MCP_CASES` narrows the run, e.g. `anthropic:claude-opus-5-5`.
@Suite("Live MCP tool search", .serialized)
struct LiveMCPToolSearchTests {
    static let cases: [(store: String, model: String?)] = [
        ("anthropic", "claude-opus-5-5"),
        ("anthropic", "claude-haiku-4-5"),
        ("openai-codex", "gpt-5.5"),
        ("openai-codex", "gpt-6.1-sol"),
        ("kimi-coding", "k3"),
        ("zai", "glm-5.3"),
        ("cursor", nil),
    ]

    static let server = #"""
import json, sys

TOOLS = [
    {"name": "search_issues", "description": "Search the Acme issue tracker. Returns matching issue ids and titles.",
     "inputSchema": {"type": "object", "properties": {"query": {"type": "string", "description": "Words to search for"}}, "required": ["query"]}},
    {"name": "get_issue", "description": "Fetch one Acme issue with its full description.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}},
    {"name": "list_deploys", "description": "List recent Acme production deployments.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "page_oncall", "description": "Page the Acme on-call engineer.",
     "inputSchema": {"type": "object", "properties": {"message": {"type": "string"}}, "required": ["message"]}},
]
ISSUES = {"crash": "#4217 App crashes on launch when offline", "login": "#4302 Login button ignores Enter",
          "timeout": "#4400 Sync times out after 30 seconds"}

for line in sys.stdin:
    msg = json.loads(line)
    mid = msg.get("id")
    if mid is None:
        continue
    method = msg.get("method")
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "acme", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        p = msg["params"]; args = p.get("arguments") or {}
        if p["name"] == "search_issues":
            q = str(args.get("query", "")).lower()
            hits = [v for k, v in ISSUES.items() if k in q] or ["no issues found"]
            result = {"content": [{"type": "text", "text": "\n".join(hits)}]}
        else:
            result = {"content": [{"type": "text", "text": p["name"] + " is not available in this test"}]}
    else:
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}}) + "\n")
        sys.stdout.flush()
        continue
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}) + "\n")
    sys.stdout.flush()
"""#

    /// Long, stable instructions so every provider has a cacheable prefix.
    static let systemPrompt: String = {
        var lines = ["You are a terse engineering assistant for the Acme project. Answer in one short sentence."]
        for index in 1...160 {
            lines.append("Guideline \(index): when working on Acme component \(index % 17), prefer small reviewable changes, keep logs structured, document public behavior, and never page on-call for routine questions.")
        }
        return lines.joined(separator: "\n")
    }()

    struct Sandbox {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("kwwk-live-mcp-\(UUID().uuidString)")
            let kwwk = root.appendingPathComponent("home/.kwwk")
            try FileManager.default.createDirectory(at: kwwk, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("cwd"), withIntermediateDirectories: true)
            let script = root.appendingPathComponent("acme.py")
            try LiveMCPToolSearchTests.server.write(to: script, atomically: true, encoding: .utf8)
            let config: [String: Any] = ["mcpServers": ["acme": [
                "command": "python3", "args": [script.path],
                "description": "Acme issue tracker, deployments and on-call paging",
                "toolExposure": ["page_*": "hidden"],
            ]]]
            try JSONSerialization.data(withJSONObject: config).write(to: kwwk.appendingPathComponent("mcp.json"))
        }
        var home: String { root.appendingPathComponent("home").path }
        var cwd: String { root.appendingPathComponent("cwd").path }
    }

    struct Run {
        var toolCalls: [String] = []
        var usages: [Usage] = []
        var finalText = ""
        var stop: StopReason?
        var failure: String?

        var usageSummary: String {
            usages.enumerated().map { "#\($0.offset + 1) in=\($0.element.input) read=\($0.element.cacheRead) write=\($0.element.cacheWrite)" }
                .joined(separator: " | ")
        }
    }

    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var run = Run()
        func record(_ event: AgentEvent) {
            guard case .messageEnd(let message) = event, case .assistant(let assistant) = message else { return }
            lock.withLock {
                run.usages.append(assistant.usage)
                run.stop = assistant.stopReason
                if let failure = assistant.failure {
                    let detail = (assistant.errorMessage ?? failure.message).replacingOccurrences(of: "\n", with: " ").prefix(400)
                    run.failure = "\(failure.category.rawValue) status=\(failure.httpStatus.map(String.init) ?? "none") \(detail)"
                }
                if ProcessInfo.processInfo.environment["KWWK_LIVE_MCP_VERBOSE"] == "1" {
                    for block in assistant.content {
                        switch block {
                        case .text(let text): print("VERBOSE text: \(text.text.prefix(600))")
                        case .thinking(let thinking): print("VERBOSE thinking: \(thinking.thinking.prefix(600))")
                        case .toolCall(let call): print("VERBOSE call: \(call.name) \(call.arguments)")
                        case .fallback: break
                        }
                    }
                }
                for block in assistant.content {
                    switch block {
                    case .toolCall(let call): run.toolCalls.append(call.name)
                    case .text(let text): run.finalText = text.text
                    default: break
                    }
                }
            }
        }
        func take() -> Run { lock.withLock { let value = run; run = Run(); return value } }
    }

    static func prompt(_ agent: Agent, _ text: String, recorder: Recorder) async -> Run {
        let unsubscribe = agent.subscribe { event, _ in recorder.record(event) }
        defer { unsubscribe() }
        do { try await agent.prompt(text) } catch { recorder.lock.withLock { recorder.run.failure = "prompt threw" } }
        return recorder.take()
    }

    static func report(_ label: String, _ run: Run) {
        let excerpt = run.finalText.replacingOccurrences(of: "\n", with: " ").prefix(160)
        print("LIVE \(label) stop=\(run.stop.map { "\($0)" } ?? "nil") failure=\(run.failure ?? "none")")
        print("LIVE \(label) calls=\(run.toolCalls)")
        print("LIVE \(label) usage: \(run.usageSummary)")
        print("LIVE \(label) text: \(excerpt)")
    }

    @Test func toolSearchAcrossStoredLogins() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KWWK_LIVE_MCP"] == "1" else { return }
        let only = environment["KWWK_LIVE_MCP_CASES"].map { Set($0.split(separator: ",").map(String.init)) }
        let store = try OAuthStore(url: OAuthStore.defaultURL())

        for testCase in Self.cases {
            let label = "\(testCase.store):\(testCase.model ?? "default")"
            if let only, !only.contains(label) { continue }
            let sandbox = try Sandbox()
            defer { try? FileManager.default.removeItem(at: sandbox.root) }

            guard let resolved = try? await registerStored(
                storeId: testCase.store, store: store, modelOverride: testCase.model, primeToken: false
            ) else {
                print("LIVE \(label) skipped: no stored login")
                continue
            }
            let runtime = MCPRuntime(cwd: sandbox.cwd, homeDirectory: sandbox.home, environment: [:])
            await runtime.start()
            let sessionId = UUID().uuidString
            let agent = Agent(options: AgentOptions(
                initialState: AgentInitialState(systemPrompt: Self.systemPrompt, model: resolved.model, thinkingLevel: .medium),
                sessionId: sessionId,
                cwd: sandbox.cwd,
                maxTurns: 8,
                autoCompact: nil,
                authResolver: resolved.authResolver
            ))
            runtime.attach(to: agent, messages: [])
            let recorder = Recorder()

            let first = await Self.prompt(
                agent,
                "Using the Acme issue tracker, find the issue about the app crashing and tell me its number.",
                recorder: recorder
            )
            Self.report("\(label) [search]", first)
            #expect(first.toolCalls.first == toolSearchToolName, "\(label) should search before calling MCP tools")
            #expect(first.toolCalls.contains("mcp__acme__search_issues"), "\(label) should call the loaded MCP tool")
            #expect(first.finalText.contains("4217"), "\(label) should report the issue number")
            #expect(first.failure == nil, "\(label) failed: \(first.failure ?? "")")


            // Same session, tool already loaded: no new search needed.
            let second = await Self.prompt(agent, "Now search Acme issues about login and give me the number.", recorder: recorder)
            Self.report("\(label) [reuse]", second)
            #expect(second.finalText.contains("4302"), "\(label) should reuse the loaded tool")

            // Declared before the next request (Cursor runs a whole turn in one).
            let declared = TranscriptTools.currentTools(in: agent.state.messages).map(\.name)
            #expect(declared.contains("mcp__acme__search_issues"))
            #expect(!declared.contains("mcp__acme__page_oncall"))

            if testCase.store == "anthropic", testCase.model == "claude-opus-5-5" {
                // Resume into a fresh agent and runtime from the transcript.
                let resumedRuntime = MCPRuntime(cwd: sandbox.cwd, homeDirectory: sandbox.home, environment: [:])
                await resumedRuntime.start()
                let resumed = Agent(options: AgentOptions(
                    initialState: AgentInitialState(systemPrompt: Self.systemPrompt, model: resolved.model, thinkingLevel: .medium, messages: agent.state.messages),
                    sessionId: sessionId,
                    cwd: sandbox.cwd,
                    maxTurns: 8,
                    autoCompact: nil,
                    authResolver: resolved.authResolver
                ))
                // No waiting: the restored tool is declared before its server connects.
                resumedRuntime.attach(to: resumed, messages: resumed.state.messages)
                #expect(resumed.state.effectiveTools.contains { $0.name == "mcp__acme__search_issues" }, "resume should reload the tool")
                let third = await Self.prompt(resumed, "Search Acme issues about timeout and give me the number.", recorder: recorder)
                Self.report("\(label) [resume]", third)
                #expect(third.finalText.contains("4400"))
                #expect(!third.toolCalls.contains(toolSearchToolName), "resumed session should not need to search again")

                let outcome = await AgentContextCompactor.compactAgent(agent: resumed, sessionId: sessionId)
                print("LIVE \(label) [compact] outcome=\(outcome) roles=\(resumed.state.messages.map(\.role.rawValue))")
                let fourth = await Self.prompt(resumed, "Search Acme issues about crash once more and give me the number.", recorder: recorder)
                Self.report("\(label) [after-compact]", fourth)
                #expect(fourth.finalText.contains("4217"))
                await resumedRuntime.shutdown()
            }
            await runtime.shutdown()
            await closeProviderSession(sessionId: sessionId)
        }
    }
}
#endif

#if os(macOS) || os(Linux)
/// Cache baseline: the same two-request shape without any tool change.
@Suite("Live cache baseline", .serialized)
struct LiveCacheBaselineTests {
    @Test func secondRequestCacheWithoutToolChange() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let cases = environment["KWWK_LIVE_CACHE_BASELINE"] else { return }
        let store = try OAuthStore(url: OAuthStore.defaultURL())
        for label in cases.split(separator: ",").map(String.init) {
            let parts = label.split(separator: ":").map(String.init)
            let override = parts.count > 1 && parts[1] != "default" ? parts[1] : nil
            guard let resolved = try? await registerStored(storeId: parts[0], store: store, modelOverride: override, primeToken: false) else { continue }
            let lookup = AgentTool(
                name: "lookup_issue",
                label: "lookup",
                description: "Search the Acme issue tracker. Returns matching issue ids and titles.",
                parameters: ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]
            ) { _, _, _, _ in AgentToolResult(content: [.text(TextContent(text: "#4217 App crashes on launch when offline"))]) }
            let sessionId = UUID().uuidString
            let agent = Agent(options: AgentOptions(
                initialState: AgentInitialState(
                    systemPrompt: LiveMCPToolSearchTests.systemPrompt, model: resolved.model,
                    thinkingLevel: .medium, tools: [lookup]
                ),
                sessionId: sessionId, maxTurns: 6, autoCompact: nil, authResolver: resolved.authResolver
            ))
            let recorder = LiveMCPToolSearchTests.Recorder()
            let run = await LiveMCPToolSearchTests.prompt(agent, "Use lookup_issue to find the crash issue and tell me its number.", recorder: recorder)
            LiveMCPToolSearchTests.report("\(label) [baseline]", run)
            await closeProviderSession(sessionId: sessionId)
        }
    }
}
#endif
