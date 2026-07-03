import Foundation
import Testing
@testable import KWWKCli

@Suite("FormModal")
struct FormModalTests {

    @MainActor
    private func makeModal(
        onSubmit: @MainActor @escaping ([String: String]) -> Void = { _ in },
        onCancel: @MainActor @escaping () -> Void = {}
    ) -> FormModal {
        FormModal(
            title: "OpenAI API key",
            fields: [
                APIKeyFormField(key: "apiKey", label: "API key",
                                hint: "sk-…", placeholder: "sk-proj-…", required: true),
                APIKeyFormField(key: "baseUrl", label: "Base URL",
                                hint: "(optional)",
                                placeholder: "https://api.openai.com",
                                default: "https://api.openai.com",
                                required: false),
            ],
            onSubmit: onSubmit,
            onCancel: onCancel
        )
    }

    @MainActor
    @Test("typing lands in the focused field and is always consumed")
    func typingConsumed() {
        let modal = makeModal()
        #expect(modal.handleText("sk-abc") == true)
        #expect(modal.values["apiKey"] == "sk-abc")
        // Focus moves with tab; typing follows.
        modal.tab()
        #expect(modal.handleText("x") == true)
        #expect(modal.values["baseUrl"] == "https://api.openai.comx")
    }

    @MainActor
    @Test("backspace deletes; bracketed paste is stripped; control chars filtered")
    func editingSemantics() {
        let modal = makeModal()
        _ = modal.handleText("ab")
        _ = modal.handleText("\u{7F}")
        #expect(modal.values["apiKey"] == "a")
        // Backspace on an empty buffer is a no-op.
        _ = modal.handleText("\u{7F}"); _ = modal.handleText("\u{7F}")
        #expect(modal.values["apiKey"] == "")
        // Bracketed-paste envelope stripped, inner tabs/newlines dropped.
        _ = modal.handleText("\u{1B}[200~sk-\n\tkey\u{1B}[201~")
        #expect(modal.values["apiKey"] == "sk-key")
        // Unrecognized escape sequences are swallowed, not typed.
        #expect(modal.handleText("\u{1B}[Z") == true)
        #expect(modal.values["apiKey"] == "sk-key")
        // Raw control bytes are filtered.
        _ = modal.handleText("\u{01}!")
        #expect(modal.values["apiKey"] == "sk-key!")
    }

    @MainActor
    @Test("confirm with an empty required field shows the error, no submit")
    func requiredValidation() {
        let submitted = Ref<[String: String]?>(nil)
        let modal = makeModal(onSubmit: { submitted.value = $0 })
        modal.confirm()
        #expect(submitted.value == nil)
        #expect(modal.render(maxRows: 24).contains(where: { $0.contains("API key is required") }))
        // Typing clears the inline error.
        _ = modal.handleText("s")
        #expect(!modal.render(maxRows: 24).contains(where: { $0.contains("is required") }))
    }

    @MainActor
    @Test("confirm submits trimmed values with defaults for empty optionals")
    func submitValues() {
        let submitted = Ref<[String: String]?>(nil)
        let modal = makeModal(onSubmit: { submitted.value = $0 })
        _ = modal.handleText("  sk-key  ")
        // Empty the optional field so it falls back to its default.
        modal.tab()
        for _ in 0..<30 { _ = modal.handleText("\u{7F}") }
        modal.confirm()
        #expect(submitted.value?["apiKey"] == "sk-key")
        #expect(submitted.value?["baseUrl"] == "https://api.openai.com")
    }

    @MainActor
    @Test("cancel fires onCancel, not onSubmit")
    func cancelFires() {
        let submitted = Ref<Bool>(false)
        let cancelled = Ref<Bool>(false)
        let modal = makeModal(onSubmit: { _ in submitted.value = true },
                              onCancel: { cancelled.value = true })
        modal.cancel()
        #expect(cancelled.value == true)
        #expect(submitted.value == false)
    }

    @MainActor
    @Test("up/down/tab wrap field focus; render marks exactly one focused row")
    func focusMovement() {
        let modal = makeModal()
        func focusedRows() -> Int {
            modal.render(maxRows: 24).filter { $0.contains("❯") }.count
        }
        #expect(focusedRows() == 1)
        modal.down()
        _ = modal.handleText("x")
        #expect(modal.values["baseUrl"]?.hasSuffix("x") == true)
        modal.down() // wraps back to the first field
        _ = modal.handleText("y")
        #expect(modal.values["apiKey"] == "y")
        modal.up() // wraps to the last field
        _ = modal.handleText("z")
        #expect(modal.values["baseUrl"]?.hasSuffix("xz") == true)
        #expect(focusedRows() == 1)
    }

