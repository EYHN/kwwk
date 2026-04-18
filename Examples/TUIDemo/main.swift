import Foundation
import KWTUI

/// Minimal kw-tui demo. Type anything, press Enter to append it to the log,
/// Ctrl-C / Esc to exit.
@main
struct TUIDemo {
    static func main() async throws {
        let runner = TUIRunner(useAlternateScreen: true, hideCursor: false)

        let header = TextComponent("kw-tui demo — type, Enter appends, Esc / Ctrl-C exits")
        let markdown = MarkdownComponent("""
        ## Highlights

        - Fully differential rendering
        - `CURSOR_MARKER` keeps the hardware cursor in sync
        - Resize triggers full redraws automatically
        """)
        let log = TextComponent([])
        let input = InputComponent()

        runner.tui.addChild(header)
        runner.tui.addChild(TextComponent(""))
        runner.tui.addChild(markdown)
        runner.tui.addChild(TextComponent(""))
        runner.tui.addChild(log)
        runner.tui.addChild(TextComponent(""))
        runner.tui.addChild(input)
        runner.focus(input)

        runner.bind(.init("enter")) { _ in
            let entry = input.value
            guard !entry.isEmpty else { return }
            var lines = log.lines
            lines.append("> \(entry)")
            log.lines = lines
            log.invalidate()
            input.value = ""
        }
        runner.bind(.init("escape")) { _ in runner.exit() }
        runner.bind(.ctrl("c")) { _ in runner.exit() }

        try await runner.run()
    }
}
