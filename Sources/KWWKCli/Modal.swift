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
    /// Lines to render in place of the transcript while the modal is open.
    func render() -> [String]
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

    init(
        layout: CodingLayout,
        restoreTranscript: @escaping () -> Void,
        requestRender: @escaping () -> Void
    ) {
        self.renderModalLines = { lines in
            if let lines {
                layout.setLiveTail(lines)
            } else {
                layout.setLiveTail([])
            }
        }
        self.restoreTranscript = restoreTranscript
        self.requestRender = requestRender
    }

    init(
        renderModalLines: @escaping ([String]?) -> Void,
        restoreTranscript: @escaping () -> Void,
        requestRender: @escaping () -> Void
    ) {
        self.renderModalLines = renderModalLines
        self.restoreTranscript = restoreTranscript
        self.requestRender = requestRender
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

    func routeUp() { guard isOpen else { return }; active?.up(); redraw() }
    func routeDown() { guard isOpen else { return }; active?.down(); redraw() }
    func routeConfirm() { guard isOpen else { return }; active?.confirm() }
    func routeCancel() { guard isOpen else { return }; active?.cancel() }

    private func redraw() {
        guard let active else { return }
        renderModalLines(active.render())
        requestRender()
    }
}