    @MainActor
    @Test("render fits maxRows and keeps the focused field visible when short")
    func rendersWithinBudget() {
        let fields = (0..<8).map {
            APIKeyFormField(key: "k\($0)", label: "Field \($0)", required: false)
        }
        let modal = FormModal(title: "t", fields: fields, onSubmit: { _ in }, onCancel: {})
        for maxRows in [4, 6, 9, 12, 40] {
            for _ in 0..<8 {
                let lines = modal.render(maxRows: maxRows)
                #expect(lines.count <= maxRows, "overflow at maxRows \(maxRows)")
                #expect(lines.contains(where: { $0.contains("❯") }),
                        "focused field must stay visible at maxRows \(maxRows)")
                modal.down()
            }
        }
    }
}

@Suite("ModalHost text/tab routing")
struct ModalHostRoutingTests {

    @MainActor
    private final class StubModal: Modal {
        var consumesText: Bool
        var texts: [String] = []
        var tabs = 0
        var lefts = 0
        var rights = 0

        init(consumesText: Bool) { self.consumesText = consumesText }

        func up() {}
        func down() {}
        func confirm() {}
        func cancel() {}
        func tab() { tabs += 1 }
        func left() { lefts += 1 }
        func right() { rights += 1 }
        func handleText(_ data: String) -> Bool {
            guard consumesText else { return false }
            texts.append(data)
            return true
        }
        func render(maxRows: Int) -> [String] { ["stub"] }
    }

    @MainActor
    private func makeHost() -> ModalHost {
        ModalHost(
            renderModalLines: { _ in },
            restoreTranscript: {},
            requestRender: {}
        )
    }

    @MainActor
    @Test("routeText returns false when no modal is open")
    func routeTextClosedFallsThrough() {
        let host = makeHost()
        #expect(host.routeText("a") == false)
    }

    @MainActor
    @Test("routeText falls through for list modals, consumes for form modals")
    func routeTextConsumption() {
        let host = makeHost()
        let list = StubModal(consumesText: false)
        host.open(list)
        #expect(host.routeText("a") == false)

        let form = StubModal(consumesText: true)
        host.open(form)
        #expect(host.routeText("a") == true)
        #expect(form.texts == ["a"])

        host.close()
        #expect(host.routeText("b") == false)
        #expect(form.texts == ["a"])
    }

    @MainActor
    @Test("routeTab / routeLeft / routeRight reach the open modal only")
    func routeTabAndArrows() {
        let host = makeHost()
        let modal = StubModal(consumesText: false)
        host.routeTab(); host.routeLeft(); host.routeRight() // closed → no-ops
        #expect(modal.tabs == 0)
        host.open(modal)
        host.routeTab(); host.routeLeft(); host.routeRight()
        #expect(modal.tabs == 1)
        #expect(modal.lefts == 1)
        #expect(modal.rights == 1)
    }

    @MainActor
    @Test("routeConfirm repaints an in-place mutation (form validation error)")
    func routeConfirmRedraws() {
        let lastLines = Ref<[String]?>(nil)
        let host = ModalHost(
            renderModalLines: { lastLines.value = $0 },
            restoreTranscript: {},
            requestRender: {}
        )
        let form = FormModal(
            title: "t",
            fields: [APIKeyFormField(key: "apiKey", label: "API key", required: true)],
            onSubmit: { _ in },
            onCancel: {}
        )
        host.open(form)
        // Enter on the empty required field: the modal stays open, so the
        // host must repaint and surface the inline error — without the
        // redraw the error is set but never rendered.
        host.routeConfirm()
        #expect(lastLines.value?.contains(where: { $0.contains("API key is required") }) == true)
    }

    @MainActor
    @Test("routeConfirm after a confirm that closes the modal does not repaint stale lines")
    func routeConfirmCloseNoStaleRedraw() {
        let lastLines = Ref<[String]?>(["sentinel"])
        let host = makeHostCapturing(lastLines)
        let closing = ClosingModal()
        host.open(closing)
        closing.host = host
        host.routeConfirm()
        // close() cleared the modal lines; the post-confirm redraw must not
        // resurrect the closed modal's frame.
        #expect(lastLines.value == nil)
        #expect(host.isOpen == false)
    }

    @MainActor
    private func makeHostCapturing(_ lines: Ref<[String]?>) -> ModalHost {
        ModalHost(
            renderModalLines: { lines.value = $0 },
            restoreTranscript: {},
            requestRender: {}
        )
    }

    @MainActor
    private final class ClosingModal: Modal {
        weak var host: ModalHost?
        func up() {}
        func down() {}
        func confirm() { host?.close() }
        func cancel() {}
        func render(maxRows: Int) -> [String] { ["closing"] }
    }

    @MainActor
    @Test("protocol defaults: list modals ignore tab/arrows and decline text")
    func protocolDefaults() {
        // SessionResumeModal adopts none of the new requirements — the
        // protocol-extension defaults must keep it compiling and inert.
        let modal = SessionResumeModal(
            sessions: [], currentSessionId: "x",
            onSelect: { _ in }, onCancel: {}
        )
        modal.tab(); modal.left(); modal.right()
        #expect(modal.handleText("a") == false)
    }
}

@MainActor
private final class Ref<T> {
    var value: T
    init(_ v: T) { self.value = v }
}
