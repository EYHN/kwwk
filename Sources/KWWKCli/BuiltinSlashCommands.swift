import Foundation
import KWWKAI
import KWWKAgent

/// Register the V1 set of builtin slash commands on `registry`. Keep these
/// focused on things a user actually needs mid-session; heavier flows
/// (login, config persistence) live on the `kwwk` binary instead.
@MainActor
func registerBuiltinSlashCommands(_ registry: SlashCommandRegistry) {
    registry.register(SlashCommand(
        name: "model",
        description: "Pick a model for this session",
        handler: handleModelCommand
    ))
    registry.register(SlashCommand(
        name: "compact",
        description: "Summarize the transcript to reclaim context",
        handler: handleCompactCommand
    ))
    registry.register(SlashCommand(
        name: "help",
        description: "List available slash commands",
        handler: { ctx, _ in
            ctx.notify(Style.dimmed("  available slash commands:"))
            for cmd in registry.all {
                ctx.notify(Style.dimmed("    /\(cmd.name) — \(cmd.description)"))
            }
        }
    ))
}

/// `/model` — opens a modal with every model the currently-authenticated
/// provider supports. Selection updates `agent.state.model` for the next
/// LLM request; the swap is session-scoped (restart = back to default).
///
/// Cross-provider switching (Codex → Anthropic or vice versa) needs a
/// second provider registered on APIRegistry at startup, which is out of
/// scope for V1.
@MainActor
private func handleModelCommand(_ ctx: SlashContext, _ args: String) async {
    let current = ctx.agent.state.model
    let agentProvider = current.provider
    let catalogKey = catalogProviderKey(forAgentProvider: agentProvider)

    let available = ModelsCatalog.models(for: catalogKey)
        .sorted { $0.id < $1.id }

    if available.isEmpty {
        ctx.notify(Style.error("  /model: no catalog entries for provider '\(agentProvider)'"))
        return
    }

    let modal = ModelSelectorModal(
        title: "Select a model  (provider: \(agentProvider))",
        models: available,
        currentModelId: current.id,
        onSelect: { [agent = ctx.agent, notify = ctx.notify, modal = ctx.modal] picked in
            let rebuilt = adoptFields(from: current, into: picked)
            agent.state.model = rebuilt
            modal.close()
            if picked.id == current.id {
                notify(Style.dimmed("  /model: already on \(picked.id)"))
            } else {
                notify(Style.dimmed("  /model: switched \(current.id) → \(picked.id)"))
            }
        },
        onCancel: { [modal = ctx.modal, notify = ctx.notify] in
            modal.close()
            notify(Style.dimmed("  /model: cancelled"))
        }
    )
    ctx.modal.open(modal)
}

/// Map an in-session agent `Model.provider` to the key used in
/// `ModelsCatalog.byProvider`. They're mostly identical except for Codex:
/// the chatgpt.com variant registers as `chatgpt-codex` on the agent side,
/// while the catalog lists its models under `openai-codex`.
private func catalogProviderKey(forAgentProvider provider: String) -> String {
    switch provider {
    case "chatgpt-codex": return "openai-codex"
    default: return provider
    }
}

/// Carry the current-session provider routing (api string, baseUrl, any
/// custom headers) over from the old model onto the newly-selected one.
/// The catalog lists models by their canonical provider (`openai-codex`),
/// but the live agent uses a provider-variant routing key
/// (`chatgpt-codex`, the Codex endpoint we registered at startup). Without
/// this copy the first request after a switch would hit the wrong
/// `APIRegistry` entry or try to call the canonical OpenAI endpoint that
/// we never registered a token for.
private func adoptFields(from current: Model, into picked: Model) -> Model {
    Model(
        id: picked.id,
        name: picked.name,
        api: current.api,
        provider: current.provider,
        baseUrl: current.baseUrl,
        reasoning: picked.reasoning,
        input: picked.input,
        cost: picked.cost,
        contextWindow: picked.contextWindow,
        maxTokens: current.maxTokens,
        headers: current.headers
    )
}

// MARK: - /compact

/// Minimum message count worth compacting. Below this the user probably
/// hasn't said enough for a summary to help; we short-circuit so the LLM
/// doesn't get a pointless request.
private let compactMinMessages = 4

/// `/compact` — fire a one-shot LLM summarize call with the current
/// transcript, then replace `agent.state.messages` with a single
/// user-role "previous-session-summary" message. The system prompt and
/// tool registrations stay intact so the next turn behaves normally;
/// only the transcript is compressed.
///
/// Blocking rules:
///   - If the agent is currently streaming, refuse (user should Esc first).
///   - If there are fewer than `compactMinMessages`, say so and bail.
@MainActor
private func handleCompactCommand(_ ctx: SlashContext, _ args: String) async {
    let agent = ctx.agent
    if agent.state.isStreaming {
        ctx.notify(Style.error("  /compact: agent is busy; stop it first (Esc)"))
        return
    }
    let snapshot = agent.state.messages
    if snapshot.count < compactMinMessages {
        ctx.notify(Style.dimmed("  /compact: only \(snapshot.count) message(s); nothing to compact"))
        return
    }

    ctx.notify(Style.dimmed("  /compact: summarizing \(snapshot.count) messages…"))

    do {
        let summary = try await summarizeTranscript(
            messages: snapshot,
            model: agent.state.model,
            apiKeyResolver: agent.apiKeyResolver
        )
        let recap = Message.user(UserMessage(content: [
            .text(TextContent(text:
                """
                <previous-session-summary>
                \(summary)
                </previous-session-summary>
                """
            ))
        ]))
        agent.state.messages = [recap]
        ctx.notify(Style.prompt("  /compact: compacted \(snapshot.count) messages → 1 recap"))
    } catch {
        let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        ctx.notify(Style.error("  /compact: \(msg)"))
    }
}

/// Render a chat history into a plain-text transcript for the summarizer.
/// Tool output is aggressively capped so a single verbose `ls -R` or build
/// log doesn't drown out everything useful in the summary.
private func renderForSummary(_ messages: [Message]) -> String {
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

private enum CompactError: Error, LocalizedError {
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
private func summarizeTranscript(
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
