import Foundation

/// A single retry owner per logical call: providers report evidence, the Agent
/// or one-shot caller schedules attempts. This avoids nested retry multiplication.
public struct ProviderRetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelayMs: UInt64
    public var maxRetryDelayMs: Int?
    public init(maxAttempts: Int = 5, baseDelayMs: UInt64 = 1_000, maxRetryDelayMs: Int? = nil) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelayMs = baseDelayMs
        self.maxRetryDelayMs = maxRetryDelayMs
    }

    /// Nil means terminal (including a server-requested delay above the cap).
    /// Never shorten Retry-After and hammer the server before its deadline.
    public func delay(for failure: ProviderFailure, attempt: Int, jitter: Double = 1) -> UInt64? {
        guard failure.isRetryable, attempt >= 0, attempt < maxAttempts - 1 else { return nil }
        if let requested = failure.retryAfterMs {
            guard requested.isFinite, requested >= 0, requested < Double(UInt64.max) else { return nil }
            let cap = maxRetryDelayMs ?? 60_000
            guard cap == 0 || requested <= Double(max(0, cap)) else { return nil }
            return UInt64(requested.rounded(.up))
        }
        let scaled = Double(baseDelayMs) * pow(2, Double(min(attempt, 30)))
        let factor = jitter.isFinite ? min(1, max(0.75, jitter)) : 1
        return UInt64(min(scaled, 30_000) * factor)
    }

    public static func wait(_ delayMs: UInt64, cancellation: CancellationHandle?) async throws {
        var remaining = delayMs
        repeat {
            try Task.checkCancellation()
            if cancellation?.isCancelled == true { throw CancellationError() }
            if remaining == 0 { return }
            let step = min(remaining, 100)
            try await Task.sleep(nanoseconds: step * 1_000_000)
            remaining -= step
        } while true
    }

    /// Self-contained calls (e.g. summaries) have no executed tools or committed
    /// output to replay. Return the last provider failure intact on exhaustion.
    public func complete(cancellation: CancellationHandle? = nil,
                         operation: () async throws -> AssistantMessage) async throws -> AssistantMessage {
        for attempt in 0..<maxAttempts {
            try await Self.wait(0, cancellation: cancellation)
            let result: AssistantMessage
            do { result = try await operation() }
            catch {
                guard let delay = delay(for: .capture(error), attempt: attempt, jitter: .random(in: 0.75...1)) else { throw error }
                try await Self.wait(delay, cancellation: cancellation)
                continue
            }
            guard result.stopReason == .error, let failure = result.providerFailure,
                  let delay = delay(for: failure, attempt: attempt, jitter: .random(in: 0.75...1)) else { return result }
            try await Self.wait(delay, cancellation: cancellation)
        }
        preconditionFailure("Every final attempt returns or throws")
    }
}
