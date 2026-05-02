import Foundation
import KWWKAI

extension Agent {
    /// Close provider-owned resources associated with this agent's session id.
    ///
    /// This does not mutate the transcript and does not kill background
    /// tasks; callers that own session-scoped task managers should close those
    /// resources separately.
    public func closeSession() async {
        guard let sessionId, !sessionId.isEmpty else { return }
        await KWWKAI.closeProviderSession(sessionId: sessionId)
    }
}
