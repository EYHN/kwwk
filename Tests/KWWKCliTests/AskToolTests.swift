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

@MainActor
private func makeModal(
    _ prompt: AskPrompt,
    onComplete: @MainActor @escaping (AskOutcome) -> Void
) -> AskModal {
    AskModal(prompt: prompt, onComplete: onComplete)
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
    @Test("multi answer with checked options AND custom input reports both")
    func multiWithCustomKeepsSelections() {
        let answer = AskAnswer(
            id: "q", question: "Which?", options: [], multi: true,
            selectedOptions: ["A", "B"], customInput: "also this"
        )
        #expect(Ask.answerLine(answer) == "q: [A, B] + \"also this\"")
        #expect(Ask.displayLine(answer) == "Which? → A, B + \"also this\"")
    }

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

    @Test("parallel ask calls serialize instead of hanging on the one modal host")
    func parallelCallsSerialize() async throws {
        // Presenter that fails the test if two presentations ever overlap,
        // mirroring the single-ModalHost constraint.
        final class OverlapGuard: @unchecked Sendable {
            private let lock = NSLock()
            private var active = 0
            private(set) var overlapped = false
            private(set) var served = 0
            func present(_ prompt: AskPrompt, _ cancellation: CancellationHandle?) async -> AskOutcome {
                lock.withLock {
                    active += 1
                    if active > 1 { overlapped = true }
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
                lock.withLock {
                    active -= 1
                    served += 1
                }
                return .answered(selected: ["A"], customInput: nil)
            }
        }
        let guardBox = OverlapGuard()
        let tool = createAskTool(present: guardBox.present, abortRun: {})

        async let first = tool.execute("t1", askArgs([questionJSON(id: "one")]), nil, nil)
        async let second = tool.execute("t2", askArgs([questionJSON(id: "two")]), nil, nil)
        let results = try await [first, second]

        #expect(!guardBox.overlapped)
        #expect(guardBox.served == 2)
        #expect(results.count == 2)
    }

    @Test("an answer racing a cancellation never yields a normal result")
    func answerRacingCancellationThrows() async throws {
        let cancellation = CancellationHandle()
        // Presenter simulating the race: the run is cancelled while the
        // question is up, and the user's confirm still resumes with an answer.
        let present: AskPresenter = { _, handle in
            handle?.cancel()
            return .answered(selected: ["A"], customInput: nil)
        }
        let tool = createAskTool(present: present, abortRun: {})
        await #expect(throws: CancellationError.self) {
            _ = try await tool.execute("t1", askArgs([questionJSON()]), cancellation, nil)
        }
    }

    @Test("cancellation between wizard questions stops before the next one")
    func cancellationBetweenQuestions() async throws {
        let cancellation = CancellationHandle()
        let presented = AbortFlag() // reused flag: set when a SECOND question is presented
        let present: AskPresenter = { prompt, handle in
            if prompt.question.id == "second" { presented.set() }
            handle?.cancel()
            return .answered(selected: ["A"], customInput: nil)
        }
        let tool = createAskTool(present: present, abortRun: {})
        await #expect(throws: CancellationError.self) {
            _ = try await tool.execute(
                "t1",
                askArgs([questionJSON(id: "first"), questionJSON(id: "second")]),
                cancellation,
                nil
            )
        }
        #expect(!presented.aborted)
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
        let modal = makeModal(prompt(singleQuestion()), onComplete: log.callback)
        modal.down()
        modal.confirm()
        #expect(log.outcomes == [.answered(selected: ["B"], customInput: nil)])
    }

    @Test("recommended option is the initial cursor position")
    func recommendedInitial() {
        let log = OutcomeLog()
        let modal = makeModal(prompt(singleQuestion(recommended: 1)), onComplete: log.callback)
        modal.confirm()
        #expect(log.outcomes == [.answered(selected: ["B"], customInput: nil)])
    }

    @Test("multi: enter toggles, Done submits in option order")
    func multiToggleAndDone() {
        let log = OutcomeLog()
        let modal = makeModal(prompt(singleQuestion(multi: true)), onComplete: log.callback)
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
        let modal = makeModal(prompt(singleQuestion()), onComplete: log.callback)
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
        let modal = makeModal(prompt(singleQuestion()), onComplete: log.callback)
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
        let singleModal = makeModal(prompt(singleQuestion()), onComplete: single.callback)
        singleModal.left()
        singleModal.right()
        #expect(single.outcomes.isEmpty)

        let wizard = OutcomeLog()
        let wizardModal = makeModal(
            prompt(singleQuestion(), allowBack: true, allowForward: true,
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
        let modal = makeModal(
            prompt(singleQuestion(multi: true), allowBack: true, allowForward: true),
            onComplete: log.callback
        )
        modal.confirm() // toggle A
        modal.left()
        #expect(log.outcomes == [.back(selected: ["A"], customInput: nil)])
    }

    @Test("forward keeps the previous answer")
    func forwardKeepsPrevious() {
        let log = OutcomeLog()
        let modal = makeModal(
            prompt(singleQuestion(), allowBack: false, allowForward: true,
                   previousSelection: ["B"]),
            onComplete: log.callback
        )
        modal.right()
        #expect(log.outcomes == [.answered(selected: ["B"], customInput: nil)])
    }

    @Test("wizard nav carries an in-progress Other draft")
    func navCarriesOtherDraft() {
        let log = OutcomeLog()
        let modal = makeModal(
            prompt(singleQuestion(), allowBack: true, allowForward: true),
            onComplete: log.callback
        )
        modal.up() // Other row
        modal.confirm() // into free-text entry
        _ = modal.handleText("draft answer")
        modal.cancel() // back to the list, buffer retained
        modal.right()
        #expect(log.outcomes == [.answered(selected: [], customInput: "draft answer")])
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
        let modal = makeModal(prompt(question), onComplete: log.callback)
        let lines = modal.render(maxRows: 20, width: 80)
        #expect(lines.contains(where: { $0.contains("Which auth?") }))
        #expect(lines.contains(where: { $0.contains("JWT") && $0.contains("(Recommended)") }))
        #expect(lines.contains(where: { $0.contains("↳ Bearer tokens") }))
        #expect(lines.contains(where: { $0.contains(Ask.otherOptionLabel) }))
        #expect(lines.contains(where: { $0.contains("Esc: cancel") }))
    }

    @Test("long lists window within maxRows, clamp to width, and follow the cursor")
    func longListWindows() {
        let log = OutcomeLog()
        let options = (1...30).map { i in
            AskOption(
                label: "选项 \(String(format: "%02d", i)): 一个非常非常长的标题用来测试列表较长时是否有滚动体验",
                description: "这是第 \(i) 个超长选项说明：堆叠大量内容以测试 ask 工具接近极限时的表现。"
            )
        }
        let question = AskQuestion(
            id: "q", question: "超长压力测试：如果有超级多选项，列表应当在窗口内滚动而不是撑爆终端?",
            options: options, multi: true, recommended: 7
        )
        let width = 60
        let maxRows = 20
        let modal = makeModal(prompt(question), onComplete: log.callback)

        for step in 0..<40 {
            let lines = modal.render(maxRows: maxRows, width: width)
            #expect(lines.count <= maxRows)
            #expect(lines.allSatisfy { ANSI.visibleWidth($0) <= width })
            // The cursor row must be inside the window at every position.
            #expect(lines.contains(where: { $0.contains("❯") }), "cursor missing at step \(step)")
            // The selected entry's label must be FULLY visible (wrapped, not
            // truncated): its plain text reassembles from the window rows.
            if case .option(let optIdx) = modal.entries[modal.selectedIndex] {
                let plain = lines.map { ANSI.stripEscapes($0).replacingOccurrences(of: " ", with: "") }
                    .joined()
                let label = options[optIdx].label.replacingOccurrences(of: " ", with: "")
                #expect(plain.contains(label), "label cut off at step \(step)")
            }
            modal.down()
        }
        // Deep in the list the window has scrolled: the first option is gone,
        // a windowed position indicator is shown.
        for _ in 0..<25 { modal.down() } // wrap around and land mid-list again
        modal.down()
        let deep = modal.render(maxRows: maxRows, width: width)
        #expect(!deep.contains(where: { $0.contains("选项 01") }))
        #expect(deep.contains(where: { $0.contains("/\(options.count + 2)") }))
    }

    @Test("only an entry taller than the window is clamped, with a marker")
    func overTallEntryClamps() {
        let log = OutcomeLog()
        let question = AskQuestion(
            id: "q", question: "Q?",
            options: [
                AskOption(label: "Small", description: "short"),
                AskOption(label: "Huge", description: String(repeating: "很长的描述内容", count: 80)),
            ],
            multi: false, recommended: nil
        )
        let width = 40
        let maxRows = 12
        let modal = makeModal(prompt(question), onComplete: log.callback)

        modal.down() // onto Huge
        let lines = modal.render(maxRows: maxRows, width: width)
        #expect(lines.count <= maxRows)
        #expect(lines.allSatisfy { ANSI.visibleWidth($0) <= width })
        #expect(lines.contains(where: { $0.contains("Huge") }))
        #expect(lines.contains(where: { $0.contains("more lines") }))

        // The rest of the list stays reachable past the clamped monster.
        modal.down() // Other row
        let after = modal.render(maxRows: maxRows, width: width)
        #expect(after.contains(where: { $0.contains(Ask.otherOptionLabel) && $0.contains("❯") }))

        // A normal multi-row entry below the window threshold is NOT clamped.
        modal.up() // Huge
        modal.up() // Small
        let back = modal.render(maxRows: maxRows, width: width)
        let plain = back.map { ANSI.stripEscapes($0) }.joined()
        #expect(plain.contains("short"))
    }

    @Test("other-input wraps an overlong buffer and keeps the tail visible")
    func otherInputLongBuffer() {
        let log = OutcomeLog()
        let modal = makeModal(prompt(singleQuestion()), onComplete: log.callback)
        modal.up()
        modal.confirm()
        _ = modal.handleText(String(repeating: "a", count: 60) + "TAIL")
        let lines = modal.render(maxRows: 10, width: 40)
        #expect(lines.count <= 10)
        #expect(lines.allSatisfy { ANSI.visibleWidth($0) <= 40 })
        // Wrapped, not truncated: the full buffer reassembles from the rows.
        let plain = lines.map { ANSI.stripEscapes($0).replacingOccurrences(of: " ", with: "") }.joined()
        #expect(plain.contains(String(repeating: "a", count: 60) + "TAIL"))
    }

    @Test("other-input render shows the buffer and its own hints")
    func renderOtherInput() {
        let log = OutcomeLog()
        let modal = makeModal(prompt(singleQuestion()), onComplete: log.callback)
        modal.up()
        modal.confirm()
        _ = modal.handleText("custom")
        let lines = modal.render(maxRows: 10, width: 80)
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
