import Foundation
import KWWKAI

enum CompactionRetry {
    static func run<T: Sendable>(
        config: AgentContextCompactionConfig,
        cancellation: CancellationHandle?,
        operation: () async throws -> T
    ) async throws -> T {
        var retries = 0
        while true {
            try checkCancellation(cancellation)
            do { return try await operation() }
            catch {
                try checkCancellation(cancellation)
                if error is CancellationError { throw AgentContextCompactionError.cancelled }
                if let error = error as? AgentContextCompactionError, case .cancelled = error { throw error }
                let retryable: Bool
                let description = error.localizedDescription
                let statusRange = description.range(of: "(?i)(?:HTTP|status)\\s+[45][0-9]{2}", options: .regularExpression)
                let parsedStatus = statusRange.flatMap { Int(description[$0].suffix(3)) }
                if let status = (error as? NativeCompactionError)?.status ?? parsedStatus {
                    retryable = [408, 429, 500, 502, 503, 504, 529].contains(status)
                } else {
                    retryable = AgentLoop.isRetryableError(description)
                }
                guard retries < max(0, config.maxRequestRetries), retryable else { throw error }
                let delay = min(config.retryBaseDelayMs, 30_000) * UInt64(1 << min(retries, 5))
                retries += 1
                var remaining = min(delay, 30_000)
                while remaining > 0 {
                    try checkCancellation(cancellation)
                    let step = min(remaining, 50)
                    try await Task.sleep(nanoseconds: step * 1_000_000)
                    remaining -= step
                }
            }
        }
    }

    private static func checkCancellation(_ cancellation: CancellationHandle?) throws {
        if Task.isCancelled || cancellation?.isCancelled == true {
            throw AgentContextCompactionError.cancelled
        }
    }
}
