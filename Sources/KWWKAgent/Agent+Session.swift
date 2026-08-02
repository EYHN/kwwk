import Foundation
import KWWKAI

extension Agent {
    /// Permanently stop this Agent and all background work it owns.
    ///
    /// The current model/tool run is cancelled, queued input is discarded, and
    /// active tasks in every attached `BackgroundTaskManager` are killed. This
    /// waits for the current run to release ownership before returning. Use
    /// `abort()` instead when cancelling only the current run while keeping the
    /// Agent reusable.
    public func stop() async {
        retire()
        await abortAndKillBackgroundTasks()
        clearAllQueues()
        await waitForIdle()
    }

    /// Stop the Agent, including its background tasks, then close
    /// provider-owned resources associated with its session id.
    public func closeSession() async {
        await stop()
        guard let sessionId, !sessionId.isEmpty else { return }
        await KWWKAI.closeProviderSession(sessionId: sessionId)
    }
}
