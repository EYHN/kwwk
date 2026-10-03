# Process-local host context

Hosts can associate a newly submitted `UserMessage` with an opaque
`hostContextID`. The SDK does not interpret that ID. It belongs in a host's
process-local lookup table, never in prompt text or provider metadata.

The ID participates in in-memory message identity but is excluded from
`Codable` and reflection. A saved or decoded transcript has no host context,
even when input JSON supplies a `hostContextID` key. Provider message builders
continue to use the existing visible message fields.

`AgentOptions.userMessageConsumed` (also mutable on `Agent`) is awaited after
a new user message is committed and before compaction or the next provider
request. It receives the concrete agent session ID and the accepted message.
Blocked submissions and restored history do not trigger it. A host should
clear its session context when it consumes an unrecognized ID, and clear or
restore an explicitly proven cause at fresh run boundaries. The SDK does not
infer causality from old messages, role labels or the last notification.

`userMessageFactory` supplies process-local context for SDK-generated prompts,
steering and follow-ups. Subagent initial messages are captured before detached
launch; `agent_send` carries context with each queued delivery. Children inherit
the factory and consumption hook. A running child's current invocation retains
its captured context until the new message is actually consumed.

`wrapToolExecution` decorates original tools once at agent construction and is
inherited by children with their own session IDs. Copy each tool and replace
only its `execute` closure to preserve SDK capability metadata. Hosts must
establish any execution scope explicitly inside the wrapper: parallel tools run
in detached tasks. The wrapper should snapshot the concrete session's context
at execution entry, rather than borrow a parent's latest context. Changing the
property later affects future children; wrap existing tools separately.

For finite background work, hosts may establish
`HostMessageContext.$id.withValue(capturedID)` inside their tool wrapper.
`BackgroundTaskManager.spawn` and `adopt` capture that ID when the task is
registered. Completion and stall messages retain the captured ID independently
of later messages. They do not infer context at completion, and the ID is
excluded from snapshots, rendered notifications and reflection. Unscoped work
has no ID. This state is intentionally not persisted across process restarts.

All hooks default to nil. Existing callers retain their existing behavior.
These hooks carry host evidence; they do not authenticate users or authorize
billing. Hosts remain responsible for validating their causal receipts and
capturing one immutable context for every provider invocation.
