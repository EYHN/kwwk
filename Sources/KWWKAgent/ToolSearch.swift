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

/// Deferred tools, such as MCP server tools, that stay hidden from the model
/// until `tool_search` (or a resumed transcript) loads them, kept in sync with
/// an agent's live tool set.
///
/// Built-in tools stay owned by the caller. The catalog only adds and removes
/// the tools it registered and loaded. Every change goes through
/// `AgentState.tools`, so the agent loop declares it in the transcript before
/// the next provider request.
public final class ToolCatalog: @unchecked Sendable {
    public struct Entry: Sendable {
        public var tool: AgentTool
        public var source: String
    }

    private let lock = NSLock()
    /// Registration order, used for stable tool ordering.
    private var entries: [Entry] = []
    /// Deferred tools loaded so far, in load order.
    private var loaded: [String] = []
    /// Loaded names restored from a transcript whose tools are not
    /// registered yet (e.g. an MCP server still connecting).
    private var pendingRestore: Set<String> = []
    /// Names this catalog placed into the agent's tool set at the last sync.
    private var injected: Set<String> = []
    private weak var agent: Agent?
    private var searchPreparation: (@Sendable () async -> Void)?

    public init() {}

    /// Keep `agent.state.tools` in sync with this catalog, re-checked before
    /// every provider request so a model switch takes effect.
    public func bind(to agent: Agent) {
        lock.withLock {
            if self.agent !== agent { injected = [] }
            self.agent = agent
        }
        agent.prepareTools = { [weak self] in self?.sync() }
        sync()
    }

    /// Whether the model's harness discovers tools on its own. Cursor's
    /// agent keeps advertised tools behind its own keyword search, so a
    /// catalog hands it every tool instead of hiding them behind
    /// `tool_search` as well.
    public static func modelDiscoversTools(_ model: Model) -> Bool {
        model.api == "cursor-agent"
    }

    /// Work `tool_search` awaits before searching, such as waiting for MCP
    /// servers that are still connecting.
    public func setSearchPreparation(_ preparation: (@Sendable () async -> Void)?) {
        lock.withLock { searchPreparation = preparation }
    }

    /// Replace every tool registered under `source`.
    public func setTools(_ tools: [AgentTool], source: String) {
        lock.withLock {
            let incoming = tools.map { Entry(tool: $0, source: source) }
            var merged: [Entry] = []
            var inserted = false
            for entry in entries {
                if entry.source == source {
                    if !inserted { merged.append(contentsOf: incoming); inserted = true }
                } else {
                    merged.append(entry)
                }
            }
            if !inserted { merged.append(contentsOf: incoming) }
            entries = merged
            let names = Set(entries.map(\.tool.name))
            for name in pendingRestore where names.contains(name) {
                if !loaded.contains(name) { loaded.append(name) }
            }
            pendingRestore.subtract(names)
        }
        sync()
    }

    /// Make the loaded deferred tools exactly those a transcript had loaded,
    /// as when a session starts, resumes, or is replaced. Names not
    /// registered yet are loaded as soon as they are.
    public func restoreLoadedTools(from messages: [Message]) {
        let declared = TranscriptTools.currentTools(in: messages).map(\.name)
        lock.withLock {
            loaded = []
            pendingRestore = []
            let registered = Set(entries.map(\.tool.name))
            for name in declared {
                if registered.contains(name) {
                    if !loaded.contains(name) { loaded.append(name) }
                } else {
                    pendingRestore.insert(name)
                }
            }
        }
        sync()
    }

    /// Whether any tool is registered.
    public var hasTools: Bool {
        lock.withLock { !entries.isEmpty }
    }

    public var registeredEntries: [Entry] {
        lock.withLock { entries }
    }

