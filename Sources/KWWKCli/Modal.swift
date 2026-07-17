import Foundation
import KWWKAI

/// Anything that temporarily takes over the transcript area + arrow-key /
/// confirm / cancel routing. Slash commands open modals; only one can be
/// active at a time.
@MainActor
protocol Modal: AnyObject {
    func up()
    func down()
    func confirm()
    func cancel()
    /// Tab key while the modal is open. Selector modals use it to cycle a
    /// filter; form modals to advance field focus. Default: no-op.
    func tab()
    /// Left / right arrow keys while the modal is open (e.g. tab-bar
    /// navigation). Default: no-op.
    func left()
    func right()
    /// Typed text / backspace / paste bytes for form-style modals. Return
    /// true when consumed; the default (false) lets list-style modals fall
    /// through to the prompt-box input, preserving its pre-modal behavior.
    func handleText(_ data: String) -> Bool
    /// Lines to render in place of the transcript while the modal is open.
    /// `maxRows` is the height budget (terminal rows available above the
    /// prompt box); modals with long lists must window their content to fit
    /// and keep the selection visible rather than overflow the viewport.
    /// `width` is the display width in visible columns: every emitted line
    /// MUST fit it (truncate or manually wrap). The frame keeps only the
    /// BOTTOM of an overflowing modal, so a line the terminal would soft-wrap
    /// breaks the `maxRows` contract and pushes the title off-screen.
    func render(maxRows: Int, width: Int) -> [String]
}

extension Modal {
    func tab() {}
    func left() {}
    func right() {}
    func handleText(_ data: String) -> Bool { false }
}

/// Owns the "one modal at a time" invariant. The coding TUI's arrow /
/// enter / esc bindings all check `host.isOpen` and forward to the host if
/// a modal is up, otherwise fall through to their default behavior.
@MainActor
final class ModalHost {
    private(set) var isOpen: Bool = false
    private var active: Modal?

    private let renderModalLines: ([String]?) -> Void
    /// Re-render the live tail from its canonical source (the
    /// TranscriptRenderer's liveLines + any notifications). Called on close
    /// so the user goes back to exactly what was on screen before the modal.
    private let restoreTranscript: () -> Void
    private let requestRender: () -> Void
    /// Height budget (terminal rows available for the modal above the prompt
    /// box), queried fresh on every redraw so windowing tracks resizes.
    private let availableRows: () -> Int
    /// Display width in visible columns (the live zone's drawable width),
    /// queried fresh on every redraw so truncation tracks resizes.
    private let availableWidth: () -> Int

    init(
        renderModalLines: @escaping ([String]?) -> Void,
        restoreTranscript: @escaping () -> Void,
        requestRender: @escaping () -> Void,
        availableRows: @escaping () -> Int = { 24 },
        availableWidth: @escaping () -> Int = { 80 }
    ) {
        self.renderModalLines = renderModalLines
        self.restoreTranscript = restoreTranscript
        self.requestRender = requestRender
        self.availableRows = availableRows
        self.availableWidth = availableWidth
    }

    func open(_ modal: Modal) {
        self.active = modal
        self.isOpen = true
        redraw()
    }

    func close() {
        self.active = nil
        self.isOpen = false
        renderModalLines(nil)
        restoreTranscript()
        requestRender()
    }

    // Key routing. These are no-ops when no modal is open, so callers can
    // wire them unconditionally and let the host decide.

    /// Re-render the open modal at the current height budget. Called on a
    /// terminal resize so a windowed list re-fits immediately instead of
    /// lagging a frame behind until the next keypress.
    func reflow() { guard isOpen else { return }; redraw() }

    func routeUp() { guard isOpen else { return }; active?.up(); redraw() }
    func routeDown() { guard isOpen else { return }; active?.down(); redraw() }
    /// Confirm may close the modal (a selection) or mutate it in place (a
    /// form surfacing a required-field error) — repaint only when it is
    /// still open, so the in-place mutation is actually visible.
    func routeConfirm() {
        guard isOpen else { return }
        active?.confirm()
        if isOpen { redraw() }
    }
    /// Cancel may close the modal or mutate it in place (e.g. Esc clearing
    /// the model selector's filter query) — repaint only when still open.
    func routeCancel() {
        guard isOpen else { return }
        active?.cancel()
        if isOpen { redraw() }
    }
    func routeTab() { guard isOpen else { return }; active?.tab(); redraw() }
    func routeLeft() { guard isOpen else { return }; active?.left(); redraw() }
    func routeRight() { guard isOpen else { return }; active?.right(); redraw() }

    /// Offer typed input to the open modal. Returns true when the modal
    /// consumed it (form modals); false — including when no modal is open —
    /// means the caller should fall through to its default input target.
    @discardableResult
    func routeText(_ data: String) -> Bool {
        guard isOpen, let active else { return false }
        guard active.handleText(data) else { return false }
        redraw()
        return true
    }

    private func redraw() {
        guard let active else { return }
        // The width handed to the modal must never exceed the drawable width
        // (no artificial floor): a floor above the real width would defeat
        // the modal-side truncation on exactly the narrow terminals the
        // contract exists for. The trailing `fit` is a backstop that enforces
        // the contract once at the host — a no-op for compliant modals, and
        // it keeps a stray overlong line from soft-wrapping and pushing the
        // modal's title off-screen.
        let width = max(1, availableWidth())
        let lines = active.render(maxRows: max(4, availableRows()), width: width)
        renderModalLines(lines.map { ANSI.fit($0, to: width) })
        requestRender()
    }
}

/// Focus target the coding TUI installs in front of the prompt row. Keybound
/// keys (enter / esc / tab / up / down) never reach it — this router only sees
/// the raw sequences the keybinding registry declined, i.e. typed text and the
/// arrows the TUI leaves unbound (left/right). While a modal is open those are
/// offered to the modal first:
///
///   - left / right move the modal's tab selection (routed here rather than
///     bound in the TUI so that, with no modal open, the raw CSI still reaches
///     the prompt editor's own cursor handling synchronously),
///   - everything else goes through `routeText` (form modals consume it).
///
/// Whatever the modal declines falls through to the prompt row, so list modals
/// and the no-modal case behave exactly as before the router existed. Never
/// added to the component tree — it only owns input focus, and forwards the
/// `Focusable` flag so the prompt row's cursor rendering is unchanged.
final class ModalInputRouter: Component, Focusable, @unchecked Sendable {
    private let host: ModalHost
    private let fallback: PromptRow

    @MainActor
    init(host: ModalHost, fallback: PromptRow) {
        self.host = host
        self.fallback = fallback
    }

    var focused: Bool {
        get { fallback.focused }
        set { fallback.focused = newValue }
    }
    var wantsKeyRelease: Bool { fallback.wantsKeyRelease }

    /// The router never renders — it stands in for the prompt row only as the
    /// runner's focus target; the prompt row stays in the frame's own tree.
    func render(width: Int) -> [String] { [] }
    func invalidate() { fallback.invalidate() }

    func handleInput(_ data: String) {
        // Raw stdin is delivered on the main queue (RawStdin's read source is
        // main-confined), so hopping onto the MainActor host is safe here.
        MainActor.assumeIsolated {
            if host.isOpen {
                switch Keys.parse(data)?.name {
                case "left": host.routeLeft(); return
                case "right": host.routeRight(); return
                default: break
                }
                if host.routeText(data) { return }
            }
            fallback.handleInput(data)
        }
    }
}
