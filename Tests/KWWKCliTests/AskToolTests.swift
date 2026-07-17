import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

// MARK: - Helpers

/// Scripted presenter: pops pre-arranged outcomes in order and records every
/// prompt the tool presented.
private final class ScriptedPresenter: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [AskOutcome]
    private(set) var prompts: [AskPrompt] = []

    init(_ outcomes: [AskOutcome]) {
        self.outcomes = outcomes
    }

    func present(_ prompt: AskPrompt, _ cancellation: CancellationHandle?) async -> AskOutcome {
        lock.withLock {
            prompts.append(prompt)
            return outcomes.removeFirst()
        }
    }

    var recorded: [AskPrompt] { lock.withLock { prompts } }
}

private final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _aborted = false
    var aborted: Bool { lock.withLock { _aborted } }
    func set() { lock.withLock { _aborted = true } }
}

private func askArgs(_ questions: [JSONValue]) -> JSONValue {
    .object(["questions": .array(questions)])
}

private func questionJSON(
    id: String = "q",
    question: String = "Which one?",
    options: [String] = ["A", "B"],
    multi: Bool? = nil,
    recommended: Int? = nil
) -> JSONValue {
    var fields: [String: JSONValue] = [
        "id": .string(id),
        "question": .string(question),
        "options": .array(options.map { .object(["label": .string($0)]) }),
    ]
    if let multi { fields["multi"] = .bool(multi) }
    if let recommended { fields["recommended"] = .int(recommended) }
    return .object(fields)
}

private func resultText(_ result: AgentToolResult) -> String {
    result.content.compactMap { block -> String? in
        if case .text(let t) = block { return t.text } else { return nil }
    }.joined(separator: "\n")
}

private func singleQuestion(
    options: [AskOption] = [AskOption(label: "A", description: nil), AskOption(label: "B", description: nil)],
    multi: Bool = false,
    recommended: Int? = nil
) -> AskQuestion {
    AskQuestion(id: "q", question: "Which one?", options: options, multi: multi, recommended: recommended)
}

private func prompt(
    _ question: AskQuestion,
    allowBack: Bool = false,
    allowForward: Bool = false,
    previousSelection: [String] = [],
    previousCustomInput: String? = nil
) -> AskPrompt {
    AskPrompt(
        question: question,
        progressText: nil,
        allowBack: allowBack,
        allowForward: allowForward,
        previousSelection: previousSelection,
        previousCustomInput: previousCustomInput
    )
}

/// Records modal outcomes; asserts single-fire by construction (appends).
@MainActor
private final class OutcomeLog {
    var outcomes: [AskOutcome] = []
    func callback(_ outcome: AskOutcome) { outcomes.append(outcome) }
}

// MARK: - Argument parsing

@Suite("Ask argument parsing")
struct AskParseTests {
    @Test("parses a full question")
    func parsesFullQuestion() throws {
        let args = askArgs([.object([
            "id": .string("auth"),
            "question": .string("Which auth?"),
            "options": .array([
                .object(["label": .string("JWT"), "description": .string("Bearer tokens")]),
                .object(["label": .string("Sessions")]),
            ]),
            "multi": .bool(true),
            "recommended": .int(1),
        ])])
        let questions = try Ask.parseQuestions(args)
        #expect(questions == [AskQuestion(
            id: "auth",
            question: "Which auth?",
            options: [
                AskOption(label: "JWT", description: "Bearer tokens"),
                AskOption(label: "Sessions", description: nil),
            ],
            multi: true,
            recommended: 1
        )])
    }

    @Test("rejects missing questions, empty questions, and empty options")
    func rejectsMalformed() {
        #expect(throws: CodingToolError.self) { try Ask.parseQuestions(.object([:])) }
        #expect(throws: CodingToolError.self) { try Ask.parseQuestions(askArgs([])) }
        #expect(throws: CodingToolError.self) {
            try Ask.parseQuestions(askArgs([.object([
                "id": .string("q"), "question": .string("?"), "options": .array([]),
            ])]))
        }
        #expect(throws: CodingToolError.self) {
            try Ask.parseQuestions(askArgs([.object([
                "question": .string("?"),
                "options": .array([.object(["label": .string("A")])]),
            ])]))
        }
    }

    @Test("out-of-range recommended index is dropped")
    func recommendedOutOfRange() throws {
        let questions = try Ask.parseQuestions(askArgs([
            questionJSON(options: ["A", "B"], recommended: 5),
        ]))
        #expect(questions[0].recommended == nil)
    }
}