    /// Rank the deferred tools that are not loaded yet and load the matches.
    public func searchAndLoad(query: String, limit: Int) async -> [AgentTool] {
        let preparation = lock.withLock { searchPreparation }
        await preparation?()
        let matches: [AgentTool] = lock.withLock {
            let candidates = entries.filter { !loaded.contains($0.tool.name) }
            let ranked = ToolSearchRanker().rank(
                query: query,
                documents: candidates.map { ToolSearchDocument(tool: $0.tool) },
                limit: limit
            )
            let byName = Dictionary(candidates.map { ($0.tool.name, $0.tool) }, uniquingKeysWith: { first, _ in first })
            let tools = ranked.compactMap { byName[$0.name] }
            loaded.append(contentsOf: tools.map(\.name))
            return tools
        }
        if !matches.isEmpty { sync() }
        return matches
    }

    /// The loaded tools, in load order.
    public var activeTools: [AgentTool] {
        lock.withLock { activeToolsLocked(exposeAll: false) }
    }

    private func activeToolsLocked(exposeAll: Bool) -> [AgentTool] {
        if exposeAll { return entries.map(\.tool) }
        let byName = Dictionary(entries.map { ($0.tool.name, $0.tool) }, uniquingKeysWith: { first, _ in first })
        return loaded.compactMap { byName[$0] }
    }

    /// Push the catalog's active tools into the bound agent, leaving the
    /// caller's own tools untouched. A catalog tool never shadows one of them.
    public func sync() {
        lock.withLock {
            guard let agent else { return }
            let current = agent.state.tools
            let base = current.filter { !injected.contains($0.name) }
            let baseNames = Set(base.map(\.name))
            let exposeAll = Self.modelDiscoversTools(agent.state.model)
            let additions = activeToolsLocked(exposeAll: exposeAll).filter { !baseNames.contains($0.name) }
            let next = base + additions
            injected = Set(additions.map(\.name))
            let unchanged = next.count == current.count && zip(next, current).allSatisfy { lhs, rhs in
                lhs.name == rhs.name && lhs.description == rhs.description && lhs.parameters == rhs.parameters
            }
            if !unchanged { agent.state.tools = next }
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
///
/// `sources` names what the deferred tools come from (for example MCP servers
/// and what they do). It is appended to the description so harnesses that
/// discover tools by keyword (Cursor) can find `tool_search` by those names.
/// Keep it stable for the session: it is part of the tool definition.
public func makeToolSearchTool(catalog: ToolCatalog, sources: [String] = []) -> AgentTool {
    var description = toolSearchDescription
    if !sources.isEmpty {
        description += "\n\nDeferred tools are available from:\n"
            + sources.map { "- \($0)" }.joined(separator: "\n")
    }
    var tool = AgentTool(
        name: toolSearchToolName,
        label: "Tool search",
        description: description,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Search query for deferred tools."),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum number of tools to load. Defaults to \(defaultToolSearchLimit)."),
                ]),
            ]),
            "required": .array([.string("query")]),
        ]),
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            guard case .object(let object) = args,
                  case .string(let query)? = object["query"],
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CodingToolError.invalidArgument("tool_search: query must not be empty")
            }
            var limit = defaultToolSearchLimit
            switch object["limit"] {
            case .int(let value)?: limit = value
            case .double(let value)? where value.rounded() == value: limit = Int(value)
            case nil, .null?: break
            default: throw CodingToolError.invalidArgument("tool_search: limit must be a positive integer")
            }
            guard limit > 0 else {
                throw CodingToolError.invalidArgument("tool_search: limit must be a positive integer")
            }
            let tools = await catalog.searchAndLoad(query: query, limit: limit)
            let text: String
            if tools.isEmpty {
                text = "No matching tools found."
            } else {
                let lines = tools.map { tool -> String in
                    let summary = tool.description
                        .split(whereSeparator: \.isNewline).first
                        .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                    return "- \(tool.name): \(summary)"
                }
                text = "Loaded \(tools.count) tool\(tools.count == 1 ? "" : "s"). They are available from your next call:\n"
                    + lines.joined(separator: "\n")
            }
            return AgentToolResult(
                content: [.text(TextContent(text: text))],
                details: .object(["loaded": .array(tools.map { .string($0.name) })]),
                uiDisplay: [tools.isEmpty
                    ? "no matching tools"
                    : "loaded \(tools.map(\.name).joined(separator: ", "))"]
            )
        }
    )
    tool.omitsBlankOptionalArguments = true
    return tool
}
