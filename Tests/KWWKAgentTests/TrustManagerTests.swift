import Foundation
import Testing
@testable import KWWKAgent

@Suite("TrustManager store round-trip")
struct TrustManagerTests {

    private func tempStore() -> (TrustManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-trust-\(UUID().uuidString.prefix(8))")
        let url = dir.appendingPathComponent("trust.json")
        return (TrustManager(storeURL: url), dir)
    }

    @Test("unknown dir is untrusted with no decision")
    func unknownIsUntrusted() {
        let (mgr, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = "/tmp/kwwk-some-project-\(UUID().uuidString.prefix(6))"
        #expect(mgr.isTrusted(project) == false)
        #expect(mgr.decision(project) == nil)
    }

    @Test("trust then read back persists across instances")
    func roundTrip() {
        let (mgr, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = TrustManager.normalize("/tmp/kwwk-rt-\(UUID().uuidString.prefix(6))")

        mgr.trust(project)
        #expect(mgr.isTrusted(project) == true)
        #expect(mgr.decision(project) == true)

        // A fresh manager reading the same file sees the persisted decision.
        let reopened = TrustManager(storeURL: mgr.storeURL)
        #expect(reopened.isTrusted(project) == true)
    }

    @Test("explicit distrust is distinct from no-decision")
    func distrust() {
        let (mgr, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = TrustManager.normalize("/tmp/kwwk-no-\(UUID().uuidString.prefix(6))")

        mgr.distrust(project)
        #expect(mgr.isTrusted(project) == false)
        #expect(mgr.decision(project) == false)
    }

    @Test("nearest-ancestor inheritance: trusting a parent trusts children")
    func ancestorInheritance() {
        let (mgr, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let parent = TrustManager.normalize("/tmp/kwwk-parent-\(UUID().uuidString.prefix(6))")
        let child = (parent as NSString).appendingPathComponent("sub/deep")

        mgr.trust(parent)
        #expect(mgr.isTrusted(child) == true)
        #expect(mgr.decision(child) == true)
    }

    @Test("a closer false decision overrides an ancestor's true")
    func closerOverrides() {
        let (mgr, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let parent = TrustManager.normalize("/tmp/kwwk-ovr-\(UUID().uuidString.prefix(6))")
        let child = (parent as NSString).appendingPathComponent("blocked")

        mgr.trust(parent)
        mgr.distrust(child)
        #expect(mgr.isTrusted(child) == false)
        // A sibling still inherits the parent's trust.
        let sibling = (parent as NSString).appendingPathComponent("ok")
        #expect(mgr.isTrusted(sibling) == true)
    }

    @Test("forget reverts to inherited / untrusted")
    func forget() {
        let (mgr, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = TrustManager.normalize("/tmp/kwwk-fg-\(UUID().uuidString.prefix(6))")

        mgr.trust(project)
        #expect(mgr.isTrusted(project) == true)
        mgr.forget(project)
        #expect(mgr.decision(project) == nil)
        #expect(mgr.isTrusted(project) == false)
    }

    @Test("missing trust.json reads as empty, no error")
    func missingIsEmpty() throws {
        let (mgr, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(mgr.decision("/some/dir") == nil)
        #expect(try mgr.decisionChecked("/some/dir") == nil)
    }

    @Test("malformed trust.json surfaces an error and does not clobber decisions")
    func malformedSurfaces() throws {
        let (mgr, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{ not json".write(to: mgr.storeURL, atomically: true, encoding: .utf8)

        #expect(throws: TrustStoreError.self) { try mgr.decisionChecked("/x") }
        // Write must refuse to clobber a malformed file.
        #expect(throws: TrustStoreError.self) { try mgr.trustChecked("/x") }
        // Original corrupt bytes still on disk.
        #expect(try String(contentsOf: mgr.storeURL, encoding: .utf8) == "{ not json")
        // Non-throwing API fails safe (untrusted) and records the error.
        #expect(mgr.decision("/x") == nil)
        #expect(mgr.isTrusted("/x") == false)
        #expect(mgr.lastLoadError != nil)
    }

    @Test("null value in store is treated as no-decision, not an error")
    func nullValueOk() throws {
        let (mgr, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"/a": null, "/b": true}"#.write(to: mgr.storeURL, atomically: true, encoding: .utf8)
        #expect(try mgr.decisionChecked("/a") == nil)
        #expect(try mgr.decisionChecked("/b") == true)
    }

    @Test("requiresPrompt true only when project has trust-requiring resources")
    func requiresPrompt() throws {
        let (mgr, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-proj-\(UUID().uuidString.prefix(6))")
        let commandsDir = project.appendingPathComponent(".kwwk/commands")
        try FileManager.default.createDirectory(at: commandsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }

        // No decision + resources present → should prompt.
        #expect(mgr.requiresPrompt(for: project.path) == true)

        // After trusting, no prompt needed.
        mgr.trust(project.path)
        #expect(mgr.requiresPrompt(for: project.path) == false)

        // A bare directory with no `.kwwk` resources never prompts.
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-bare-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bare) }
        #expect(mgr.requiresPrompt(for: bare.path) == false)
    }
}