// MARK: - Result shaping

@Suite("Ask result shaping")
struct AskResultTests {
    @Test("answer lines mirror omp: custom / multi / single / none")
    func answerLines() {
        #expect(Ask.answerLine(AskAnswer(
            id: "q", question: "?", options: [], multi: false,
            selectedOptions: [], customInput: "my own"
        )) == "q: \"my own\"")
        #expect(Ask.answerLine(AskAnswer(
            id: "q", question: "?", options: [], multi: true,
            selectedOptions: ["A", "B"], customInput: nil
        )) == "q: [A, B]")
        #expect(Ask.answerLine(AskAnswer(
            id: "q", question: "?", options: [], multi: false,
            selectedOptions: ["A"], customInput: nil
        )) == "q: A")
        #expect(Ask.answerLine(AskAnswer(
            id: "q", question: "?", options: [], multi: false,
            selectedOptions: [], customInput: nil
        )) == "q: (no selection)")
    }

    @Test("single-question text: selection, multiline custom input, both")
    func singleText() {
        #expect(Ask.singleResultText(AskAnswer(
            id: "q", question: "?", options: [], multi: false,
            selectedOptions: ["JWT"], customInput: nil
        )) == "User selected: JWT")
        #expect(Ask.singleResultText(AskAnswer(
            id: "q", question: "?", options: [], multi: false,
            selectedOptions: [], customInput: "line1\nline2"
        )) == "User provided custom input:\n  line1\n  line2")
        #expect(Ask.singleResultText(AskAnswer(
            id: "q", question: "?", options: [], multi: true,
            selectedOptions: ["A"], customInput: "extra"
        )) == "User selected: A\nUser provided custom input: extra")
    }
}

// MARK: - Tool execution

@Suite("Ask tool execution")
struct AskExecuteTests {
    @Test("single question answers with selection text and display line")
    func singleAnswered() async throws {
        let presenter = ScriptedPresenter([.answered(selected: ["B"], customInput: nil)])
        let abort = AbortFlag()
        let tool = createAskTool(present: presenter.present, abortRun: { abort.set() })

        let result = try await tool.execute("t1", askArgs([questionJSON()]), nil, nil)
        #expect(resultText(result) == "User selected: B")
        #expect(result.uiDisplay == ["Which one? → B"])
        #expect(!abort.aborted)

        let prompts = presenter.recorded
        #expect(prompts.count == 1)
        #expect(prompts[0].progressText == nil)
        #expect(!prompts[0].allowBack && !prompts[0].allowForward)
    }

