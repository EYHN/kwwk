import Foundation

/// Per-path serial queue for file mutations. Matches pi-coding-agent's
/// `withFileMutationQueue` — overlapping edits and writes on the same physical
/// file run strictly one-after-the-other, while unrelated files run in parallel.
///
/// Uniqueness is determined by the file's inode when the file exists;
/// otherwise the absolute path is used. This keeps symlink siblings on the
/// same queue.
public actor FileMutationQueue {
    public static let shared = FileMutationQueue()

    private var inflight: [String: Task<Void, Never>] = [:]

    public init() {}

    /// Run `body` serially with respect to other mutations against the same
    /// file. Returns the body's result — throws if body throws.
    public func run<T: Sendable>(_ path: String, body: @Sendable @escaping () async throws -> T) async throws -> T {
        let key = queueKey(for: path)
        let previous = inflight[key]
        let box = ResultBox<T>()
        let task = Task<Void, Never> {
            if let previous { _ = await previous.value }
            do {
                let value = try await body()
                await box.set(.success(value))
            } catch {
                await box.set(.failure(error))
            }
        }
        inflight[key] = task
        await task.value
        // Clean up if we're the tail of the chain.
        if let tail = inflight[key], tail == task {
            inflight.removeValue(forKey: key)
        }
        switch await box.get() {
        case .success(let v): return v
        case .failure(let e): throw e
        case .none: throw CancellationError()
        }
    }

    private func queueKey(for path: String) -> String {
        // If the file exists, key by inode so symlinks collapse.
        var stats = stat()
        if stat(path, &stats) == 0 {
            return "inode:\(stats.st_dev):\(stats.st_ino)"
        }
        return "path:\(path)"
    }
}

/// Small value-passing box shared across the await gate inside the actor.
private actor ResultBox<T: Sendable> {
    var result: Result<T, Error>?
    func set(_ value: Result<T, Error>) { result = value }
    func get() -> Result<T, Error>? { result }
}
