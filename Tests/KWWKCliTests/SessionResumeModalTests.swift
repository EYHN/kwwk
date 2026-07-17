import Foundation
import Testing
@testable import KWWKCli
@testable import KWWKAgent

@MainActor
private func info(
    _ id: String,
    cwd: String = "/home/me/myproj",
    msgs: Int = 3,
    title: String? = nil
) -> SessionStore.SessionInfo {
    SessionStore.SessionInfo(
        id: id,
        cwd: cwd,
        createdAt: 0,
        model: nil,
        provider: nil,
        updatedAt: Int64(Date().timeIntervalSince1970 * 1000),
        messageCount: msgs,
        title: title,
        path: URL(fileURLWithPath: "/tmp/\(id).jsonl")
    )
}

private func strip(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
}

@Suite("SessionResumeModal")
struct SessionResumeModalTests {

    @MainActor
    @Test("confirm selects the highlighted session; cancel never selects")
    func confirmAndCancel() {
        let sessions = [info("aaa"), info("bbb"), info("ccc")]
        let picked = Ref<String?>(nil)
        let cancelled = Ref<Bool>(false)
        let modal = SessionResumeModal(
            sessions: sessions,
            currentSessionId: "aaa",
            onSelect: { picked.value = $0.id },
            onCancel: { cancelled.value = true }
        )
        modal.down()
        modal.confirm()
        #expect(picked.value == "bbb")
        modal.cancel()
        #expect(cancelled.value == true)
    }

    @MainActor
    @Test("confirming the current session closes without replacing it")
    func currentSessionIsNoOp() {
        let picked = Ref<String?>(nil)
        let cancelled = Ref<Bool>(false)
        let modal = SessionResumeModal(
            sessions: [info("current"), info("other")],
            currentSessionId: "current",
            onSelect: { picked.value = $0.id },
            onCancel: { cancelled.value = true }
        )

        modal.confirm()

        #expect(picked.value == nil, "the destructive replacement callback must not run")
        #expect(cancelled.value, "the host's cancel callback closes the modal")
    }

    @MainActor
    @Test("up wraps from the top to the bottom row")
    func wrapAround() {
        let sessions = [info("aaa"), info("bbb"), info("ccc")]
        let picked = Ref<String?>(nil)
        let modal = SessionResumeModal(
            sessions: sessions,
            currentSessionId: "zzz",
            onSelect: { picked.value = $0.id },
            onCancel: {}
        )
        modal.up()
        modal.confirm()
        #expect(picked.value == "ccc")
    }

    @MainActor
    @Test("rows show title (or dir basename), relative age, count, and current tag")
    func rowContent() {
        let sessions = [
            info("aaa", cwd: "/home/me/myproj", msgs: 1),
            info("bbb", cwd: "/home/me/other", msgs: 4, title: "renamed session"),
        ]
        let modal = SessionResumeModal(
            sessions: sessions,
            currentSessionId: "aaa",
            onSelect: { _ in },
            onCancel: {}
        )
        let lines = modal.render(maxRows: 40, width: 80).map(strip)
        #expect(lines.contains(where: { $0.contains("Resume a session") }))
        let first = lines.first(where: { $0.contains("myproj") })
        #expect(first?.contains("1 msg") == true)
        #expect(first?.contains("· current") == true)
        // A user-set title (from /rename) replaces the dir basename.
        let second = lines.first(where: { $0.contains("renamed session") })
        #expect(second != nil)
        #expect(second?.contains("4 msgs") == true)
        #expect(second?.contains("current") == false)
    }

    @MainActor
    @Test("empty list renders the no-sessions notice within budget")
    func emptyList() {
        let modal = SessionResumeModal(
            sessions: [],
            currentSessionId: "x",
            onSelect: { _ in },
            onCancel: {}
        )
        // confirm on an empty list must not fire the callback.
        modal.confirm()
        for maxRows in 4...40 {
            let lines = modal.render(maxRows: maxRows, width: 80)
            #expect(lines.count <= maxRows, "overflow at maxRows \(maxRows)")
            #expect(lines.contains(where: { strip($0).contains("no saved sessions") }))
        }
    }

    @MainActor
    @Test("render never overflows maxRows and keeps the selection visible")
    func staysWithinBudget() {
        let sessions = (0..<50).map { info("s\($0)", cwd: "/proj/s\($0)") }
        let modal = SessionResumeModal(
            sessions: sessions,
            currentSessionId: "s0",
            onSelect: { _ in },
            onCancel: {}
        )
        // At every terminal height (including tiny ones) and at every scroll
        // position, the render must fit the budget AND keep the selected row
        // visible — the pre-ModalListCore implementation overflowed by one.
        for maxRows in 4...40 {
            for step in 0..<50 {
                let lines = modal.render(maxRows: maxRows, width: 80).map(strip)
                #expect(lines.count <= maxRows, "overflow at maxRows \(maxRows), selection \(step)")
                #expect(lines.contains(where: { $0.contains("❯ s\(step)  ") }),
                        "selected row s\(step) must be within the window at maxRows \(maxRows)")
                modal.down()
            }
        }
    }
}

@MainActor
private final class Ref<T> {
    var value: T
    init(_ v: T) { self.value = v }
}
