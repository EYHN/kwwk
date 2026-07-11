import Foundation
import KWWKAI

/// Process-local capacity gate shared by one subagent surface.
///
/// Foreground calls stay fail-fast: making one tool call wait behind another
/// call in the same parallel batch would turn the parent turn into an implicit
/// wait-all. Background calls are admitted against `maxTotal` immediately and
/// receive a cancellable FIFO reservation which starts as soon as compatible
/// capacity is released.
final class SubagentLimiter: @unchecked Sendable {
    private struct QueuedRequest {
        let id: UUID
        let mutating: Bool
        let reservation: SubagentCapacityReservation
    }

    private let lock = NSLock()
    private let limits: SubagentLimits
    private var active = 0
    private var activeMutating = 0
    private var total = 0
    private var queued: [QueuedRequest] = []

    init(limits: SubagentLimits) {
        self.limits = limits
    }

    /// Reserve capacity for a foreground child. This deliberately fails when
    /// no slot is available instead of suspending the parent tool call.
    func reserve(tools: CodingTools) throws -> SubagentPermit {
        let mutating = Self.isMutating(tools)
        try lock.withLock {
            guard total < limits.maxTotal else {
                throw SubagentLimitError.total(limit: limits.maxTotal)
            }
            try validateAvailableCapacity(mutating: mutating)
            total += 1
            claimCapacity(mutating: mutating)
        }
        return SubagentPermit(limiter: self, mutating: mutating)
    }

    /// Admit a background child without waiting for a runner slot. The total
    /// launch budget is charged now, so an arbitrarily large queued fan-out can
    /// never bypass `maxTotal`.
    func enqueue(tools: CodingTools) throws -> SubagentCapacityReservation {
        let mutating = Self.isMutating(tools)
        let id = UUID()
        let reservation = SubagentCapacityReservation(id: id, limiter: self)
        var immediatePermit: SubagentPermit?

        try lock.withLock {
            guard total < limits.maxTotal else {
                throw SubagentLimitError.total(limit: limits.maxTotal)
            }
            total += 1
            if hasAvailableCapacity(mutating: mutating) {
                claimCapacity(mutating: mutating)
                immediatePermit = SubagentPermit(limiter: self, mutating: mutating)
            } else {
                queued.append(QueuedRequest(
                    id: id,
                    mutating: mutating,
                    reservation: reservation
                ))
            }
        }

        if let immediatePermit {
            reservation.resolve(.success(immediatePermit))
        }
        return reservation
    }

    /// Spawn-time capacity context: 1-based position of `id` in the queue
    /// (nil once it holds a runner slot), total queued launches, and the
    /// concurrency limit — enough for the model to estimate expected wait.
    func queueStatus(of id: UUID) -> (position: Int?, queuedCount: Int, maxConcurrent: Int) {
        lock.withLock {
            let index = queued.firstIndex(where: { $0.id == id })
            return (index.map { $0 + 1 }, queued.count, limits.maxConcurrent)
        }
    }

    fileprivate func cancelQueued(id: UUID) {
        var cancelled: SubagentCapacityReservation?
        lock.withLock {
            guard let index = queued.firstIndex(where: { $0.id == id }) else { return }
            cancelled = queued.remove(at: index).reservation
        }
        cancelled?.resolve(.failure(SubagentExecutionCapacityError.cancelled))
    }

    fileprivate func release(mutating: Bool) {
        var grants: [(SubagentCapacityReservation, SubagentPermit)] = []
        lock.withLock {
            active = max(0, active - 1)
            if mutating { activeMutating = max(0, activeMutating - 1) }

            // Preserve FIFO among requests that are currently eligible. A
            // mutating request waiting on the serial mutation slot must not
            // unnecessarily block an independent read-only request.
            while let index = queued.firstIndex(where: {
                hasAvailableCapacity(mutating: $0.mutating)
            }) {
                let request = queued.remove(at: index)
                claimCapacity(mutating: request.mutating)
                grants.append((
                    request.reservation,
                    SubagentPermit(limiter: self, mutating: request.mutating)
                ))
            }
        }
        for (reservation, permit) in grants {
            reservation.resolve(.success(permit))
        }
    }

    private func validateAvailableCapacity(mutating: Bool) throws {
        guard active < limits.maxConcurrent else {
            throw SubagentLimitError.concurrent(limit: limits.maxConcurrent)
        }
        if mutating, activeMutating >= limits.maxConcurrentMutating {
            throw SubagentLimitError.mutatingConcurrent(
                limit: limits.maxConcurrentMutating
            )
        }
    }

    private func hasAvailableCapacity(mutating: Bool) -> Bool {
        active < limits.maxConcurrent
            && (!mutating || activeMutating < limits.maxConcurrentMutating)
    }

    private func claimCapacity(mutating: Bool) {
        active += 1
        if mutating { activeMutating += 1 }
    }

