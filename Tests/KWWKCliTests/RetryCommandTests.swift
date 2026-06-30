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

    @MainActor
    @Test("submit clears failed; an .error agentEnd flips it; /retry no-ops while clean")
    func retryStateLifecycle() {
        let retry = TurnRetryState()

        // Fresh state: nothing to retry, so the /retry guard short-circuits.
        #expect(retry.failed == false)
        #expect(retryWouldResubmit(retry) == false, "/retry no-ops when failed=false")

        // Submit records the prompt and clears the failed flag (mirrors
        // submitBuiltPrompt's first three lines).
        retry.lastText = "do the thing"
        retry.lastImages = []
        retry.failed = false
        #expect(retryWouldResubmit(retry) == false, "a clean turn is not retryable even with a recorded prompt")

        // A genuine failure arrives on the event stream as an .error agentEnd —
        // the listener flips `failed` via turnEndedRetryable.
        let summary = AgentRunSummary(finalStopReason: .error)
        if turnEndedRetryable(summary) { retry.failed = true }
        #expect(retry.failed)
        #expect(retryWouldResubmit(retry), "/retry resubmits once a failure is recorded")
        #expect(retry.lastText == "do the thing")

        // An aborted turn is likewise retryable.
        retry.failed = false
        let aborted = AgentRunSummary(finalStopReason: .aborted)
        if turnEndedRetryable(aborted) { retry.failed = true }
        #expect(retry.failed)
    }

    @MainActor
    @Test("/retry no-ops when no prompt was ever recorded")
    func retryWithoutRecordedPrompt() {
        let retry = TurnRetryState()
        retry.failed = true  // failed but lastText is nil
        #expect(retry.lastText == nil)
        #expect(retryWouldResubmit(retry) == false, "no recorded prompt → nothing to resubmit")
    }
}

/// Mirrors the `/retry` handler guard (`guard retry.failed, let _ = retry.lastText`):
/// true only when a failed turn has a recorded prompt to resubmit.
@MainActor
private func retryWouldResubmit(_ retry: TurnRetryState) -> Bool {
    retry.failed && retry.lastText != nil
}
