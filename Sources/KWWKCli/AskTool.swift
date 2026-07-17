import Foundation
import KWWKAI
import KWWKAgent

/// The model-facing `ask` tool (omp's `ask` ported to kwwk): mid-turn
/// clarifying questions answered through a TUI selector modal. UI-only —
/// registered by the coding TUI next to `goal`, never by `makeCodingAgent`,
/// so headless runs and subagents never see it.

/// One selectable option of an ask question.
struct AskOption: Sendable, Equatable {
    let label: String
    let description: String?
}

/// One question parsed from the model's `ask` call.
struct AskQuestion: Sendable, Equatable {
    let id: String
    let question: String
    let options: [AskOption]
    let multi: Bool
    let recommended: Int?
}

/// Everything the TUI needs to present one question of a call: the question
/// itself plus wizard context (progress + ←/→ availability) and the previous
/// answer to restore when the user navigated back to it.
struct AskPrompt: Sendable {
    let question: AskQuestion
    /// `"2/3"` in a multi-question wizard; nil for a single question.
    let progressText: String?
    let allowBack: Bool
    let allowForward: Bool
    let previousSelection: [String]
    let previousCustomInput: String?
}

/// The user's response to one presented question.
enum AskOutcome: Sendable, Equatable {
    /// Enter on an option / Done, → to advance keeping the current state, or
    /// a submitted "Other" free-text answer. An empty `selected` with nil
    /// `customInput` is a skip (wizard →) — the answer line reads
    /// `(no selection)`.
    case answered(selected: [String], customInput: String?)
    /// ← pressed on a non-first wizard question. Carries the question's
    /// current state so in-progress selections survive the round trip
    /// (omp saves the answer before navigating).
    case back(selected: [String], customInput: String?)
    /// Esc — the whole `ask` call is torn down and the run aborted.
    case cancelled
}

/// One answered question, kept for result shaping and the transcript.
struct AskAnswer: Sendable, Equatable {
    let id: String
    let question: String
    let options: [String]
    let multi: Bool
    let selectedOptions: [String]
    let customInput: String?
}

/// Async bridge to the TUI: suspend the tool until the user answers the
/// presented question. The cancellation handle lets the presenter tear the
/// modal down when the run is aborted out from under it.
typealias AskPresenter = @Sendable (AskPrompt, CancellationHandle?) async -> AskOutcome

enum Ask {
    /// Appended by the UI to every question; confirming it opens free-text
    /// entry. The model is told not to offer its own "Other".
    static let otherOptionLabel = "Other (type your own)"
    static let recommendedSuffix = " (Recommended)"

    // MARK: - Argument parsing

    static func parseQuestions(_ args: JSONValue) throws -> [AskQuestion] {
        guard case .object(let obj) = args,
              case .array(let rawQuestions) = obj["questions"] ?? .null,
              !rawQuestions.isEmpty else {
            throw CodingToolError.invalidArgument("ask: `questions` must be a non-empty array")
        }
        return try rawQuestions.map { raw in
            guard case .object(let q) = raw else {
                throw CodingToolError.invalidArgument("ask: each question must be an object")
            }
            guard case .string(let id) = q["id"] ?? .null, !id.isEmpty else {
                throw CodingToolError.invalidArgument("ask: question `id` is required")
            }
            guard case .string(let question) = q["question"] ?? .null, !question.isEmpty else {
                throw CodingToolError.invalidArgument("ask: question `question` is required")
            }
            guard case .array(let rawOptions) = q["options"] ?? .null, !rawOptions.isEmpty else {
                throw CodingToolError.invalidArgument("ask: question `options` must be a non-empty array")
            }
            let options = try rawOptions.map { rawOption -> AskOption in
                guard case .object(let o) = rawOption,
                      case .string(let label) = o["label"] ?? .null, !label.isEmpty else {
                    throw CodingToolError.invalidArgument("ask: each option needs a non-empty `label`")
                }
                if case .string(let description) = o["description"] ?? .null,
                   !description.trimmingCharacters(in: .whitespaces).isEmpty {
                    return AskOption(label: label, description: description)
                }
                return AskOption(label: label, description: nil)
            }
            let multi: Bool = {
                if case .bool(let b) = q["multi"] ?? .null { return b }
                return false
            }()
            let recommended: Int? = {
                switch q["recommended"] ?? .null {
                case .int(let i): return (0..<options.count).contains(i) ? i : nil
                case .double(let d): return (0..<options.count).contains(Int(d)) ? Int(d) : nil
                default: return nil
                }
            }()
            return AskQuestion(
                id: id, question: question, options: options,
                multi: multi, recommended: recommended
            )
        }
    }

