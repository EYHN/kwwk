import Foundation

/// Replay helpers for the tool state recorded by ``SystemMessage`` entries.
///
/// Ported from pi's `packages/ai/src/utils/transcript.ts`, narrowed to tool
/// state: kwwk keeps the system prompt in `Context.systemPrompt`, so only tool
/// additions and removals live in the transcript.
public enum TranscriptTools {
    /// The added and removed tools between two complete tool states.
    public struct Changes: Sendable, Hashable {
        public var toolsAdded: [Tool]
        public var toolsRemoved: [String]

        public init(toolsAdded: [Tool] = [], toolsRemoved: [String] = []) {
            self.toolsAdded = toolsAdded
            self.toolsRemoved = toolsRemoved
        }

        public var isEmpty: Bool { toolsAdded.isEmpty && toolsRemoved.isEmpty }
    }

    /// How a provider should declare tools for one request.
    public struct Resolution: Sendable, Hashable {
        /// Tools for the request's top-level tool list.
        public var requestTools: [Tool]
        /// When true, `requestTools` holds only the initial tools and every
        /// later system message must be encoded in place as a tool change.
        /// When false, `requestTools` is the complete current tool set and
        /// system messages must be dropped.
        public var anchorsChanges: Bool
    }

    /// Index of the initial tool declaration: the first system message, as
    /// long as no assistant turn precedes it. A fresh transcript starts with
    /// it; after compaction it directly follows the recap. A transcript whose
    /// first declaration came after the model already answered (a session
    /// recorded before tool declarations existed) has none, and is always
    /// sent with the full tool list.
    public static func initialDeclarationIndex(in messages: [Message]) -> Int? {
        for (index, message) in messages.enumerated() {
            switch message {
            case .system: return index
            case .assistant(let assistant):
                // Failed turns are never replayed (`repairToolFlow`), so the
                // answer must not change once they are dropped.
                if assistant.stopReason == .error || assistant.stopReason == .aborted { continue }
                return nil
            case .user, .toolResult: continue
            }
        }
        return nil
    }

    /// The tools declared by the initial declaration.
    public static func initialTools(in messages: [Message]) -> [Tool] {
        guard let index = initialDeclarationIndex(in: messages),
              case .system(let system) = messages[index] else { return [] }
        return system.toolsAdded ?? []
    }

    /// The tool state after replaying every system message in order.
    public static func currentTools(in messages: [Message]) -> [Tool] {
        var order: [String] = []
        var tools: [String: Tool] = [:]
        for message in messages {
            guard case .system(let system) = message else { continue }
            for name in system.toolsRemoved ?? [] {
                tools.removeValue(forKey: name)
                order.removeAll { $0 == name }
            }
            for tool in system.toolsAdded ?? [] {
                if tools[tool.name] != nil { order.removeAll { $0 == tool.name } }
                tools[tool.name] = tool
                order.append(tool.name)
            }
        }
        return order.compactMap { tools[$0] }
    }

    /// Compare two complete tool states. A changed definition is reported as
    /// an addition under the same name, which replaces the old definition.
    public static func changes(from previous: [Tool], to current: [Tool]) -> Changes {
        let previousByName = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        let currentNames = Set(current.map(\.name))
        let added = current.filter { previousByName[$0.name] != $0 }
        let removed = previous.map(\.name).filter { !currentNames.contains($0) }
        return Changes(toolsAdded: added, toolsRemoved: removed)
    }

    /// Whether the transcript contains a removal or a same-name
    /// redeclaration, which an addition-only transport cannot replay.
    public static func hasNonAdditiveChanges(in messages: [Message]) -> Bool {
        var declared = Set<String>()
        for message in messages {
            guard case .system(let system) = message else { continue }
            if !(system.toolsRemoved ?? []).isEmpty { return true }
            for tool in system.toolsAdded ?? [] where !declared.insert(tool.name).inserted {
                return true
            }
        }
        return false
    }

    /// Whether the transcript carries any system message.
    public static func hasSystemMessages(_ messages: [Message]) -> Bool {
        messages.contains { if case .system = $0 { return true } else { return false } }
    }

    /// Drop every system message. Providers that cannot encode tool changes
    /// send `Context.tools` as the full tool list instead.
    public static func withoutSystemMessages(_ messages: [Message]) -> [Message] {
        guard hasSystemMessages(messages) else { return messages }
        return messages.filter { if case .system = $0 { return false } else { return true } }
    }

    /// Decide how a request should declare its tools.
    ///
    /// In-place encoding requires a transport that supports it, a non-empty
    /// leading declaration to anchor the top-level list, and a transcript
    /// whose replayed state matches exactly what the caller wants to send.
    /// The last condition fails on turns that deliberately narrow the tools
    /// (a forced final turn), which then fall back to the full list.
    ///
    /// - Parameters:
    ///   - supportsChanges: whether the transport can encode tool changes.
    ///   - allowsNonAdditive: whether it can also encode removals and
    ///     redefinitions. Addition-only transports fall back to the full list
    ///     once the transcript contains either.
    public static func resolve(
        messages: [Message],
        tools: [Tool]?,
        supportsChanges: Bool,
        allowsNonAdditive: Bool
    ) -> Resolution {
        let tools = tools ?? []
        guard supportsChanges, hasSystemMessages(messages) else {
            return Resolution(requestTools: tools, anchorsChanges: false)
        }
        let initial = initialTools(in: messages)
        let consistent = !initial.isEmpty
            && sameToolSet(currentTools(in: messages), tools)
            && (allowsNonAdditive || !hasNonAdditiveChanges(in: messages))
        return consistent
            ? Resolution(requestTools: initial, anchorsChanges: true)
            : Resolution(requestTools: tools, anchorsChanges: false)
    }

    private static func sameToolSet(_ lhs: [Tool], _ rhs: [Tool]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        let byName = Dictionary(lhs.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        return rhs.allSatisfy { byName[$0.name] == $0 }
    }
}
