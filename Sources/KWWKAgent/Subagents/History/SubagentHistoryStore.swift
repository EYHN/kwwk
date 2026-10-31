import Foundation
import KWWKAI
import NIOConcurrencyHelpers

/// Process-local registry for live and parked child transcripts.
///
/// The registry intentionally stores messages instead of file paths. The
/// paired `agent_history` tool can therefore expose only children launched by
/// this parent catalog and cannot read arbitrary files.
public final class SubagentHistoryStore: Sendable {
    private enum Scope: Hashable {
        case anonymous
        case session(String)

        init(_ sessionId: String?) {
            if let sessionId { self = .session(sessionId) }
            else { self = .anonymous }
        }
    }

    private struct Entry {
        var parentSessionId: String?
        var snapshot: SubagentHistorySnapshot
        var awaitingTaskId: Bool
        var modelOverride: String?
        var thinkingLevelOverride: ThinkingLevel?
        var live: SubagentLiveChild?
        var pendingSteers: [String] = []
        /// The run that owns the entry right now. Calls carrying another
        /// run's token (a stale run still settling) are ignored.
        var runToken: UUID?
    }

    /// Whether a call from the run holding `token` may change `entry`. A nil
    /// token is an unconditional caller (tests, SDK hosts).
    private static func owns(_ token: UUID?, _ entry: Entry) -> Bool {
        token == nil || entry.runToken == token
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var childSessionIds: [String] = []
        var evictedEntriesByScope: [Scope: Int] = [:]
        var reservedAgentIds: [Scope: Set<String>] = [:]
        var agentIdCounters: [Scope: [String: Int]] = [:]
    }

    private let state = NIOLockedValueBox(State())
    private let maxTerminalEntries: Int
    private let maxEstimatedBytes: Int

    public init(
        maxTerminalEntries: Int = 32,
        maxEstimatedBytes: Int = 16 * 1_024 * 1_024
    ) {
        self.maxTerminalEntries = max(1, maxTerminalEntries)
        self.maxEstimatedBytes = max(64 * 1_024, maxEstimatedBytes)
    }

    public func retention(parentSessionId: String? = nil) -> SubagentHistoryRetention {
        state.withLockedValue { state in
            SubagentHistoryRetention(
                processLocal: true,
                maxTerminalEntries: maxTerminalEntries,
                maxEstimatedBytes: maxEstimatedBytes,
                evictedEntries: state.evictedEntriesByScope[Scope(parentSessionId), default: 0]
            )
        }
    }

    public func list(parentSessionId: String? = nil) -> [SubagentHistorySnapshot] {
        state.withLockedValue { state in
            state.childSessionIds.compactMap { childSessionId in
                guard let entry = state.entries[childSessionId],
                      entry.parentSessionId == parentSessionId else {
                    return nil
                }
                return entry.snapshot
            }
        }
    }

    public func snapshot(
        childSessionId: String,
        parentSessionId: String? = nil
    ) -> SubagentHistorySnapshot? {
        state.withLockedValue { state in
            guard let entry = state.entries[childSessionId],
                  entry.parentSessionId == parentSessionId else {
                return nil
            }
            return entry.snapshot
        }
    }

    /// The child with this `agent_id` (case-insensitive).
    public func snapshot(
        agentId: String,
        parentSessionId: String? = nil
    ) -> SubagentHistorySnapshot? {
        state.withLockedValue { entryId(in: $0, agentId: agentId, parentSessionId: parentSessionId) }
            .flatMap { id in state.withLockedValue { $0.entries[id]?.snapshot } }
    }

    /// The child any of whose runs has this background task id.
    public func snapshot(
        taskId: String,
        parentSessionId: String? = nil
    ) -> SubagentHistorySnapshot? {
        state.withLockedValue { state in
            // The lazy transform escapes, so it cannot capture the inout state.
            let entries = state.entries
            return state.childSessionIds.reversed().lazy.compactMap { entries[$0] }.first {
                $0.parentSessionId == parentSessionId
                    && ($0.snapshot.taskId == taskId
                        || $0.snapshot.runs.contains { $0.taskId == taskId })
            }?.snapshot
        }
    }