    // MARK: - Result shaping (mirrors omp's `ask` result text)

    /// `id: value` line for the multi-question "User answers:" block. A
    /// multi answer can carry checked options AND a custom input — both are
    /// reported.
    static func answerLine(_ a: AskAnswer) -> String {
        let selection = a.selectedOptions.isEmpty
            ? nil
            : a.multi
                ? "[\(a.selectedOptions.joined(separator: ", "))]"
                : a.selectedOptions[0]
        switch (selection, a.customInput) {
        case (let selection?, let custom?):
            return "\(a.id): \(selection) + \"\(custom)\""
        case (let selection?, nil):
            return "\(a.id): \(selection)"
        case (nil, let custom?):
            return "\(a.id): \"\(custom)\""
        case (nil, nil):
            return "\(a.id): (no selection)"
        }
    }

    /// Model-facing result text for a single-question call.
    static func singleResultText(_ a: AskAnswer) -> String {
        var parts: [String] = []
        if !a.selectedOptions.isEmpty {
            parts.append("User selected: \(a.selectedOptions.joined(separator: ", "))")
        }
        if let custom = a.customInput {
            if custom.contains("\n") {
                let indented = custom.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "  \($0)" }.joined(separator: "\n")
                parts.append("User provided custom input:\n\(indented)")
            } else {
                parts.append("User provided custom input: \(custom)")
            }
        }
        if parts.isEmpty {
            return "User made no selection"
        }
        return parts.joined(separator: "\n")
    }

    /// Model-facing result text for a multi-question call.
    static func multiResultText(_ answers: [AskAnswer]) -> String {
        "User answers:\n" + answers.map(answerLine).joined(separator: "\n")
    }

    /// One transcript line per question: `question → answer`. Checked
    /// options and a custom input can coexist on a multi answer.
    static func displayLine(_ a: AskAnswer) -> String {
        var parts: [String] = []
        if !a.selectedOptions.isEmpty {
            parts.append(a.selectedOptions.joined(separator: ", "))
        }
        if let custom = a.customInput {
            parts.append("\"\(custom.replacingOccurrences(of: "\n", with: " "))\"")
        }
        let answer = parts.isEmpty ? "(no selection)" : parts.joined(separator: " + ")
        return "\(a.question) → \(answer)"
    }

    static func details(_ answers: [AskAnswer]) -> JSONValue {
        .object(["results": .array(answers.map { a in
            var fields: [String: JSONValue] = [
                "id": .string(a.id),
                "question": .string(a.question),
                "options": .array(a.options.map { .string($0) }),
                "multi": .bool(a.multi),
                "selectedOptions": .array(a.selectedOptions.map { .string($0) }),
            ]
            if let custom = a.customInput { fields["customInput"] = .string(custom) }
            return .object(fields)
        })])
    }
}

private let askDescription = """
Ask the user when you need clarification or input during task execution.

- Only ask when multiple approaches exist with materially different tradeoffs the user must weigh. Default to action: resolve ambiguity yourself using repo conventions, existing patterns, and reasonable defaults first.
- If multiple choices are acceptable, pick the most conservative/standard option, proceed, and state the choice instead of asking.
- Provide 2-5 concise, distinct options. Keep labels short; put explanatory tradeoffs in `description`.
- Use `recommended: <index>` (0-based) to mark a default — " (Recommended)" is appended automatically.
- Ask multiple related questions in ONE call via `questions` instead of one call at a time.
- Set `multi: true` on a question to allow multiple selections.
- Do NOT include an "Other" option — the UI automatically adds "Other (type your own)" to every question.
"""

