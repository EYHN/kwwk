import Foundation
import KWWKAI

struct CompactionPlan: Sendable, Equatable {
    let previousSummary: String?
    let previousTurnPrefixSummary: String?
    /// Raw, trusted recap contents used only to carry deterministic facts.
    /// Summary prompts consume the decoded semantic fields above instead of
    /// receiving this XML envelope as prose.
    let previousRecapForFacts: String?
    let messagesToSummarize: [Message]
    let turnPrefixToSummarize: [Message]
    let recentTail: [Message]
    let firstKeptMessageIndex: Int
    let estimatedRecentTokens: Int
}

enum CompactionPlanner {
    static let recapOpenTag = "<previous-session-summary>"
    static let recapCloseTag = "</previous-session-summary>"
    private static let v2RecapOpenTag = "<kwwk-compaction version=\"2\">"
    private static let v2RecapCloseTag = "</kwwk-compaction>"

    private struct PreviousRecap {
        let index: Int
        let history: String?
        let turnPrefix: String?
        let factsSource: String
    }

    static func plan(
        messages: [Message],
        keepRecentTokens: Int
    ) -> CompactionPlan? {
        guard !messages.isEmpty else { return nil }

        let previous = leadingRecap(in: messages)
        let historyStart = previous.map { $0.index + 1 } ?? 0
        guard historyStart < messages.count else { return nil }
        let protectedUserStart = trailingUnansweredUserStart(
            in: messages,
            lowerBound: historyStart
        )

        let budget = max(1, keepRecentTokens)
        var suffixStart = messages.count
        var suffixTokens = 0

        for index in stride(from: messages.count - 1, through: historyStart, by: -1) {
            let messageTokens = ContextTokenEstimator.estimate(message: messages[index])
            if suffixStart < messages.count, suffixTokens + messageTokens > budget {
                break
            }
            suffixTokens += messageTokens
            suffixStart = index
        }

        // Multiple prompts can be queued before the provider gets a turn.
        // Keep that entire unanswered run verbatim: retaining only the newest
        // user message would silently turn earlier, never-sent prompts into
        // summary prose.
        if let protectedUserStart, suffixStart > protectedUserStart {
            suffixStart = protectedUserStart
            suffixTokens = estimatedTokens(in: Array(messages[suffixStart...]))
        }

        if suffixStart > historyStart,
           firstUserIndex(atOrAfter: suffixStart, messages: messages) == nil,
           let turnStart = lastUserIndex(atOrBefore: suffixStart, lowerBound: historyStart, messages: messages),
           suffixStart > turnStart {
            let splitCut = toolSafeCut(
                messages: messages,
                candidate: suffixStart,
                lowerBound: turnStart
            )
            if splitCut > turnStart, splitCut < messages.count {
                let tail = Array(messages[splitCut...])
                if let first = tail.first, case .toolResult = first {
                    return nil
                }
                let tailTokens = estimatedTokens(in: tail)
                if tailTokens > budget {
                    return wholeTurnSummaryPlan(
                        messages: messages,
                        previousRecap: previous,
                        historyStart: historyStart,
                        turnStart: turnStart
                    )
                }
                return CompactionPlan(
                    previousSummary: previous?.history,
                    previousTurnPrefixSummary: previous?.turnPrefix,
                    previousRecapForFacts: previous?.factsSource,
                    messagesToSummarize: Array(messages[historyStart..<turnStart]),
                    turnPrefixToSummarize: Array(messages[turnStart..<splitCut]),
                    recentTail: tail,
                    firstKeptMessageIndex: splitCut,
                    estimatedRecentTokens: tailTokens
                )
            }
        }

        var cut: Int
        if suffixStart <= historyStart {
            // A manual compact should still make progress when the complete
            // transcript fits under the recent-tail budget. Keep the newest
            // full turn verbatim and summarize at least one earlier turn.
            if let protectedUserStart {
                guard protectedUserStart > historyStart else { return nil }
                cut = protectedUserStart
            } else if let newestTurnStart = messages.indices.reversed().first(where: {
                $0 > historyStart && isUser(messages[$0])
            }) {
                cut = newestTurnStart
            } else if messages.count > historyStart {
                return wholeTurnSummaryPlan(
                    messages: messages,
                    previousRecap: previous,
                    historyStart: historyStart,
                    turnStart: historyStart
                )
            } else {
                return nil
            }
        } else {
            cut = firstUserIndex(atOrAfter: suffixStart, messages: messages) ?? suffixStart
        }

        cut = toolSafeCut(messages: messages, candidate: cut, lowerBound: historyStart)
        if cut <= historyStart,
           firstUserIndex(atOrAfter: historyStart, messages: messages) == nil {
            // After a recap, the remaining raw suffix can legitimately begin
            // with a completed assistant response or a tool call/result group.
            // Fold that non-user suffix into the next recap so repeated
            // compaction can always make progress.
            return wholeTurnSummaryPlan(
                messages: messages,
                previousRecap: previous,
                historyStart: historyStart,
                turnStart: historyStart
            )
        }
        guard cut > historyStart, cut <= messages.count else { return nil }

        let summarized = Array(messages[historyStart..<cut])
        guard !summarized.isEmpty else { return nil }
        let tail = Array(messages[cut...])
        if let first = tail.first, case .toolResult = first { return nil }

        return CompactionPlan(
            previousSummary: previous?.history,
            previousTurnPrefixSummary: previous?.turnPrefix,
            previousRecapForFacts: previous?.factsSource,
            messagesToSummarize: summarized,
            turnPrefixToSummarize: [],
            recentTail: tail,
            firstKeptMessageIndex: cut,
            estimatedRecentTokens: estimatedTokens(in: tail)
        )
    }

