let testBashEnvironment = [
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
]

/// Retries a load-sensitive test body up to `attempts` times, for tests that
/// assert wall-clock upper bounds and flake on oversubscribed CI runners.
///
/// Inside the body, use `try retryCheck(...)` for the load-sensitive
/// assertions: it throws, so a failed early attempt retries instead of
/// recording an issue. Deterministic assertions should stay as `#expect` —
/// a recorded issue fails the test regardless of retries, so real bugs are
/// never masked. The final attempt's error propagates and fails the test.
func withRetries<T>(
    _ attempts: Int = 3,
    _ body: (_ attempt: Int) async throws -> T
) async throws -> T {
    for attempt in 1..<attempts {
        do {
            return try await body(attempt)
        } catch {}
    }
    return try await body(attempts)
}

struct RetryCheckFailure: Error, CustomStringConvertible {
    let description: String
}

/// Throwing counterpart of `#expect` for use inside `withRetries`.
func retryCheck(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw RetryCheckFailure(description: message()) }
}
