import Foundation
import KWWKAI

// MARK: - Ranking

/// A tool as the ranker sees it: its name and searchable text.
public struct ToolSearchDocument: Sendable, Hashable {
    public var name: String
    public var text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }

    /// Search text of a tool: the name, the name with `_` as spaces, the
    /// description, and schema property names and descriptions.
    public init(tool: AgentTool) {
        var parts = [tool.name, tool.name.replacingOccurrences(of: "_", with: " "), tool.description]
        Self.appendSchemaText(tool.parameters, to: &parts)
        self.init(
            name: tool.name,
            text: parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: " ")
        )
    }

    private static func appendSchemaText(_ schema: JSONValue, to parts: inout [String]) {
        guard case .object(let object) = schema else { return }
        if case .string(let description)? = object["description"] { parts.append(description) }
        if case .object(let properties)? = object["properties"] {
            for name in properties.keys.sorted() {
                parts.append(name)
                if let property = properties[name] { appendSchemaText(property, to: &parts) }
            }
        }
        if let items = object["items"] { appendSchemaText(items, to: &parts) }
        for key in ["anyOf", "oneOf", "allOf"] {
            if case .array(let variants)? = object[key] {
                for variant in variants { appendSchemaText(variant, to: &parts) }
            }
        }
    }
}

/// Okapi BM25 over tool metadata, ported from pi's tool-search extension.
/// Ties keep document order.
public struct ToolSearchRanker: Sendable {
    public var k1: Double
    public var b: Double

    public init(k1: Double = 1.2, b: Double = 0.75) {
        self.k1 = k1
        self.b = b
    }

    public struct Match: Sendable, Hashable {
        public var name: String
        public var score: Double
    }

    public func rank(query: String, documents: [ToolSearchDocument], limit: Int) -> [Match] {
        var seen = Set<String>()
        let queryTerms = Self.tokenize(query).filter { seen.insert($0).inserted }
        guard !queryTerms.isEmpty, !documents.isEmpty, limit > 0 else { return [] }
        let termCounts: [[String: Int]] = documents.map { document in
            Self.tokenize(document.text).reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        let lengths = termCounts.map { $0.values.reduce(0, +) }
        let total = lengths.reduce(0, +)
        let averageLength = total > 0 ? Double(total) / Double(documents.count) : 1
        let documentCount = Double(documents.count)
        var idf: [String: Double] = [:]
        for term in queryTerms {
            let frequency = Double(termCounts.filter { $0[term] != nil }.count)
            idf[term] = log(1 + (documentCount - frequency + 0.5) / (frequency + 0.5))
        }
        var matches: [(index: Int, match: Match)] = []
        for (index, document) in documents.enumerated() {
            var score = 0.0
            let norm = k1 * (1 - b + b * Double(lengths[index]) / averageLength)
            for term in queryTerms {
                guard let count = termCounts[index][term] else { continue }
                let tf = Double(count)
                score += (idf[term] ?? 0) * (tf * (k1 + 1)) / (tf + norm)
            }
            if score > 0 { matches.append((index, Match(name: document.name, score: score))) }
        }
        return matches
            .sorted { $0.match.score != $1.match.score ? $0.match.score > $1.match.score : $0.index < $1.index }
            .prefix(limit)
            .map(\.match)
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in",
        "is", "it", "of", "on", "or", "that", "the", "this", "to", "with",
    ]

    /// Lowercase terms, split at camelCase boundaries and non-alphanumerics,
    /// without stop words, naively singularized.
    static func tokenize(_ text: String) -> [String] {
        var terms: [String] = []
        var current = ""
        var previous: Character?
        let characters = Array(text)
        func flush() {
            if !current.isEmpty {
                let term = current.lowercased()
                if !stopWords.contains(term) { terms.append(stem(term)) }
            }
            current = ""
        }
        for (index, character) in characters.enumerated() {
            guard character.isASCII, character.isLetter || character.isNumber else {
                flush()
                previous = nil
                continue
            }
            if let previous, character.isUppercase {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                // "fooBar" -> foo|Bar, "HTTPServer" -> HTTP|Server.
                if previous.isLowercase || previous.isNumber
                    || (previous.isUppercase && (next?.isLowercase ?? false)) {
                    flush()
                }
            }
            current.append(character)
            previous = character
        }
        flush()
        return terms
    }

    /// Naive singular form, so `issues` matches `issue`.
    static func stem(_ term: String) -> String {
        if term.count > 4, term.hasSuffix("ies") { return String(term.dropLast(3)) + "y" }
        if term.count > 4, ["ches", "shes", "sses", "xes", "zes"].contains(where: { term.hasSuffix($0) }) {
            return String(term.dropLast(2))
        }
        if term.count > 3, term.hasSuffix("s"), !term.hasSuffix("ss") { return String(term.dropLast()) }
        return term
    }
}

// MARK: - Catalog

/// Deferred tools, such as MCP server tools, hidden from the model until
/// `tool_search` loads them.
///
/// A catalog feeds an agent through `AgentState.toolSource`: the agent loop
/// reads the loaded tools before each request and records every change in
/// the transcript. The caller's own `AgentState.tools` are never touched.
public final class ToolCatalog: @unchecked Sendable {
    private let lock = NSLock()
    /// Every registered tool, in registration order.
    private var registered: [AgentTool] = []
    /// Loaded tool names, in load order.
    private var loaded: [String] = []
    /// Definitions of loaded tools that are not registered (yet), restored
    /// from a transcript: a server that is still connecting must not make a
    /// resumed session lose its tools.
    private var restored: [String: Tool] = [:]
    private let prepare: @Sendable (CancellationHandle?) async -> Void