    static func summaryText(from message: Message) -> String? {
        guard case .user(let user) = message,
              user.source == .compaction else {
            return nil
        }
        return recapText(from: user)
    }

    /// Recognizes the envelope written by older compaction markers before
    /// `UserMessageSource.compaction` existed. Callers must establish trust
    /// from marker metadata before using this to upgrade a message.
    static func isLegacyRecapEnvelope(_ message: Message) -> Bool {
        guard case .user(let user) = message else { return false }
        return recapText(from: user) != nil
    }

    private static func recapText(from user: UserMessage) -> String? {
        let text = user.content.compactMap { block -> String? in
            guard case .text(let content) = block else { return nil }
            return content.text
        }.joined(separator: "\n")
        guard text.hasPrefix(recapOpenTag),
              let open = text.range(of: recapOpenTag),
              let close = text.range(of: recapCloseTag, range: open.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func leadingRecap(in messages: [Message]) -> PreviousRecap? {
        guard let first = messages.first,
              let rawContents = summaryText(from: first) else {
            return nil
        }
        let semantic = semanticRecap(from: rawContents)
        return PreviousRecap(
            index: 0,
            history: semantic.history,
            turnPrefix: semantic.turnPrefix,
            factsSource: rawContents
        )
    }

    private static func wholeTurnSummaryPlan(
        messages: [Message],
        previousRecap: PreviousRecap?,
        historyStart: Int,
        turnStart: Int
    ) -> CompactionPlan {
        if isCompletedTurn(messages.last) {
            return CompactionPlan(
                previousSummary: previousRecap?.history,
                previousTurnPrefixSummary: previousRecap?.turnPrefix,
                previousRecapForFacts: previousRecap?.factsSource,
                messagesToSummarize: Array(messages[historyStart...]),
                turnPrefixToSummarize: [],
                recentTail: [],
                firstKeptMessageIndex: messages.count,
                estimatedRecentTokens: 0
            )
        }
        return CompactionPlan(
            previousSummary: previousRecap?.history,
            previousTurnPrefixSummary: previousRecap?.turnPrefix,
            previousRecapForFacts: previousRecap?.factsSource,
            messagesToSummarize: Array(messages[historyStart..<turnStart]),
            turnPrefixToSummarize: Array(messages[turnStart...]),
            recentTail: [],
            firstKeptMessageIndex: messages.count,
            estimatedRecentTokens: 0
        )
    }

    private static func isCompletedTurn(_ message: Message?) -> Bool {
        guard case .assistant(let assistant) = message else { return false }
        return assistant.stopReason != .toolUse
    }

    private static func firstUserIndex(atOrAfter start: Int, messages: [Message]) -> Int? {
        guard start < messages.count else { return nil }
        return (max(0, start)..<messages.count).first(where: { isUser(messages[$0]) })
    }

    private static func lastUserIndex(
        atOrBefore end: Int,
        lowerBound: Int,
        messages: [Message]
    ) -> Int? {
        guard !messages.isEmpty, end >= lowerBound else { return nil }
        return stride(from: min(end, messages.count - 1), through: lowerBound, by: -1)
            .first(where: { isUser(messages[$0]) })
    }

    private static func toolSafeCut(
        messages: [Message],
        candidate: Int,
        lowerBound: Int
    ) -> Int {
        guard candidate < messages.count else { return messages.count }
        var cut = max(candidate, lowerBound)

        while cut < messages.count, case .toolResult(let result) = messages[cut] {
            if let owner = owningAssistantIndex(
                for: result.toolCallId,
                before: cut,
                lowerBound: lowerBound,
                messages: messages
            ) {
                cut = owner
                break
            }
            // Orphan result: summarize it rather than projecting a tail that
            // begins with an invalid result-only message.
            cut += 1
        }
        return cut
    }

    private static func owningAssistantIndex(
        for toolCallId: String,
        before index: Int,
        lowerBound: Int,
        messages: [Message]
    ) -> Int? {
        guard index > lowerBound else { return nil }
        for candidate in stride(from: index - 1, through: lowerBound, by: -1) {
            guard case .assistant(let assistant) = messages[candidate] else { continue }
            if assistant.content.contains(where: { block in
                guard case .toolCall(let call) = block else { return false }
                return call.id == toolCallId
            }) {
                return candidate
            }
        }
        return nil
    }

    private static func isUser(_ message: Message) -> Bool {
        if case .user = message { return true }
        return false
    }

    private static func trailingUnansweredUserStart(
        in messages: [Message],
        lowerBound: Int
    ) -> Int? {
        guard lowerBound < messages.count, isUser(messages[messages.count - 1]) else {
            return nil
        }
        var start = messages.count - 1
        while start > lowerBound, isUser(messages[start - 1]) {
            start -= 1
        }
        return start
    }

    private static func estimatedTokens(in messages: [Message]) -> Int {
        messages.reduce(0) { $0 + ContextTokenEstimator.estimate(message: $1) }
    }

    /// Converts the versioned recap envelope back into the semantic strings
    /// that were originally rendered into it. Legacy recaps predate the
    /// envelope and are already plain durable summaries.
    private static func semanticRecap(
        from rawContents: String
    ) -> (history: String?, turnPrefix: String?) {
        let envelope = rawContents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard envelope.hasPrefix(v2RecapOpenTag),
              envelope.hasSuffix(v2RecapCloseTag) else {
            return (nonEmpty(envelope), nil)
        }

        return (
            decodedSection(named: "history", in: envelope),
            decodedSection(named: "current-turn-prefix", in: envelope)
        )
    }

    private static func decodedSection(named name: String, in envelope: String) -> String? {
        let openTag = "<\(name)>"
        let closeTag = "</\(name)>"
        guard let open = envelope.range(of: openTag),
              let close = envelope.range(
                  of: closeTag,
                  range: open.upperBound..<envelope.endIndex
              ) else {
            return nil
        }
        let encoded = String(envelope[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return nonEmpty(unescapeXML(encoded))
    }

    /// Reverse exactly one application of `CompactionFactsExtractor.escapeXML`.
    /// Decode `&amp;` last so an original literal entity such as `&amp;` remains
    /// an entity string rather than being decoded twice.
    private static func unescapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }
}
