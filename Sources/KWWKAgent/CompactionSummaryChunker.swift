import KWWKAI

enum CompactionSummaryChunker {
    /// Packs complete turns when possible and otherwise falls back to
    /// tool-safe groups. The pipeline supplies the exact allowance for its
    /// current summary accumulator before each request. A single indivisible
    /// group may still exceed `maxTokens`; `CompactionSummaryGenerator`
    /// applies the final global transcript bound in that unavoidable case.
    static func chunks(
        _ messages: [Message],
        maxTokens: Int,
        limits: CompactionTranscriptSerializer.Limits
    ) -> [[Message]] {
        guard !messages.isEmpty else { return [] }
        let budget = max(1, maxTokens)
        let turns = turnUnits(messages)
        var chunks: [[Message]] = []
        var current: [Message] = []
        var currentQuarterTokenUnits = 0

        func appendUnit(_ unit: [Message]) {
            var unitUnits = serializedQuarterTokenUnits(
                unit,
                startingAt: current.count,
                limits: limits
            )
            let separatorUnits = current.isEmpty ? 0 : 1
            let candidateTokens = ContextTokenEstimator.tokens(
                forQuarterTokenUnits: currentQuarterTokenUnits + separatorUnits + unitUnits
            )
            if !current.isEmpty, candidateTokens > budget {
                chunks.append(current)
                current = []
                currentQuarterTokenUnits = 0
                // Record indices restart at zero in every chunk.
                unitUnits = serializedQuarterTokenUnits(unit, startingAt: 0, limits: limits)
            }
            if !current.isEmpty { currentQuarterTokenUnits += 1 }
            current.append(contentsOf: unit)
            currentQuarterTokenUnits += unitUnits
        }

        for turn in turns {
            if serializedTokens(turn, limits: limits) <= budget {
                appendUnit(turn)
            } else {
                for group in toolSafeGroups(
                    turn,
                    maxTokens: budget,
                    limits: limits
                ) {
                    appendUnit(group)
                }
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private static func turnUnits(_ messages: [Message]) -> [[Message]] {
        var turns: [[Message]] = []
        var current: [Message] = []
        for message in messages {
            if case .user = message, !current.isEmpty {
                turns.append(current)
                current = []
            }
            current.append(message)
        }
        if !current.isEmpty { turns.append(current) }
        return turns
    }

    /// Within an oversized turn, keep a call with its result. If one assistant
    /// issued enough parallel calls that the complete batch is itself too
    /// large, project it into ordered per-call groups. Every call/result then
    /// reaches a summary request instead of the middle of the batch being
    /// hidden by a global transcript preview.
    private static func toolSafeGroups(
        _ messages: [Message],
        maxTokens: Int,
        limits: CompactionTranscriptSerializer.Limits
    ) -> [[Message]] {
        var groups: [[Message]] = []
        var index = 0
        while index < messages.count {
            guard case .assistant(let assistant) = messages[index] else {
                groups.append([messages[index]])
                index += 1
                continue
            }

            var end = index + 1
            while end < messages.count, case .toolResult = messages[end] {
                end += 1
            }
            let results = messages[(index + 1)..<end].compactMap { message -> ToolResultMessage? in
                guard case .toolResult(let result) = message else { return nil }
                return result
            }
            let completeGroup = Array(messages[index..<end])
            if serializedTokens(completeGroup, limits: limits) <= maxTokens {
                groups.append(completeGroup)
            } else {
                groups.append(contentsOf: splitParallelToolGroup(
                    assistant: assistant,
                    results: results
                ))
            }
            index = end
        }
        return groups
    }

    private static func splitParallelToolGroup(
        assistant: AssistantMessage,
        results: [ToolResultMessage]
    ) -> [[Message]] {
        let calls = assistant.content.compactMap { block -> ToolCall? in
            guard case .toolCall(let call) = block else { return nil }
            return call
        }
        guard calls.count > 1 else {
            return [[.assistant(assistant)] + results.map(Message.toolResult)]
        }

        var groups: [[Message]] = []
        let narrative = assistant.content.filter { block in
            if case .toolCall = block { return false }
            return true
        }
        if !narrative.isEmpty {
            var narrativeMessage = assistant
            narrativeMessage.content = narrative
            groups.append([.assistant(narrativeMessage)])
        }

        var resultIndicesByToolCallId: [String: [Int]] = [:]
        resultIndicesByToolCallId.reserveCapacity(min(calls.count, results.count))
        for (resultIndex, result) in results.enumerated() {
            resultIndicesByToolCallId[result.toolCallId, default: []].append(resultIndex)
        }

        var matchedResultIndices = Set<Int>()
        matchedResultIndices.reserveCapacity(results.count)
        for call in calls {
            var callMessage = assistant
            callMessage.content = [.toolCall(call)]
            var group: [Message] = [.assistant(callMessage)]
            for resultIndex in resultIndicesByToolCallId[call.id] ?? [] {
                matchedResultIndices.insert(resultIndex)
                group.append(.toolResult(results[resultIndex]))
            }
            groups.append(group)
        }

        // Malformed provider output can contain orphan results. Keep each one
        // independently chunkable so a large orphan batch cannot collapse to
        // one opaque global preview.
        let orphanResults = results.enumerated().compactMap { index, result in
            matchedResultIndices.contains(index) ? nil : Message.toolResult(result)
        }
        groups.append(contentsOf: orphanResults.map { [$0] })
        return groups
    }

    private static func serializedTokens(
        _ messages: [Message],
        limits: CompactionTranscriptSerializer.Limits
    ) -> Int {
        ContextTokenEstimator.tokens(
            forQuarterTokenUnits: serializedQuarterTokenUnits(
                messages,
                startingAt: 0,
                limits: limits
            )
        )
    }

    private static func serializedQuarterTokenUnits(
        _ messages: [Message],
        startingAt baseIndex: Int,
        limits: CompactionTranscriptSerializer.Limits
    ) -> Int {
        ContextTokenEstimator.quarterTokenUnits(
            in: CompactionTranscriptSerializer.serialize(
                messages,
                startingAt: baseIndex,
                limits: limits
            )
        )
    }
}