    /// Hand out the child's `agent_id` before it launches. A requested name
    /// must be unused in this parent session; otherwise the id is
    /// `<type>-<n>`.
    func reserveAgentId(
        parentSessionId: String?,
        requested: String?,
        subagentType: String
    ) throws -> String {
        try state.withLockedValue { state in
            let scope = Scope(parentSessionId)
            var reserved = state.reservedAgentIds[scope, default: []]
            let taken = Set(state.entries.values.compactMap { entry -> String? in
                guard Scope(entry.parentSessionId) == scope else { return nil }
                return entry.snapshot.agentId.lowercased()
            }).union(reserved)
            let agentId: String
            if let requested {
                guard !taken.contains(requested.lowercased()) else {
                    throw CodingToolError.invalidArgument(
                        "agent: a subagent named '\(requested)' already exists; pick another `name` or continue it with agent_send"
                    )
                }
                agentId = requested
            } else {
                var counters = state.agentIdCounters[scope, default: [:]]
                var next = counters[subagentType, default: 0]
                var candidate: String
                repeat {
                    next += 1
                    candidate = "\(subagentType)-\(next)"
                } while taken.contains(candidate.lowercased())
                counters[subagentType] = next
                state.agentIdCounters[scope] = counters
                agentId = candidate
            }
            reserved.insert(agentId.lowercased())
            state.reservedAgentIds[scope] = reserved
            return agentId
        }
    }

    /// Give back a reserved `agent_id` whose launch failed before it began.
    func releaseAgentId(_ agentId: String, parentSessionId: String?) {
        state.withLockedValue { state in
            let scope = Scope(parentSessionId)
            state.reservedAgentIds[scope]?.remove(agentId.lowercased())
        }
    }

    func begin(
        childSessionId: String,
        parentSessionId: String?,
        agentId: String? = nil,
        subagentType: String,
        description: String = "",
        prompt: String,
        model: String,
        modelOverride: String? = nil,
        thinkingLevelOverride: ThinkingLevel? = nil,
        status: SubagentHistoryStatus = .running,
        awaitingTaskId: Bool? = nil,
        runToken: UUID? = nil,
        firstMessageIndex: Int? = nil
    ) {
        let now = Timestamp.now()
        state.withLockedValue { state in
            if var existing = state.entries[childSessionId] {
                // A run that already finished, or a stale one, must not take
                // the entry back from the run that owns it now.
                if let runToken, let current = existing.runToken, current != runToken { return }
                existing.snapshot.model = model
                existing.snapshot.status = status
                existing.snapshot.errorMessage = nil
                existing.snapshot.updatedAt = now
                if runToken != nil { existing.runToken = runToken }
                if !existing.snapshot.runs.isEmpty {
                    let last = existing.snapshot.runs.count - 1
                    existing.snapshot.runs[last].status = status
                    if let firstMessageIndex {
                        existing.snapshot.runs[last].firstMessageIndex = firstMessageIndex
                    }
                }
                if let awaitingTaskId {
                    existing.awaitingTaskId = awaitingTaskId
                }
                state.entries[childSessionId] = existing
                return
            }
            let agentId = agentId ?? childSessionId
            let scope = Scope(parentSessionId)
            state.reservedAgentIds[scope]?.remove(agentId.lowercased())
            state.entries[childSessionId] = Entry(
                parentSessionId: parentSessionId,
                snapshot: SubagentHistorySnapshot(
                    childSessionId: childSessionId,
                    agentId: agentId,
                    subagentType: subagentType,
                    description: description,
                    prompt: prompt,
                    model: model,
                    status: status,
                    runs: [SubagentHistoryRun(
                        trigger: .prompt,
                        firstMessageIndex: 0,
                        status: status,
                        startedAt: now
                    )],
                    startedAt: now,
                    updatedAt: now
                ),
                awaitingTaskId: awaitingTaskId ?? false,
                modelOverride: modelOverride,
                thinkingLevelOverride: thinkingLevelOverride,
                runToken: runToken
            )
            state.childSessionIds.append(childSessionId)
        }
    }

    func attachTask(_ taskId: String, childSessionId: String) {
        state.withLockedValue { state in
            guard var entry = state.entries[childSessionId] else { return }
            entry.snapshot.taskId = taskId
            if !entry.snapshot.runs.isEmpty {
                entry.snapshot.runs[entry.snapshot.runs.count - 1].taskId = taskId
            }
            entry.awaitingTaskId = false
            entry.snapshot.updatedAt = Timestamp.now()
            state.entries[childSessionId] = entry
            if !entry.snapshot.status.isActive {
                pruneTerminalEntries(in: &state, parentSessionId: entry.parentSessionId)
            }
        }
    }

