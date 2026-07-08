import Foundation
import KWWKAI
import KWWKAgent

/// Render a stored `[Message]` transcript into display lines for the retained
/// frame. Used by `/resume` and `/rewind` to repaint history.
///
/// Replays the messages through a fresh `TranscriptRenderer` as synthetic
/// agent events, so the recap is rendered by the exact same code path as the
/// live stream: user bars, markdown-committed assistant prose, `●` tool
/// blocks with result previews, folded read runs — and, critically, one
/// physical line per array element (embedded newlines are split), which the
/// raw-mode terminal requires. Thinking blocks don't replay (they only ever
/// render from live deltas); tool `uiDisplay` summaries aren't persisted, so
/// replayed tool results show the default content preview.
@MainActor
enum TranscriptSnapshot {
    static func render(_ messages: [Message], width: Int) -> [String] {
        let renderer = TranscriptRenderer()
        renderer.displayWidth = width
        for message in messages {
            switch message {
            case .user:
                renderer.apply(.messageStart(message: message))
            case .assistant(let a):
                renderer.apply(.messageStart(message: message))
                renderer.apply(.messageEnd(message: message))
                for block in a.content {
                    if case .toolCall(let call) = block {
                        renderer.apply(.toolExecutionStart(
                            toolCallId: call.id, toolName: call.name, args: call.arguments))
                    }
                }
            case .toolResult(let tr):
                renderer.apply(.toolExecutionEnd(
                    toolCallId: tr.toolCallId,
                    toolName: tr.toolName,
                    result: AgentToolResult(content: tr.content, details: tr.details),
                    isError: tr.isError
                ))
            }
        }
        // Seal any trailing read-only fold run into its count-headed tree block.
        // A trailing tool call with no persisted result (the process died
        // mid-execution) stays in the renderer's live zone and is deliberately
        // dropped from the recap — a frozen "calling…" row in scrollback reads
        // worse than the call simply not appearing, and the resumed model
        // context has no result for it either.
        renderer.sealFoldRun()
        return renderer.drainCommits()
    }
}
