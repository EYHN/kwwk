import Foundation
import Testing
@testable import KWWKCli

/// Modal stub that records what the router delivered. `consumesText`
/// models the two modal families: form modals consume typed input,
/// list modals decline it (falling through to the prompt row).
@MainActor
private final class RecordingModal: Modal {
    let consumesText: Bool
    var lefts = 0
    var rights = 0
    var texts: [String] = []

    init(consumesText: Bool) {
        self.consumesText = consumesText
    }

    func up() {}
    func down() {}
    func confirm() {}
    func cancel() {}
    func left() { lefts += 1 }
    func right() { rights += 1 }
    func handleText(_ data: String) -> Bool {
        texts.append(data)
        return consumesText
    }
    func render(maxRows: Int, width: Int) -> [String] { ["stub modal"] }
}

/// Direct coverage of the router the coding TUI installs in front of the
/// prompt row: raw CSI arrows and typed text must reach an open modal first,
/// and everything must fall through to the prompt editor untouched when no
/// modal is open (or the modal declines).
@MainActor
@Suite("ModalInputRouter")
struct ModalInputRouterTests {
    private static let csiLeft = "\u{1B}[D"
    private static let csiRight = "\u{1B}[C"

    private func makeRouter() -> (ModalHost, PromptRow, ModalInputRouter) {
        let host = ModalHost(
            renderModalLines: { _ in },
            restoreTranscript: {},
            requestRender: {}
        )
        let prompt = PromptRow(prompt: "❯ ", input: InputComponent())
        let router = ModalInputRouter(host: host, fallback: prompt)
        return (host, prompt, router)
    }

    @Test("raw left/right CSI bytes reach the open modal, not the prompt row")
    func arrowsRouteToOpenModal() {
        let (host, prompt, router) = makeRouter()
        // Seed through the editor and park the cursor mid-buffer so a leaked
        // left OR right arrow would both move it.
        prompt.handleInput("a")
        prompt.handleInput("b")
        prompt.handleInput(Self.csiLeft)
        let cursorBefore = prompt.input.cursor
        #expect(cursorBefore == 1)
        let modal = RecordingModal(consumesText: false)
        host.open(modal)

        router.handleInput(Self.csiLeft)
        router.handleInput(Self.csiRight)

        #expect(modal.lefts == 1)
        #expect(modal.rights == 1)
        // The prompt editor never saw the arrows.
        #expect(prompt.input.cursor == cursorBefore)
        #expect(prompt.input.value == "ab")
    }

    @Test("typed text goes to a consuming modal and never reaches the prompt")
    func textConsumedByFormModal() {
        let (host, prompt, router) = makeRouter()
        let modal = RecordingModal(consumesText: true)
        host.open(modal)

        router.handleInput("s")
        router.handleInput("k")

        #expect(modal.texts == ["s", "k"])
        #expect(prompt.input.value.isEmpty)
    }

    @Test("typed text a list modal declines falls through to the prompt row")
    func textFallsThroughDecliningModal() {
        let (host, prompt, router) = makeRouter()
        let modal = RecordingModal(consumesText: false)
        host.open(modal)

        router.handleInput("x")

        // The modal was offered the text first, declined it, and the prompt
        // editor received it unchanged.
        #expect(modal.texts == ["x"])
        #expect(prompt.input.value == "x")
        #expect(prompt.input.cursor == 1)
    }

    @Test("with no modal open, arrows and text reach the prompt row unchanged")
    func noModalFallsThrough() {
        let (host, prompt, router) = makeRouter()
        #expect(!host.isOpen)

        router.handleInput("h")
        router.handleInput("i")
        #expect(prompt.input.value == "hi")
        #expect(prompt.input.cursor == 2)

        // Left moves the editor cursor; right moves it back.
        router.handleInput(Self.csiLeft)
        #expect(prompt.input.cursor == 1)
        router.handleInput(Self.csiRight)
        #expect(prompt.input.cursor == 2)

        // Insertion lands at the (arrow-moved) cursor, proving the CSI bytes
        // drove the editor's own cursor handling.
        router.handleInput(Self.csiLeft)
        router.handleInput("!")
        #expect(prompt.input.value == "h!i")
    }
}
