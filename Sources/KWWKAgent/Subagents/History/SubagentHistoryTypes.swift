import Foundation
import KWWKAI

public enum SubagentHistoryStatus: String, Codable, Sendable, Hashable {
    case queued
    case running
    case completed
    case incomplete
    case failed
    case aborted

    var isActive: Bool { self == .queued || self == .running }
}

/// What started one run of a child: the original `agent` call, or an
/// `agent_send` that resumed it after it stopped.
public enum SubagentRunTrigger: String, Codable, Sendable, Hashable {
    case prompt
    case send = "agent_send"
}

/// One run of a child. A child that is resumed has several; each run has its
/// own background task id (nil for a run that finished in the foreground).
public struct SubagentHistoryRun: Sendable, Hashable {
    public var taskId: String?
    public var trigger: SubagentRunTrigger
    /// Index into the child's messages of the prompt that started this run.
    public var firstMessageIndex: Int
    public var status: SubagentHistoryStatus
    public var startedAt: Int64
    public var endedAt: Int64?

    public init(
        taskId: String? = nil,
        trigger: SubagentRunTrigger,
        firstMessageIndex: Int,
        status: SubagentHistoryStatus,
        startedAt: Int64,
        endedAt: Int64? = nil
    ) {
        self.taskId = taskId
        self.trigger = trigger
        self.firstMessageIndex = firstMessageIndex
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// Read-only snapshot of one child retained by its parent agent.
///
/// A store belongs to one coding-agent tool catalog. Entries are additionally
/// scoped by parent session id so SDK callers may safely share a store without
/// making one session's child transcript visible to another.
public struct SubagentHistorySnapshot: Sendable, Hashable {
    public var childSessionId: String
    /// Stable, model-facing name of the child across all of its runs.
    public var agentId: String
    /// Background task id of the latest run, if it has one.
    public var taskId: String?
    public var subagentType: String
    public var description: String
    public var prompt: String
    public var model: String?
    public var status: SubagentHistoryStatus
    public var messages: [Message]
    public var liveMessage: Message?
    public var currentActivity: String?
    public var errorMessage: String?
    public var runs: [SubagentHistoryRun]
    public var startedAt: Int64
    public var updatedAt: Int64

    public init(
        childSessionId: String,
        agentId: String? = nil,
        taskId: String? = nil,
        subagentType: String,
        description: String = "",
        prompt: String,
        model: String? = nil,
        status: SubagentHistoryStatus,
        messages: [Message] = [],
        liveMessage: Message? = nil,
        currentActivity: String? = nil,
        errorMessage: String? = nil,
        runs: [SubagentHistoryRun] = [],
        startedAt: Int64,
        updatedAt: Int64
    ) {
        self.childSessionId = childSessionId
        self.agentId = agentId ?? childSessionId
        self.taskId = taskId
        self.subagentType = subagentType
        self.description = description
        self.prompt = prompt
        self.model = model
        self.status = status
        self.messages = messages
        self.liveMessage = liveMessage
        self.currentActivity = currentActivity
        self.errorMessage = errorMessage
        self.runs = runs
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

extension SubagentHistorySnapshot {
    /// The snapshot without transcript tool declarations, with run start
    /// indices remapped to the remaining messages.
    func withoutToolDeclarations() -> SubagentHistorySnapshot {
        guard TranscriptTools.hasSystemMessages(messages) else { return self }
        var visibleIndex: [Int] = []
        visibleIndex.reserveCapacity(messages.count + 1)
        var count = 0
        for message in messages {
            visibleIndex.append(count)
            if message.role != .system { count += 1 }
        }
        visibleIndex.append(count)
        var copy = self
        copy.messages = TranscriptTools.withoutSystemMessages(messages)
        copy.runs = runs.map { run in
            var run = run
            run.firstMessageIndex = visibleIndex[min(max(0, run.firstMessageIndex), visibleIndex.count - 1)]
            return run
        }
        return copy
    }
}

public struct SubagentHistoryRetention: Sendable, Hashable {
    public var processLocal: Bool
    public var maxTerminalEntries: Int
    public var maxEstimatedBytes: Int
    public var evictedEntries: Int
}

/// A child that is inside a run right now. Follow-ups reach it as steering
/// messages, read at its next step.
final class SubagentLiveChild: @unchecked Sendable {
    let agent: Agent

    init(agent: Agent) {
        self.agent = agent
    }

    func deliver(_ message: String) {
        agent.steer(UserMessage(text: subagentSteerMessageText(message)))
    }

    var hasQueuedSteering: Bool { agent.queuedSteeringCount() > 0 }
}

/// Everything a resumed run needs from the child it continues.
struct SubagentResumeTicket: Sendable {
    var childSessionId: String
    var agentId: String
    var subagentType: String
    var description: String
    var modelOverride: String?
    var thinkingLevelOverride: ThinkingLevel?
    var messages: [Message]
    var previousStatus: SubagentHistoryStatus
    /// Follow-ups that were queued for a run that never read them; they
    /// belong at the front of the resumed run's prompt.
    var carriedMessages: [String]
    /// The number of the run the resume starts, 1-based.
    var runNumber: Int
}

enum SubagentFollowUpClaim: Sendable {
    /// The child is running (or waiting for capacity) and will read the
    /// message at its next step.
    case delivered(SubagentHistorySnapshot)
    /// The child had stopped; the caller must launch a resumed run.
    case resume(SubagentResumeTicket)
    /// The child is between states inside a run (starting, or settling after
    /// its last step) and can take the message in a moment. Retry.
    case busy
    case notFound(known: [String])
}