    @Test("cancel aborts the run and throws")
    func cancelAborts() async throws {
        let presenter = ScriptedPresenter([.cancelled])
        let abort = AbortFlag()
        let tool = createAskTool(present: presenter.present, abortRun: { abort.set() })

        await #expect(throws: CodingToolError.aborted) {
            _ = try await tool.execute("t1", askArgs([questionJSON()]), nil, nil)
        }
        #expect(abort.aborted)
    }

    @Test("wizard: back revisits with the previous answer, result lists all ids")
    func wizardBackNavigation() async throws {
        let q1 = questionJSON(id: "first", question: "First?", options: ["A", "B"])
        let q2 = questionJSON(id: "second", question: "Second?", options: ["X", "Y"])
        let presenter = ScriptedPresenter([
            .answered(selected: ["A"], customInput: nil),
            .back(selected: ["X"], customInput: nil),
            .answered(selected: ["B"], customInput: nil),
            .answered(selected: ["Y"], customInput: nil),
        ])
        let tool = createAskTool(present: presenter.present, abortRun: {})

        let result = try await tool.execute("t1", askArgs([q1, q2]), nil, nil)
        #expect(resultText(result) == "User answers:\nfirst: B\nsecond: Y")

        let prompts = presenter.recorded
        #expect(prompts.count == 4)
        #expect(prompts.map(\.progressText) == ["1/2", "2/2", "1/2", "2/2"])
        #expect(prompts.map(\.allowBack) == [false, true, false, true])
        #expect(prompts.map(\.allowForward) == [true, true, true, true])
        // Revisited first question carries its previous answer back in, and
        // the second question's in-progress state survives the round trip.
        #expect(prompts[2].previousSelection == ["A"])
        #expect(prompts[3].previousSelection == ["X"])
    }

    @Test("multi answer and skipped question render omp-style lines")
    func multiAndSkipped() async throws {
        let q1 = questionJSON(id: "langs", question: "Which?", options: ["Swift", "Rust"], multi: true)
        let q2 = questionJSON(id: "extra", question: "More?", options: ["Yes"])
        let presenter = ScriptedPresenter([
            .answered(selected: ["Swift", "Rust"], customInput: nil),
            .answered(selected: [], customInput: nil),
        ])
        let tool = createAskTool(present: presenter.present, abortRun: {})

        let result = try await tool.execute("t1", askArgs([q1, q2]), nil, nil)
        #expect(resultText(result) == "User answers:\nlangs: [Swift, Rust]\nextra: (no selection)")
        #expect(result.uiDisplay == ["Which? → Swift, Rust", "More? → (no selection)"])
    }
}

// MARK: - Modal behavior

@MainActor
@Suite("Ask modal")
struct AskModalTests {
    @Test("enter on an option answers a single-select question")
    func singleSelect() {
        let log = OutcomeLog()
        let modal = AskModal(prompt: prompt(singleQuestion()), onComplete: log.callback)
        modal.down()
        modal.confirm()
        #expect(log.outcomes == [.answered(selected: ["B"], customInput: nil)])
    }

    @Test("recommended option is the initial cursor position")
    func recommendedInitial() {
        let log = OutcomeLog()
        let modal = AskModal(prompt: prompt(singleQuestion(recommended: 1)), onComplete: log.callback)
        modal.confirm()
        #expect(log.outcomes == [.answered(selected: ["B"], customInput: nil)])
    }

    @Test("multi: enter toggles, Done submits in option order")
    func multiToggleAndDone() {
        let log = OutcomeLog()
        let modal = AskModal(prompt: prompt(singleQuestion(multi: true)), onComplete: log.callback)
        // Toggle B first, then A — submit order must follow option order.
        modal.down()
        modal.confirm()
        modal.up()
        modal.confirm()
        #expect(log.outcomes.isEmpty)
        #expect(modal.orderedSelection == ["A", "B"])
        // Entries: A, B, Done, Other — move from A to Done.
        modal.down()
        modal.down()
        modal.confirm()
        #expect(log.outcomes == [.answered(selected: ["A", "B"], customInput: nil)])
    }

    @Test("other: typed text submits as custom input; esc returns to the list")
    func otherInput() {
        let log = OutcomeLog()
        let modal = AskModal(prompt: prompt(singleQuestion()), onComplete: log.callback)
        modal.up() // wraps to the Other row (last entry)
        modal.confirm()
        #expect(modal.handleText("hi there"))
        #expect(modal.handleText("\u{7F}")) // backspace: "hi ther"
        modal.confirm()
        #expect(log.outcomes == [.answered(selected: [], customInput: "hi ther")])
    }

    @Test("esc in other-input backs out; esc in the list cancels")
    func escBehavior() {
        let log = OutcomeLog()
        let modal = AskModal(prompt: prompt(singleQuestion()), onComplete: log.callback)
        modal.up()
        modal.confirm() // into other-input
        modal.cancel() // back to the list
        #expect(log.outcomes.isEmpty)
        #expect(!modal.handleText("x")) // list mode consumes nothing
        modal.cancel()
        #expect(log.outcomes == [.cancelled])
    }