    private static func isMutating(_ tools: CodingTools) -> Bool {
        tools.contains(.write) || tools.contains(.edit) || tools.contains(.bash)
    }
}

/// One admitted background launch. Waiting is cancellable independently of
/// the foreground tool task; cancelling while queued removes it from the gate.
final class SubagentCapacityReservation: @unchecked Sendable {
    fileprivate typealias Outcome = Result<SubagentPermit, any Error>

    private let lock = NSLock()
    private let id: UUID
    private weak var limiter: SubagentLimiter?
    private var outcome: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?
    private var abandoned = false
    private var permitClaimed = false

    fileprivate init(id: UUID, limiter: SubagentLimiter) {
        self.id = id
        self.limiter = limiter
    }

    var isWaitingForCapacity: Bool {
        lock.withLock { outcome == nil }
    }

    /// Capacity context for spawn-result rendering. Position is nil once the
    /// launch holds a runner slot.
    var queueStatus: (position: Int?, queuedCount: Int, maxConcurrent: Int)? {
        limiter?.queueStatus(of: id)
    }

    func wait(cancellation: CancellationHandle) async throws -> SubagentPermit {
        let registration = cancellation.onCancel { [weak self] _ in
            self?.cancel()
        }
        defer { registration.cancel() }
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<Outcome, Never>) in
            let ready = lock.withLock { () -> Outcome? in
                if let outcome { return outcome }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        let permit = try result.get()
        let accepted = lock.withLock { () -> Bool in
            guard !abandoned, !permitClaimed else { return false }
            permitClaimed = true
            return true
        }
        guard accepted else {
            permit.release()
            throw SubagentExecutionCapacityError.cancelled
        }
        do {
            try cancellation.throwIfCancelled()
            return permit
        } catch {
            permit.release()
            throw error
        }
    }

    func cancel() {
        abandon()
    }

    /// Cancel a queued launch that will never call `wait`. This is also safe
    /// after an immediate grant: an unclaimed permit is released exactly once.
    /// A permit already claimed by a running child remains owned by that child.
    func abandon() {
        let unusedPermit = lock.withLock { () -> SubagentPermit? in
            guard !abandoned else { return nil }
            abandoned = true
            guard !permitClaimed,
                  case .success(let permit)? = outcome else { return nil }
            outcome = .failure(SubagentExecutionCapacityError.cancelled)
            return permit
        }
        unusedPermit?.release()
        limiter?.cancelQueued(id: id)
    }

    fileprivate func resolve(_ result: Outcome) {
        let resolution = lock.withLock {
            () -> (CheckedContinuation<Outcome, Never>?, Outcome, SubagentPermit?) in
            guard outcome == nil else {
                let unused: SubagentPermit?
                if case .success(let permit) = result { unused = permit }
                else { unused = nil }
                return (nil, outcome!, unused)
            }
            let settled: Outcome
            let unused: SubagentPermit?
            if abandoned {
                settled = .failure(SubagentExecutionCapacityError.cancelled)
                if case .success(let permit) = result { unused = permit }
                else { unused = nil }
            } else {
                settled = result
                unused = nil
            }
            outcome = settled
            let pending = waiter
            waiter = nil
            return (pending, settled, unused)
        }
        resolution.2?.release()
        resolution.0?.resume(returning: resolution.1)
    }
}

final class SubagentPermit: @unchecked Sendable {
    private let lock = NSLock()
    private weak var limiter: SubagentLimiter?
    private let mutating: Bool
    private var released = false

    fileprivate init(limiter: SubagentLimiter, mutating: Bool) {
        self.limiter = limiter
        self.mutating = mutating
    }

    func release() {
        let target = lock.withLock { () -> SubagentLimiter? in
            guard !released else { return nil }
            released = true
            return limiter
        }
        target?.release(mutating: mutating)
    }

    deinit {
        release()
    }
}

private enum SubagentExecutionCapacityError: Error, LocalizedError, Sendable {
    case cancelled

    var errorDescription: String? {
        "agent: queued subagent was cancelled before runner capacity became available"
    }
}

enum SubagentLimitError: Error, LocalizedError, Sendable {
    case concurrent(limit: Int)
    case mutatingConcurrent(limit: Int)
    case total(limit: Int)

    var errorDescription: String? {
        switch self {
        case .concurrent(let limit):
            return "agent: concurrent subagent limit reached (max \(limit)); wait for a running child to finish"
        case .mutatingConcurrent(let limit):
            return "agent: concurrent mutating subagent limit reached (max \(limit)); writing children run serially by default"
        case .total(let limit):
            return "agent: subagent launch budget exhausted for this parent session (max \(limit))"
        }
    }

    var failureKind: String {
        switch self {
        case .concurrent: return "concurrency_limit"
        case .mutatingConcurrent: return "mutating_concurrency_limit"
        case .total: return "total_limit"
        }
    }
}