    /// - Parameter prepare: Awaited before searching and before a restored
    ///   tool runs, e.g. to wait for MCP servers that are still connecting.
    public init(prepare: @escaping @Sendable (CancellationHandle?) async -> Void = { _ in }) {
        self.prepare = prepare
    }

    /// Feed `agent` this catalog's loaded tools.
    public func bind(to agent: Agent) {
        agent.state.toolSource = { [weak self] in self?.tools ?? [] }
    }

    /// Replace the registered tools.
    public func setTools(_ tools: [AgentTool]) {
        lock.withLock { registered = tools }
    }

    /// Make the loaded tools exactly `tools`, as when a session starts,
    /// resumes or is replaced. Pass the deferred tools a transcript declares.
    public func restore(loaded tools: [Tool]) {
        lock.withLock {
            loaded = tools.map(\.name)
            restored = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    /// Every registered tool, loaded or not.
    public var registeredTools: [AgentTool] {
        lock.withLock { registered }
    }

    /// The loaded tools, in load order. A loaded tool whose source has not
    /// registered it (yet) keeps its restored definition and waits for the
    /// source when called.
    public var tools: [AgentTool] {
        lock.withLock {
            let byName = Dictionary(registered.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            return loaded.compactMap { name in
                byName[name] ?? restored[name].map(restoredTool)
            }
        }
    }

    /// Rank the registered tools that are not loaded yet and load the matches.
    public func search(query: String, limit: Int, cancellation: CancellationHandle? = nil) async -> [AgentTool] {
        await prepare(cancellation)
        if cancellation?.isCancelled == true { return [] }
        return lock.withLock {
            let candidates = registered.filter { !loaded.contains($0.name) }
            let byName = Dictionary(candidates.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let matches = ToolSearchRanker()
                .rank(query: query, documents: candidates.map(ToolSearchDocument.init(tool:)), limit: limit)
                .compactMap { byName[$0.name] }
            loaded.append(contentsOf: matches.map(\.name))
            return matches
        }
    }

    private func registeredTool(named name: String) -> AgentTool? {
        lock.withLock { registered.first { $0.name == name } }
    }

    private func restoredTool(_ definition: Tool) -> AgentTool {
        AgentTool(
            name: definition.name,
            label: definition.name,
            description: definition.description,
            parameters: definition.parameters
        ) { [weak self] toolCallId, args, cancellation, onUpdate in
            guard let self else { throw CodingToolError.runtime("\(definition.name) is no longer available") }
            await self.prepare(cancellation)
            guard let tool = self.registeredTool(named: definition.name) else {
                throw CodingToolError.runtime("\(definition.name) is not available: its server did not provide it")
            }
            return try await tool.execute(toolCallId, args, cancellation, onUpdate)
        }
    }
}

// MARK: - Tool

public let toolSearchToolName = "tool_search"
public let defaultToolSearchLimit = 8

/// Description kept static so it never changes as tools are registered,
/// which would invalidate the prompt cache.
let toolSearchDescription = """
Searches deferred tool metadata with BM25 and loads the matching tools for your next call.

Some tools, such as the tools of MCP servers, are not provided to you upfront. Use this tool \
(`\(toolSearchToolName)`) to find and load the tools you need. For MCP tool discovery, always use \
`\(toolSearchToolName)`.
"""

/// The `tool_search` tool for a catalog.
public func makeToolSearchTool(catalog: ToolCatalog) -> AgentTool {
    var tool = AgentTool(
        name: toolSearchToolName,
        label: "Tool search",
        description: toolSearchDescription,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Search query for deferred tools."),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "description": .string("Maximum number of tools to load. Defaults to \(defaultToolSearchLimit)."),
                ]),
            ]),
            "required": .array([.string("query")]),
        ]),
        execute: { _, args, cancellation, _ in
            guard case .object(let object) = args,
                  case .string(let query)? = object["query"],
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CodingToolError.invalidArgument("tool_search: query must not be empty")
            }
            var limit = defaultToolSearchLimit
            if case .int(let value)? = object["limit"] {
                guard value > 0 else { throw CodingToolError.invalidArgument("tool_search: limit must be positive") }
                limit = value
            }
            let tools = await catalog.search(query: query, limit: limit, cancellation: cancellation)
            try cancellation?.throwIfCancelled()
            guard !tools.isEmpty else {
                return AgentToolResult(
                    content: [.text(TextContent(text: "No matching tools found."))],
                    details: .object(["loaded": .array([])]),
                    uiDisplay: ["no matching tools"]
                )
            }
            let lines = tools.map { tool -> String in
                let summary = tool.description.split(whereSeparator: \.isNewline).first
                    .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                return "- \(tool.name): \(summary)"
            }
            let text = "Loaded \(tools.count) tool\(tools.count == 1 ? "" : "s"). They are available from your next call:\n"
                + lines.joined(separator: "\n")
            return AgentToolResult(
                content: [.text(TextContent(text: text))],
                details: .object(["loaded": .array(tools.map { .string($0.name) })]),
                uiDisplay: ["loaded \(tools.map(\.name).joined(separator: ", "))"]
            )
        }
    )
    tool.omitsBlankOptionalArguments = true
    return tool
}
