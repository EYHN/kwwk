import Foundation
import KWWKAI

/// Creates in-memory host context for SDK-generated user messages. Hosts must
/// capture context here, before asynchronous child launch or queue admission.
public typealias UserMessageFactory = @Sendable (String) -> UserMessage

/// Awaited after a new user message is committed, before compaction or the next
/// provider invocation. Restored transcript messages do not invoke this hook.
public typealias UserMessageConsumedHook = @Sendable (String?, UserMessage) async -> Void

/// Decorates each original tool once at Agent construction. Children inherit
/// the wrapper but pass their own session ID. Copy the tool and replace only
/// `execute` to preserve SDK capabilities. Execute scopes must be established
/// explicitly: parallel SDK tools run in detached tasks.
public typealias ToolExecutionWrapper = @Sendable (String?, AgentTool) -> AgentTool

/// Opaque process-local scope captured by finite background task registration.
/// Hosts establish it explicitly inside tool wrappers. No context is inferred
/// from task text, thread identity, restored history or the current agent.
public enum HostMessageContext {
    @TaskLocal public static var id: String?
}