private let askParameters: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
        "questions": .object([
            "type": .string("array"),
            "minItems": .int(1),
            "description": .string("questions to ask"),
            "items": .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("short identifier echoed back in the result (e.g. auth_method)"),
                    ]),
                    "question": .object([
                        "type": .string("string"),
                        "description": .string("question text"),
                    ]),
                    "options": .object([
                        "type": .string("array"),
                        "description": .string("available options"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "label": .object([
                                    "type": .string("string"),
                                    "description": .string("display label"),
                                ]),
                                "description": .object([
                                    "type": .string("string"),
                                    "description": .string("optional explanatory text displayed below the label"),
                                ]),
                            ]),
                            "required": .array([.string("label")]),
                        ]),
                    ]),
                    "multi": .object([
                        "type": .string("boolean"),
                        "description": .string("allow multiple selections"),
                    ]),
                    "recommended": .object([
                        "type": .string("integer"),
                        "description": .string("0-based index of the recommended option"),
                    ]),
                ]),
                "required": .array([.string("id"), .string("question"), .string("options")]),
            ]),
        ]),
    ]),
    "required": .array([.string("questions")]),
])

/// FIFO gate serializing concurrent `ask` executions. The agent loop runs a
/// tool batch in parallel by default, but there is one ModalHost — a second
/// `ask` opening mid-question would replace the first modal and strand its
/// suspended continuation forever. omp marks its ask `concurrency:
/// "exclusive"` for the same reason; here the later call simply waits for
/// the earlier one's questions to finish.
private actor AskGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Build the `ask` tool. `present` suspends until the user answers one
/// question; `abortRun` is invoked when the user cancels (Esc) — mirroring
/// omp, a cancelled ask aborts the whole run rather than handing the model a
/// "user declined" result to argue with.
func createAskTool(
    present: @escaping AskPresenter,
    abortRun: @escaping @Sendable () -> Void
) -> AgentTool {
    let gate = AskGate()
    return AgentTool(
        name: "ask",
        label: "ask",
        description: askDescription,
        parameters: askParameters,
        execute: { _, args, cancellation, _ in
            try cancellation?.throwIfCancelled()
            let questions = try Ask.parseQuestions(args)

            await gate.acquire()
            do {
                let result = try await runAskQuestions(
                    questions: questions,
                    present: present,
                    abortRun: abortRun,
                    cancellation: cancellation
                )
                await gate.release()
                return result
            } catch {
                await gate.release()
                throw error
            }
        }
    )
}

private func runAskQuestions(
    questions: [AskQuestion],
    present: AskPresenter,
    abortRun: @Sendable () -> Void,
    cancellation: CancellationHandle?
) async throws -> AgentToolResult {
    // A run abort may have landed while this call was queued behind another
    // ask — don't present a dead run's questions.
    try cancellation?.throwIfCancelled()

    var answers: [AskAnswer?] = Array(repeating: nil, count: questions.count)
    let isWizard = questions.count > 1
    var index = 0
    while index < questions.count {
        let question = questions[index]
        let previous = answers[index]
        let outcome = await present(AskPrompt(
            question: question,
            progressText: isWizard ? "\(index + 1)/\(questions.count)" : nil,
            allowBack: isWizard && index > 0,
            allowForward: isWizard,
            previousSelection: previous?.selectedOptions ?? [],
            previousCustomInput: previous?.customInput
        ), cancellation)
        let record: ([String], String?) -> Void = { selected, customInput in
            answers[index] = AskAnswer(
                id: question.id,
                question: question.question,
                options: question.options.map(\.label),
                multi: question.multi,
                selectedOptions: selected,
                customInput: customInput
            )
        }
        switch outcome {
        case .cancelled:
            abortRun()
            throw CodingToolError.aborted
        case .back(let selected, let customInput):
            record(selected, customInput)
            index = max(0, index - 1)
        case .answered(let selected, let customInput):
            record(selected, customInput)
            index += 1
        }
    }
    let resolved = answers.compactMap { $0 }

    let text = resolved.count == 1
        ? Ask.singleResultText(resolved[0])
        : Ask.multiResultText(resolved)
    return AgentToolResult(
        content: [.text(TextContent(text: text))],
        details: Ask.details(resolved),
        uiDisplay: resolved.map(Ask.displayLine)
    )
}
