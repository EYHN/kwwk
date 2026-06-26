import Foundation
import Testing
@testable import KWWKCli
@testable import KWWKAgent

@Suite("SessionPicker selection")
struct SessionPickerTests {
    private func info(_ id: String, cwd: String, msgs: Int) -> SessionStore.SessionInfo {
        SessionStore.SessionInfo(
            id: id,
            cwd: cwd,
            createdAt: 0,
            model: nil,
            provider: nil,
            updatedAt: Int64(Date().timeIntervalSince1970 * 1000),
            messageCount: msgs,
            path: URL(fileURLWithPath: "/tmp/\(id).jsonl")
        )
    }

    @Test("a valid number selects the matching session")
    func selectsByIndex() {
        let infos = [
            info("aaa", cwd: "/proj/one", msgs: 3),
            info("bbb", cwd: "/proj/two", msgs: 7),
        ]
        #expect(SessionPicker.select(from: infos, line: "2")?.id == "bbb")
        #expect(SessionPicker.select(from: infos, line: " 1 \n")?.id == "aaa")
    }

    @Test("blank or out-of-range input cancels")
    func cancels() {
        let infos = [info("aaa", cwd: "/p", msgs: 1)]
        #expect(SessionPicker.select(from: infos, line: "") == nil)
        #expect(SessionPicker.select(from: infos, line: "\n") == nil)
        #expect(SessionPicker.select(from: infos, line: "5") == nil)
        #expect(SessionPicker.select(from: infos, line: "abc") == nil)
    }

    @Test("rendered row shows dir basename, message count, and id prefix")
    func rendersRow() {
        let row = SessionPicker.renderRow(info("abcdef12345", cwd: "/home/me/myproj", msgs: 4), index: 1)
        #expect(row.contains("1)"))
        #expect(row.contains("myproj"))
        #expect(row.contains("4 msgs"))
        #expect(row.contains("abcdef12"))
    }
}
