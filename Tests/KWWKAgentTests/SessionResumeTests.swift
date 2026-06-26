import Foundation
import Testing
@testable import KWWKAgent

@Suite("SessionResume resolution")
struct SessionResumeTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-resume-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("pickInteractive resolves to a fresh session at the agent layer")
    func pickInteractiveFallsBackFresh() async {
        let store = SessionStore(directory: tempDir())
        let r = await store.resolveResume(.pickInteractive, cwd: "/x", freshId: "FIX")
        #expect(r.sessionId == "FIX")
        #expect(r.resumed == false)
    }

    @Test("none resolves to a fresh session")
    func noneFresh() async {
        let store = SessionStore(directory: tempDir())
        let r = await store.resolveResume(.none, cwd: "/x", freshId: "FIX")
        #expect(r.sessionId == "FIX")
        #expect(r.resumed == false)
    }

    @Test("the four resume cases are distinct")
    func casesDistinct() {
        let cases: [SessionResume] = [.none, .latestForCwd, .pickInteractive, .id("abc")]
        #expect(Set(cases).count == 4)
    }
}
