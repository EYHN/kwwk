import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

@Suite("goal tool + store")
struct GoalToolTests {
    @Test("store transitions")
    func transitions() {
        let s = GoalStore()
        #expect(s.snapshot().status == .dropped)
        s.start("ship X")
        #expect(s.isActive)
        #expect(s.snapshot().objective == "ship X")
        s.recordAutoContinue(); s.recordAutoContinue()
        #expect(s.snapshot().autoContinueCount == 2)
        s.resetAutoContinue()
        #expect(s.snapshot().autoContinueCount == 0)
        s.pauseForCap()
        #expect(s.snapshot().status == .paused)
        s.resume()
        #expect(s.snapshot().status == .active)
        s.complete()
        #expect(s.snapshot().status == .complete)
        s.stop()
        #expect(s.snapshot().status == .dropped && s.snapshot().objective == "")
    }

    @Test("goal get returns current state")
    func toolGet() async throws {
        let store = GoalStore(); store.start("build a parser")
        let tool = createGoalTool(store: store)
        let r = try await tool.execute("c1", .object(["op": .string("get")]), nil, nil)
        if case .object(let d) = r.details ?? .null,
           case .string(let obj) = d["objective"] ?? .null,
           case .string(let st) = d["status"] ?? .null {
            #expect(obj == "build a parser")
            #expect(st == "active")
        } else { Issue.record("missing details") }
    }

    @Test("goal complete flips the store")
    func toolComplete() async throws {
        let store = GoalStore(); store.start("do the thing")
        let tool = createGoalTool(store: store)
        _ = try await tool.execute("c1", .object(["op": .string("complete")]), nil, nil)
        #expect(store.snapshot().status == .complete)
    }

    @Test("complete is a no-op unless the goal is active (no resurrection)")
    func completeConditional() {
        let s = GoalStore()
        #expect(s.complete() == false)          // no goal at all
        #expect(s.snapshot().status == .dropped)
        s.start("x"); s.stop()                   // user cleared it
        #expect(s.complete() == false)           // stale turn can't complete it
        #expect(s.snapshot().status == .dropped)
        s.start("y"); s.pauseForCap()            // cap-paused
        #expect(s.complete() == false)
        #expect(s.snapshot().status == .paused)
        s.resume()                               // active again
        #expect(s.complete() == true)
        #expect(s.snapshot().status == .complete)
    }

    @Test("multi-block user message with a marker text block is NOT a continuation")
    func multiBlockNotHidden() {
        // A real user message: a marker-quoting text block plus an image. Must be
        // preserved (not redacted/suppressed) — only lone-text-block synthetic
        // continuations count.
        let img = ImageContent(data: "AAAA", mimeType: "image/png")
        let multi = Message.user(UserMessage(content: [
            .text(TextContent(text: "\(goalContinuationMarker) why is this in my logs?")),
            .image(img),
        ]))
        #expect(isHiddenGoalContinuation(multi) == false)
        #expect(redactedForPersistence(multi) == multi)   // passed through intact
    }

    @Test("goal rejects unknown op")
    func toolBadOp() async {
        let tool = createGoalTool(store: GoalStore())
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute("c1", .object(["op": .string("nope")]), nil, nil)
        }
    }

    @Test("undoAutoContinue rolls back a lost-race count, floors at 0")
    func undoCount() {
        let s = GoalStore(); s.start("x")
        s.recordAutoContinue(); s.recordAutoContinue()
        s.undoAutoContinue()
        #expect(s.snapshot().autoContinueCount == 1)
        s.undoAutoContinue(); s.undoAutoContinue()   // floors, no underflow
        #expect(s.snapshot().autoContinueCount == 0)
    }

    @Test("isHiddenGoalContinuation flags only user messages that START with the marker")
    func hiddenPredicate() {
        let hidden = Message.user(UserMessage(content: [.text(TextContent(
            text: "\(goalContinuationMarker)\nContinue work on the active goal."))]))
        let normal = Message.user(UserMessage(content: [.text(TextContent(text: "hello"))]))
        // A user who merely QUOTES the marker mid-sentence is real input, not a
        // synthetic continuation — must not be flagged (anchored on prefix).
        let quoting = Message.user(UserMessage(content: [.text(TextContent(
            text: "why does \(goalContinuationMarker) show up in my logs?"))]))
        let assistant = Message.assistant(AssistantMessage(
            content: [.text(TextContent(text: goalContinuationMarker))],
            api: "anthropic-messages", provider: "anthropic", model: "m"))
        #expect(isHiddenGoalContinuation(hidden) == true)
        #expect(isHiddenGoalContinuation(normal) == false)
        #expect(isHiddenGoalContinuation(quoting) == false)
        #expect(isHiddenGoalContinuation(assistant) == false)
    }

    @Test("redactedForPersistence keeps role+marker, drops the objective; passes others through")
    func redaction() {
        let cont = Message.user(UserMessage(content: [.text(TextContent(
            text: "\(goalContinuationMarker)\nContinue: ship the secret objective XYZ."))]))
        let out = redactedForPersistence(cont)
        guard case .user(let u) = out, case .text(let t) = u.content.first else {
            Issue.record("expected a user text message"); return
        }
        #expect(t.text.hasPrefix(goalContinuationMarker))   // still display-suppressed
        #expect(!t.text.contains("XYZ"))                    // objective not on disk
        #expect(isHiddenGoalContinuation(out) == true)      // stays recognizably hidden
        // Ordinary messages are untouched (identity).
        let normal = Message.user(UserMessage(content: [.text(TextContent(text: "hello"))]))
        #expect(redactedForPersistence(normal) == normal)
    }
}