    func update(
        childSessionId: String,
        runToken: UUID? = nil,
        messages: [Message],
        liveMessage: Message?,
        currentActivity: String?
    ) {
        state.withLockedValue { state in
            guard var entry = state.entries[childSessionId], Self.owns(runToken, entry) else { return }
            entry.snapshot.messages = messages
            entry.snapshot.liveMessage = liveMessage
            if entry.snapshot.status.isActive, let currentActivity {
                entry.snapshot.currentActivity = currentActivity
            } else if !entry.snapshot.status.isActive {
                entry.snapshot.liveMessage = nil
                entry.snapshot.currentActivity = nil
            }
            entry.snapshot.updatedAt = Timestamp.now()
            state.entries[childSessionId] = entry
        }
    }

    /// End the run that holds `runToken`. A finish from any other run (a
    /// second report of a run that already finished, or a stale run) is
    /// ignored. Follow-ups still queued are kept for the next resume.
    func finish(
        childSessionId: String,
        runToken: UUID? = nil,
        status: SubagentHistoryStatus,
        messages: [Message]? = nil,
        errorMessage: String? = nil
    ) {
        state.withLockedValue { state in
            guard var entry = state.entries[childSessionId], Self.owns(runToken, entry) else { return }
            let now = Timestamp.now()
            if let messages {
                entry.snapshot.messages = messages
            }
            entry.snapshot.liveMessage = nil
            entry.snapshot.currentActivity = nil
            entry.snapshot.status = status
            entry.snapshot.errorMessage = errorMessage
            entry.snapshot.updatedAt = now
            if !entry.snapshot.runs.isEmpty {
                let last = entry.snapshot.runs.count - 1
                entry.snapshot.runs[last].status = status
                entry.snapshot.runs[last].endedAt = now
            }
            entry.live = nil
            entry.runToken = nil
            state.entries[childSessionId] = entry
            pruneTerminalEntries(in: &state, parentSessionId: entry.parentSessionId)
        }
    }

    /// Route a follow-up to the child named `agentId`: into its run when it is
    /// running or waiting for capacity, or as a claim to resume it when it
    /// stopped. The claim marks the child queued with a new run so a second
    /// follow-up racing this one is delivered into the resumed run instead of
    /// starting another.
    func claimFollowUp(
        agentId: String,
        parentSessionId: String?,
        message: String
    ) -> SubagentFollowUpClaim {
        state.withLockedValue { state in
            guard let id = entryId(in: state, agentId: agentId, parentSessionId: parentSessionId),
                  var entry = state.entries[id] else {
                let scope = Scope(parentSessionId)
                let known = state.childSessionIds.compactMap { childSessionId -> String? in
                    guard let entry = state.entries[childSessionId],
                          Scope(entry.parentSessionId) == scope else { return nil }
                    return entry.snapshot.agentId
                }
                return .notFound(known: known)
            }
            if let live = entry.live {
                live.deliver(message)
                return .delivered(entry.snapshot)
            }
            switch entry.snapshot.status {
            case .queued:
                // Waiting for capacity, or a claimed resume that has not
                // begun: the run delivers these when it attaches.
                entry.pendingSteers.append(message)
                state.entries[id] = entry
                return .delivered(entry.snapshot)
            case .running:
                // Starting up or settling after its last step: no agent to
                // steer, but the run is not over either.
                return .busy
            case .completed, .incomplete, .failed, .aborted:
                break
            }
            let previousStatus = entry.snapshot.status
            let carried = entry.pendingSteers
            let now = Timestamp.now()
            entry.pendingSteers.removeAll()
            entry.runToken = nil
            entry.snapshot.taskId = nil
            entry.snapshot.status = .queued
            entry.snapshot.errorMessage = nil
            entry.snapshot.updatedAt = now
            entry.snapshot.runs.append(SubagentHistoryRun(
                trigger: .send,
                firstMessageIndex: entry.snapshot.messages.count,
                status: .queued,
                startedAt: now
            ))
            state.entries[id] = entry
            return .resume(SubagentResumeTicket(
                childSessionId: id,
                agentId: entry.snapshot.agentId,
                subagentType: entry.snapshot.subagentType,
                description: entry.snapshot.description,
                modelOverride: entry.modelOverride,
                thinkingLevelOverride: entry.thinkingLevelOverride,
                messages: entry.snapshot.messages,
                previousStatus: previousStatus,
                carriedMessages: carried,
                runNumber: entry.snapshot.runs.count
            ))
        }
    }

