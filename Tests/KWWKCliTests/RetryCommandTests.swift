import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

@Suite("/retry retry-state transitions")
struct RetryCommandTests {

    @Test("turnEndedRetryable flags only .error and .aborted finishes")
    func retryableClassification() {
        #expect(turnEndedRetryable(AgentRunSummary(finalStopReason: .error)))
        #expect(turnEndedRetryable(AgentRunSummary(finalStopReason: .aborted)))
        #expect(!turnEndedRetryable(AgentRunSummary(finalStopReason: .stop)))
        #expect(!turnEndedRetryable(AgentRunSummary(finalStopReason: .toolUse)))
        #expect(!turnEndedRetryable(AgentRunSummary(finalStopReason: nil)))
    }

    // A single-user-message transcript, the common in-flight shape.
    private func transcript(text: String, images: [ImageContent] = []) -> [Message] {
        var blocks: [UserBlock] = [.text(TextContent(text: text))]
        for img in images { blocks.append(.image(img)) }
        return [.user(UserMessage(content: blocks))]
    }

    @MainActor
    @Test("retryArmTarget returns nil when the turn was not user-initiated (covers #6)")
    func notArmedWithoutTracking() {
        // A failed internal turn (/init, custom command) never sets
        // trackedActive, so even an .error finish must NOT arm /retry with its
        // stale internal prompt.
        let target = retryArmTarget(
            summary: AgentRunSummary(finalStopReason: .error),
            aborted: false,
            trackedActive: false,
            messages: transcript(text: "internal /init prompt")
        )
        #expect(target == nil, "trackedActive=false must never arm /retry")
    }

    @MainActor
    @Test("retryArmTarget returns nil for a successful (non-retryable) turn")
    func notArmedOnSuccess() {
        // A clean .stop finish is not retryable, so /retry stays disarmed even
        // for a tracked, user-initiated turn.
        let target = retryArmTarget(
            summary: AgentRunSummary(finalStopReason: .stop),
            aborted: false,
            trackedActive: true,
            messages: transcript(text: "do the thing")
        )
        #expect(target == nil, "a successful turn leaves /retry disarmed")
    }

    @MainActor
    @Test("retryArmTarget derives text + images from the last user message on failure")
    func armsFromLastUserMessage() {
        let img = ImageContent(data: "AAAA", mimeType: "image/png")
        // Two turns already settled; the retry target is the LAST user message.
        var messages = transcript(text: "first prompt")
        messages.append(.assistant(AssistantMessage(
            content: [.text(TextContent(text: "ok"))],
            api: "x", provider: "y", model: "z"
        )))
        messages.append(contentsOf: transcript(text: "second prompt", images: [img]))

        let onError = retryArmTarget(
            summary: AgentRunSummary(finalStopReason: .error),
            aborted: false,
            trackedActive: true,
            messages: messages
        )
        #expect(onError?.text == "second prompt")
        #expect(onError?.images == [img])

        // An explicit abort (no summary) arms identically.
        let onAbort = retryArmTarget(
            summary: nil,
            aborted: true,
            trackedActive: true,
            messages: messages
        )
        #expect(onAbort?.text == "second prompt")
        #expect(onAbort?.images == [img])
    }

    @MainActor
    @Test("retryArmTarget joins multiple text blocks and returns nil with no user message")
    func armEdgeCases() {
        let multi: [Message] = [.user(UserMessage(content: [
            .text(TextContent(text: "line one")),
            .text(TextContent(text: "line two")),
        ]))]
        let t = retryArmTarget(summary: nil, aborted: true, trackedActive: true, messages: multi)
        #expect(t?.text == "line one\nline two")

        // No user message in the transcript → nothing to arm.
        let none: [Message] = [.assistant(AssistantMessage(
            content: [.text(TextContent(text: "hi"))],
            api: "x", provider: "y", model: "z"
        ))]
        #expect(retryArmTarget(summary: nil, aborted: true, trackedActive: true, messages: none) == nil)
    }

    @MainActor
    @Test("steer + Esc-abort: /retry resubmits the in-flight prompt exactly once")
    func steerThenAbortResubmitsOnce() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel()))

        // A direct submit of "A" is in flight (its user message is in the
        // transcript); the user then steers a follow-up "B" while it streams.
        agent.state.messages = [.user(UserMessage(text: "A"))]
        agent.steer(.user(UserMessage(text: "B")))

        let retry = TurnRetryState()
        retry.trackedActive = true  // set by both the submit and steer paths

        // Esc-abort: drop the queued-but-unstarted steer so it can't
        // double-drain, then arm /retry from the message actually in flight.
        agent.clearSteeringQueue()
        let target = retryArmTarget(
            summary: nil,
            aborted: true,
            trackedActive: retry.trackedActive,
            messages: agent.state.messages
        )
        if let target {
            retry.lastText = target.text
            retry.lastImages = target.images
            retry.failed = true
        }
        retry.trackedActive = false

        // The steer is gone (no double-drain) and /retry would resubmit exactly
        // the in-flight prompt "A" — not the discarded steer "B".
        #expect(agent.queuedSteeringCount() == 0, "queued steer dropped, so it won't also drain")
        #expect(retry.failed)
        #expect(retry.lastText == "A", "/retry resubmits the aborted prompt, not the steer")
        #expect(retry.trackedActive == false, "tracking flag consumed on abort")
    }

    @MainActor
    @Test("/retry no-ops when no failure was recorded")
    func retryGuard() {
        let retry = TurnRetryState()
        // Fresh: nothing to retry.
        #expect(retryWouldResubmit(retry) == false)

        // failed but no recorded prompt → still a no-op.
        retry.failed = true
        #expect(retry.lastText == nil)
        #expect(retryWouldResubmit(retry) == false)

        // A recorded failure resubmits.
        retry.lastText = "A"
        #expect(retryWouldResubmit(retry))
    }
}

/// Mirrors the `/retry` handler guard (`guard retry.failed, let _ = retry.lastText`):
/// true only when a failed turn has a recorded prompt to resubmit.
@MainActor
private func retryWouldResubmit(_ retry: TurnRetryState) -> Bool {
    retry.failed && retry.lastText != nil
}
