import Foundation
import Testing
@testable import KWWKCli

// The welcome card renders from a live `WelcomeHeaderState` snapshot so a
// resize full-repaint reflects the current login state; these tests pin the
// logged-out greeting/banner and the snapshot swap a /login performs.

@Suite("WelcomeScreen + live header state")
struct WelcomeScreenTests {

    private func context(loggedOut: Bool) -> WelcomeContext {
        WelcomeContext(
            version: "0.0.0",
            modelId: loggedOut ? "no provider" : "claude-opus-4-8",
            providerName: loggedOut ? "not signed in" : "Anthropic",
            cwd: "/tmp/project",
            branch: "main",
            recentSessions: [],
            loggedOut: loggedOut
        )
    }

    private func plain(_ lines: [String]) -> String {
        lines.map { ANSI.stripEscapes($0) }.joined(separator: "\n")
    }

    @Test("logged-out card greets with Welcome! and the /login banner (wide + compact)")
    func loggedOutGreeting() {
        // Wide layout.
        let wide = plain(WelcomeScreen.render(context(loggedOut: true), width: 100))
        #expect(wide.contains("Welcome!"))
        #expect(!wide.contains("Welcome back!"))
        #expect(wide.contains("not signed in — run /login"))
        // Compact layout (no greeting line, but the banner must still show).
        let compact = plain(WelcomeScreen.render(context(loggedOut: true), width: 40))
        #expect(!compact.contains("Welcome back!"))
        #expect(compact.contains("not signed in — run /login"))
    }

    @Test("logged-in card greets with Welcome back! and no banner")
    func loggedInGreeting() {
        let wide = plain(WelcomeScreen.render(context(loggedOut: false), width: 100))
        #expect(wide.contains("Welcome back!"))
        #expect(!wide.contains("not signed in"))
    }

    @Test("WelcomeHeaderState snapshot swap drops the stale banner after login")
    func headerStateSwap() {
        let state = WelcomeHeaderState(context(loggedOut: true))
        #expect(plain(WelcomeScreen.render(state.snapshot(), width: 100))
            .contains("not signed in — run /login"))

        // What updateFrameStatus does after a successful /login: publish the
        // live context so the next resize repaint renders the fresh state.
        state.update(context(loggedOut: false))
        let after = plain(WelcomeScreen.render(state.snapshot(), width: 100))
        #expect(!after.contains("not signed in"))
        #expect(after.contains("claude-opus-4-8"))
    }
}
