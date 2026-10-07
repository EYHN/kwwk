import Foundation
import Testing
@testable import KWWKAI

/// Kimi For Coding's answer to a 278k-token k3 request on a Plus login,
/// captured 2026-10-07.
let kimiPlanRefusalBody = #"{"error":{"type":"authentication_error","message":"Your current plan supports only k3 up to 256K context. 1M context is available on higher-tier Kimi Code plans. Upgrade: https://www.kimi.com/code?from=server_k3_error#pricing"},"type":"error"}"#

@Suite("Kimi plan context limit")
struct KimiPlanContextLimitTests {
    @Test("Kimi's plan refusal is a context overflow even though it arrives as 401")
    func planRefusalIsOverflow() {
        #expect(ProviderFailure(message: kimiPlanRefusalBody, httpStatus: 401).category == .contextOverflow)
        #expect(ProviderFailure(message: kimiPlanRefusalBody, httpStatus: 403).category == .contextOverflow)
        // Without a structured status the same body still reads as overflow.
        #expect(ProviderFailure(message: kimiPlanRefusalBody).category == .contextOverflow)
        #expect(ProviderContextLimit.isInputOverflow(kimiPlanRefusalBody))
    }

    @Test("other 401 and 403 answers stay authentication failures")
    func otherAuthFailuresUnchanged() {
        let invalidKey = #"{"error":{"type":"authentication_error","message":"The API Key appears to be invalid or may have expired. Please verify your credentials and try again."}}"#
        #expect(ProviderFailure(message: invalidKey, httpStatus: 401).category == .authentication)
        #expect(ProviderFailure(message: "forbidden", httpStatus: 403).category == .authentication)
        // A generic overflow phrase under 401 is still a login problem.
        #expect(ProviderFailure(message: "prompt is too long", httpStatus: 401).category == .authentication)
        #expect(!ProviderContextLimit.isPlanContextLimit("Your current subscription does not have access to Kimi Code right now."))
    }
}
