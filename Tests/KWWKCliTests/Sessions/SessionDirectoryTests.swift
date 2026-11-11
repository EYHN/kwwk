import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKCli

@Suite("CLI session directory")
struct SessionDirectoryTests {

    @Test("defaults to ~/.kwwk/sessions when KWWK_SESSION_DIR is unset or empty")
    func defaultsToHomeSessions() {
        let expected = SessionStore.defaultDirectory().standardizedFileURL.path
        #expect(cliSessionDirectory(environment: [:], cwd: "/w").standardizedFileURL.path == expected)
        #expect(
            cliSessionDirectory(environment: ["KWWK_SESSION_DIR": ""], cwd: "/w")
                .standardizedFileURL.path == expected
        )
    }

    @Test("KWWK_SESSION_DIR overrides the directory; relative paths resolve against cwd")
    func environmentOverride() {
        #expect(
            cliSessionDirectory(environment: ["KWWK_SESSION_DIR": "/logs/agent/sessions"], cwd: "/w")
                .path == "/logs/agent/sessions"
        )
        #expect(
            cliSessionDirectory(environment: ["KWWK_SESSION_DIR": "out/sessions"], cwd: "/w")
                .path == "/w/out/sessions"
        )
    }
}