    /// Undo a resume claim whose run never launched.
    func abandonFollowUp(_ ticket: SubagentResumeTicket, errorMessage: String) {
        state.withLockedValue { state in
            guard var entry = state.entries[ticket.childSessionId],
                  entry.snapshot.status == .queued,
                  entry.snapshot.runs.last?.trigger == .send else { return }
            entry.snapshot.runs.removeLast()
            entry.snapshot.status = ticket.previousStatus
            entry.snapshot.errorMessage = errorMessage
            entry.snapshot.updatedAt = Timestamp.now()
            entry.snapshot.taskId = entry.snapshot.runs.last?.taskId
            // Follow-ups acknowledged meanwhile stay queued for the next
            // resume, behind the ones this claim carried.
            entry.pendingSteers = ticket.carriedMessages + entry.pendingSteers
            state.entries[ticket.childSessionId] = entry
        }
    }

    /// Register the child's live agent for the duration of a run. Follow-ups
    /// that arrived while it was queued are delivered now.
    func attachLive(childSessionId: String, runToken: UUID? = nil, live: SubagentLiveChild) {
        state.withLockedValue { state in
            guard var entry = state.entries[childSessionId], Self.owns(runToken, entry) else { return }
            for message in entry.pendingSteers {
                live.deliver(message)
            }
            entry.pendingSteers.removeAll()
            entry.live = live
            state.entries[childSessionId] = entry
        }
    }

    /// Detach the live agent at the end of a run, unless a follow-up is still
    /// waiting to be read: then it stays attached and the caller continues the
    /// run. Holding the store lock makes this atomic with `claimFollowUp`, so
    /// no follow-up can land between the check and the detach.
    func detachLiveIfSettled(childSessionId: String, runToken: UUID? = nil) -> Bool {
        state.withLockedValue { state in
            guard var entry = state.entries[childSessionId],
                  Self.owns(runToken, entry),
                  let live = entry.live else { return true }
            for message in entry.pendingSteers {
                live.deliver(message)
            }
            entry.pendingSteers.removeAll()
            guard !live.hasQueuedSteering else {
                state.entries[childSessionId] = entry
                return false
            }
            entry.live = nil
            state.entries[childSessionId] = entry
            return true
        }
    }

    private func entryId(in state: State, agentId: String, parentSessionId: String?) -> String? {
        let wanted = agentId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return state.childSessionIds.last { childSessionId in
            guard let entry = state.entries[childSessionId] else { return false }
            return entry.parentSessionId == parentSessionId
                && entry.snapshot.agentId.lowercased() == wanted
        }
    }

    private func pruneTerminalEntries(in state: inout State, parentSessionId: String?) {
        let scope = Scope(parentSessionId)
        var terminalIds = state.childSessionIds.filter { childSessionId in
            guard let entry = state.entries[childSessionId],
                  Scope(entry.parentSessionId) == scope,
                  !entry.awaitingTaskId else { return false }
            return !entry.snapshot.status.isActive
        }
        // Least recently active first: a child resumed a moment ago is worth
        // more than one that finished long before it.
        let order = Dictionary(
            state.childSessionIds.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        terminalIds.sort { lhs, rhs in
            let left = state.entries[lhs]?.snapshot.updatedAt ?? 0
            let right = state.entries[rhs]?.snapshot.updatedAt ?? 0
            if left != right { return left < right }
            return order[lhs, default: 0] < order[rhs, default: 0]
        }
        func estimatedBytes() -> Int {
            terminalIds.reduce(0) { total, childSessionId in
                guard let snapshot = state.entries[childSessionId]?.snapshot else { return total }
                let encoded = (try? JSONEncoder().encode(snapshot.messages))?.count ?? 0
                return total + encoded + snapshot.prompt.utf8.count
            }
        }

        var bytes = estimatedBytes()
        while terminalIds.count > maxTerminalEntries
            || (bytes > maxEstimatedBytes && terminalIds.count > 1) {
            let removed = terminalIds.removeFirst()
            guard let snapshot = state.entries.removeValue(forKey: removed)?.snapshot else { continue }
            state.childSessionIds.removeAll { $0 == removed }
            state.evictedEntriesByScope[scope, default: 0] += 1
            bytes -= ((try? JSONEncoder().encode(snapshot.messages))?.count ?? 0)
                + snapshot.prompt.utf8.count
        }
    }
}
