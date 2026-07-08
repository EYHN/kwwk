import Foundation
import KWWKAI
import KWWKAgent

/// Coalesces the render storm of token streaming. Every `.textDelta` /
/// `.thinkingDelta` used to trigger a synchronous terminal render; with the
/// live tail visible each delta now changes `liveLines`, so per-delta
/// rendering would repaint the live zone at provider speed. Pure stream
/// deltas instead call `schedule()`, which flushes at most once per
/// interval (~30fps). Everything else — commits, tool events, turn
/// boundaries — still renders immediately via its existing path.
@MainActor
final class RenderCoalescer {
    private var scheduled = false
    private let intervalNs: UInt64
    private let flush: @MainActor () -> Void

    init(intervalMs: UInt64 = 33, flush: @escaping @MainActor () -> Void) {
        self.intervalNs = intervalMs * 1_000_000
        self.flush = flush
    }

    func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: intervalNs)
            scheduled = false
            flush()
        }
    }
}

/// True for events that only extend streaming text/thinking — the ones
/// safe to render on the coalesced cadence instead of immediately.
func isPureStreamDelta(_ event: AgentEvent) -> Bool {
    guard case .messageUpdate(_, let amEvent) = event else { return false }
    switch amEvent {
    case .textDelta, .thinkingDelta:
        return true
    default:
        return false
    }
}