    @Test("left/right only navigate when the wizard allows them")
    func wizardNavGating() {
        let single = OutcomeLog()
        let singleModal = AskModal(prompt: prompt(singleQuestion()), onComplete: single.callback)
        singleModal.left()
        singleModal.right()
        #expect(single.outcomes.isEmpty)

        let wizard = OutcomeLog()
        let wizardModal = AskModal(
            prompt: prompt(singleQuestion(), allowBack: true, allowForward: true,
                           previousSelection: ["A"]),
            onComplete: wizard.callback
        )
        wizardModal.left()
        #expect(wizard.outcomes == [.back(selected: ["A"], customInput: nil)])
        // A finished modal reports exactly once.
        wizardModal.right()
        wizardModal.confirm()
        #expect(wizard.outcomes == [.back(selected: ["A"], customInput: nil)])
    }

    @Test("wizard back carries the live multi selections")
    func backCarriesMultiState() {
        let log = OutcomeLog()
        let modal = AskModal(
            prompt: prompt(singleQuestion(multi: true), allowBack: true, allowForward: true),
            onComplete: log.callback
        )
        modal.confirm() // toggle A
        modal.left()
        #expect(log.outcomes == [.back(selected: ["A"], customInput: nil)])
    }

    @Test("forward keeps the previous answer")
    func forwardKeepsPrevious() {
        let log = OutcomeLog()
        let modal = AskModal(
            prompt: prompt(singleQuestion(), allowBack: false, allowForward: true,
                           previousSelection: ["B"]),
            onComplete: log.callback
        )
        modal.right()
        #expect(log.outcomes == [.answered(selected: ["B"], customInput: nil)])
    }

    @Test("render shows question, markers, recommended tag, and hints")
    func renderLines() {
        let log = OutcomeLog()
        let question = AskQuestion(
            id: "q", question: "Which auth?",
            options: [
                AskOption(label: "JWT", description: "Bearer tokens"),
                AskOption(label: "Sessions", description: nil),
            ],
            multi: false, recommended: 0
        )
        let modal = AskModal(prompt: prompt(question), onComplete: log.callback)
        let lines = modal.render(maxRows: 20)
        #expect(lines.contains(where: { $0.contains("Which auth?") }))
        #expect(lines.contains(where: { $0.contains("JWT") && $0.contains("(Recommended)") }))
        #expect(lines.contains(where: { $0.contains("↳ Bearer tokens") }))
        #expect(lines.contains(where: { $0.contains(Ask.otherOptionLabel) }))
        #expect(lines.contains(where: { $0.contains("Esc: cancel") }))
    }

    @Test("other-input render shows the buffer and its own hints")
    func renderOtherInput() {
        let log = OutcomeLog()
        let modal = AskModal(prompt: prompt(singleQuestion()), onComplete: log.callback)
        modal.up()
        modal.confirm()
        _ = modal.handleText("custom")
        let lines = modal.render(maxRows: 10)
        #expect(lines.contains(where: { $0.contains("custom") }))
        #expect(lines.contains(where: { $0.contains("Enter: submit") }))
    }
}

// MARK: - Transcript rendering

@MainActor
@Suite("Ask transcript rendering")
struct AskTranscriptTests {
    @Test("header shows the first question instead of the raw array")
    func headerSummary() {
        let r = TranscriptRenderer()
        let args = askArgs([
            questionJSON(question: "Which auth method?"),
            questionJSON(id: "q2", question: "Second?"),
        ])
        r.apply(.toolExecutionStart(toolCallId: "1", toolName: "ask", args: args))
        #expect(r.liveLines.contains(where: { $0.contains("ask(\"Which auth method?\" +1 more)") }))

        r.apply(.toolExecutionEnd(
            toolCallId: "1",
            toolName: "ask",
            result: AgentToolResult(
                content: [.text(TextContent(text: "User selected: JWT"))],
                uiDisplay: ["Which auth method? → JWT"]
            ),
            isError: false
        ))
        let commits = r.drainCommits()
        #expect(commits.contains(where: { $0.contains("ask(\"Which auth method?\" +1 more)") }))
        #expect(commits.contains(where: { $0.contains("Which auth method? → JWT") }))
    }
}
