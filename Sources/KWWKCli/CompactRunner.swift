import Foundation
import KWWKAI
import KWWKAgent

/// Minimum message count worth compacting. Below this the user (or the
/// auto-compact driver) probably hasn't seen enough of a conversation for
/// a summary to help; we short-circuit so the LLM doesn't burn a round
/// trip on three pleasantries.
let compactMinMessages = 4

/// Outcome of a `performCompact` call. Callers decide how to render
/// each case (status line, notification, silent log, etc.) — the runner
/// stays pure.
enum CompactOutcome: Sendable {
    case compacted(messagesCompacted: Int, hasRunningTasksLedger: Bool)
    case refusedAgentBusy
    case refusedTooFewMessages(count: Int)
    case failed(String)
}

/// Run the shared compact flow: validate → grab a running-task snapshot →
/// one-shot LLM summarize → replace `agent.state.messages` with a single
/// `<previous-session-summary>` recap. Returns the outcome; never
/// surfaces anything to the UI itself.
///
/// Used by both the manual `/compact` slash command and the
/// `AutoCompactController` threshold watcher, so the compact semantics
/// stay identical regardless of who pulls the trigger.
@MainActor
func performCompact(
    agent: Agent,
    backgroundManager: BackgroundTaskManager,
    sessionId: String,
    // The isStreaming check prevents racing agent.state.messages with a
    // live agent loop. That is the right default for /compact (the user
    // can invoke it any time) and for the post-agentEnd deferred path.
    // For the between-turns hook the guard is inverted: we run *inside*
    // the loop, in a windowed gap where no LLM call is in flight and the
    // loop is awaiting the hook — safe to compact. Pass true to skip.
    ignoreStreaming: Bool = false
) async -> CompactOutcome {
    if !ignoreStreaming && agent.state.isStreaming {
        return .refusedAgentBusy
    }
    let snapshot = agent.state.messages
    if snapshot.count < compactMinMessages {
        return .refusedTooFewMessages(count: snapshot.count)
    }

    // Capture running background tasks BEFORE the LLM call so even if
    // one of them finishes mid-summary we still carry the state the
    // current turn was acting against. `runningTasksSummary` returns ""
    // when nothing is running; trim before deciding whether to
    // append the section to the recap.
    let runningTasks = await backgroundManager
        .runningTasksSummary(sessionId: sessionId)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    do {
        let summary = try await summarizeTranscript(
            messages: snapshot,
            model: agent.state.model,
            apiKeyResolver: agent.apiKeyResolver
        )
        var body = """
        <previous-session-summary>
        \(summary)
        </previous-session-summary>
        """
        if !runningTasks.isEmpty {
            body += "\n\n<running-background-tasks>\n\(runningTasks)\n</running-background-tasks>"
        }
        let recap = Message.user(UserMessage(content: [.text(TextContent(text: body))]))
        agent.state.messages = [recap]
        return .compacted(
            messagesCompacted: snapshot.count,
            hasRunningTasksLedger: !runningTasks.isEmpty
        )
    } catch {
        let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        return .failed(reason)
    }
}

/// Render a chat history into a plain-text transcript for the summarizer.
/// Tool output is aggressively capped so a single verbose `ls -R` or build
/// log doesn't drown out everything useful in the summary.
func renderForSummary(_ messages: [Message]) -> String {
    let toolOutputCap = 500
    return messages.compactMap { msg -> String? in
        switch msg {
        case .user(let u):
            let text = u.content.compactMap { block -> String? in
                if case .text(let t) = block { return t.text }
                return nil
            }.joined(separator: "\n")
            return text.isEmpty ? nil : "User:\n\(text)"
        case .assistant(let a):
            var parts: [String] = []
            for block in a.content {
                switch block {
                case .text(let t):
                    if !t.text.isEmpty { parts.append(t.text) }
                case .toolCall(let tc):
                    parts.append("<tool-call name=\"\(tc.name)\" />")
                case .thinking:
                    continue  // omit — summarizer doesn't need to re-reason
                }
            }
            return parts.isEmpty ? nil : "Assistant:\n\(parts.joined(separator: "\n"))"
        case .toolResult(let tr):
            let text = tr.content.compactMap { block -> String? in
                if case .text(let t) = block { return t.text }
                return nil
            }.joined(separator: "\n")
            let capped = text.count > toolOutputCap
                ? String(text.prefix(toolOutputCap)) + "… [\(text.count - toolOutputCap) chars elided]"
                : text
            return "Tool(\(tr.toolName)):\n\(capped)"
        }
    }.joined(separator: "\n\n")
}

/// Render a dimmed, full-width boundary marker that sits in scrollback
/// to show the user "everything above this line was summarized". Used
/// by both `/compact` and the auto-compact driver so the two paths
/// leave an identical visual trail.
///
/// Returns three lines (leading blank, rule, trailing blank) so callers
/// can hand them straight to `TUI.commit(_:)`.
func renderCompactBoundary(messagesCompacted: Int, hasRunningTasksLedger: Bool, width: Int) -> [String] {
    var label = "compacted"
    if hasRunningTasksLedger { label += " (+ running-task ledger)" }
    let prefix = "── "
    let spacedLabel = " \(label) "
    let overhead = prefix.count + spacedLabel.count
    let fill = max(3, width - overhead)
    let rule = Style.dimmed(prefix + spacedLabel + String(repeating: "─", count: fill))
    return ["", rule, ""]
}

enum CompactError: Error, LocalizedError {
    case summarizationFailed(String)
    case emptySummary

    var errorDescription: String? {
        switch self {
        case .summarizationFailed(let reason): return "summarization failed: \(reason)"
        case .emptySummary: return "LLM returned an empty summary"
        }
    }
}

/// Fire a one-shot LLM call (no tools, isolated system prompt) to produce
/// a compressed recap of the conversation. The call uses the same model +
/// api-key resolver as the agent, so Codex / Anthropic / etc. all work
/// transparently.
func summarizeTranscript(
    messages: [Message],
    model: Model,
    apiKeyResolver: (@Sendable (String) async -> String?)?
) async throws -> String {
    let transcript = renderForSummary(messages)

    let systemPrompt = """
    You are summarizing a coding-agent conversation so it can be resumed \
    with a compressed context. Produce a concise recap that preserves:
      • the user's goal and any decisions already agreed on
      • concrete file paths touched and function / module names referenced
      • in-flight work (partial commits, failing tests, open questions)
      • outstanding asks the user made that aren't answered yet

    Omit:
      • pleasantries and rhetorical framing
      • verbose tool output unless a specific line of it is load-bearing
      • step-by-step reasoning (just the conclusions)

    Write for a future agent resuming the session, not the user. Bullet \
    points are fine. Target under 400 words.
    """

    let userPrompt = """
    Conversation to summarize:

    \(transcript)
    """

    let context = Context(
        systemPrompt: systemPrompt,
        messages: [.user(UserMessage(content: [.text(TextContent(text: userPrompt))]))],
        tools: []
    )

    var apiKey: String?
    if let resolver = apiKeyResolver {
        apiKey = await resolver(model.provider)
    }
    let options = StreamOptions(apiKey: apiKey)

    let response = try await stream(model: model, context: context, options: options)
    let result = await response.result()

    if result.stopReason == .error {
        throw CompactError.summarizationFailed(result.errorMessage ?? "unknown")
    }
    let texts = result.content.compactMap { block -> String? in
        if case .text(let t) = block { return t.text }
        return nil
    }
    let summary = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if summary.isEmpty {
        throw CompactError.emptySummary
    }
    return summary
}
