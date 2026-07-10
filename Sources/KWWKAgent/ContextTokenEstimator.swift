import Foundation
import KWWKAI

struct ContextTokenEstimate: Sendable, Equatable {
    let providerReported: Int?
    let locallyEstimated: Int

    var effective: Int {
        max(providerReported ?? 0, locallyEstimated)
    }
}

/// Conservative, provider-independent context sizing used for compaction
/// planning. It deliberately estimates the semantic wire payload instead of
/// encoding `Message` wholesale: timestamps, billing metadata, and provider
/// attribution are persisted fields but are not prompt tokens.
enum ContextTokenEstimator {
    static let imageTokenAllowance = 1_024

    static func estimate(messages: [Message], model: Model? = nil) -> ContextTokenEstimate {
        ContextTokenEstimate(
            providerReported: latestValidProviderUsage(in: messages, model: model),
            locallyEstimated: messages.reduce(0) { $0 + estimate(message: $1) }
        )
    }

    static func estimate(context: AgentContext, model: Model? = nil) -> ContextTokenEstimate {
        var local = estimate(text: context.systemPrompt) + 8
        local += context.messages.reduce(0) { $0 + estimate(message: $1) }
        for tool in context.tools {
            local += 12
            local += estimate(text: tool.name)
            local += estimate(text: tool.description)
            local += estimate(json: tool.parameters)
        }
        return ContextTokenEstimate(
            providerReported: latestValidProviderUsage(in: context.messages, model: model),
            locallyEstimated: local
        )
    }

    static func estimate(message: Message) -> Int {
        var tokens = 6 // role and message framing
        switch message {
        case .user(let user):
            for block in user.content {
                switch block {
                case .text(let text):
                    tokens += estimate(text: text.text)
                    tokens += estimate(text: text.textSignature ?? "")
                case .image:
                    tokens += imageTokenAllowance
                }
            }

        case .assistant(let assistant):
            for block in assistant.content {
                switch block {
                case .text(let text):
                    tokens += estimate(text: text.text)
                    tokens += estimate(text: text.textSignature ?? "")
                case .thinking(let thinking):
                    tokens += estimate(text: thinking.thinking)
                    tokens += estimate(text: thinking.thinkingSignature ?? "")
                case .toolCall(let call):
                    tokens += 8
                    tokens += estimate(text: call.id)
                    tokens += estimate(text: call.name)
                    tokens += estimate(json: call.arguments)
                    tokens += estimate(text: call.thoughtSignature ?? "")
                }
            }

        case .toolResult(let result):
            tokens += estimate(text: result.toolCallId)
            tokens += estimate(text: result.toolName)
            if let details = result.details {
                tokens += estimate(json: details)
            }
            for block in result.content {
                switch block {
                case .text(let text):
                    tokens += estimate(text: text.text)
                    tokens += estimate(text: text.textSignature ?? "")
                case .image:
                    tokens += imageTokenAllowance
                }
            }
        }
        return max(1, tokens)
    }

    static func estimate(text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return tokens(forQuarterTokenUnits: quarterTokenUnits(in: text))
    }

    /// Additive representation of the text heuristic. Callers that build a
    /// larger serialized payload incrementally can sum these units and round
    /// once, avoiding repeated scans without changing the estimate.
    static func quarterTokenUnits(in text: String) -> Int {
        var quarterTokenUnits = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                quarterTokenUnits += 1
            } else if scalar.value > 0xFFFF {
                // Emoji and supplementary-plane symbols commonly split into
                // more than one token. Bias high instead of risking overflow.
                quarterTokenUnits += 8
            } else {
                // Treat CJK and other non-ASCII scalars as roughly one token.
                quarterTokenUnits += 4
            }
        }
        return quarterTokenUnits
    }

    static func tokens(forQuarterTokenUnits units: Int) -> Int {
        guard units > 0 else { return 0 }
        return max(1, (units + 3) / 4)
    }

    static func latestValidProviderUsage(in messages: [Message], model: Model? = nil) -> Int? {
        let recapTimestamp: Int64? = {
            guard let first = messages.first,
                  CompactionPlanner.summaryText(from: first) != nil,
                  case .user(let user) = first else {
                return nil
            }
            return user.timestamp
        }()

        for index in messages.indices.reversed() {
            let message = messages[index]
            guard case .assistant(let assistant) = message,
                  assistant.stopReason != .error,
                  assistant.stopReason != .aborted else {
                continue
            }
            if let model,
               (assistant.model != model.id || assistant.provider != model.provider) {
                continue
            }
            // Assistant usage retained in the raw tail describes the old,
            // pre-compaction request. Only a response produced after the recap
            // is a valid provider anchor for the projected context.
            if let recapTimestamp, assistant.timestamp <= recapTimestamp {
                continue
            }
            let usage = assistant.usage
            let components = usage.input + usage.output + usage.cacheRead + usage.cacheWrite
            let reported = max(usage.totalTokens, components)
            if reported > 0 {
                let appendedTokens = messages.index(after: index) < messages.endIndex
                    ? messages[messages.index(after: index)...].reduce(0) {
                        $0 + estimate(message: $1)
                    }
                    : 0
                return reported + appendedTokens
            }
        }
        return nil
    }

    private static func estimate(json: JSONValue) -> Int {
        guard let data = try? canonicalEncoder().encode(json),
              let text = String(data: data, encoding: .utf8) else {
            return 0
        }
        return estimate(text: text)
    }

    private static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
