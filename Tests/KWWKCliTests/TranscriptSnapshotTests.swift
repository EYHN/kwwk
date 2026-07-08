import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

/// TranscriptSnapshot replays a stored transcript through TranscriptRenderer,
/// so a `/resume` / `/rewind` recap must look exactly like the live stream
/// did. These tests pin the two properties the repaint path depends on:
/// every element is ONE physical line (the TUI writes each element with its
/// own `\r\n`; an embedded bare `\n` staircases in raw mode), and the recap
/// carries the same user-bar / `●` tool blocks as live rendering.
@Suite("TranscriptSnapshot replay")
@MainActor
struct TranscriptSnapshotTests {

    private func assistant(_ blocks: [AssistantBlock]) -> Message {
        .assistant(AssistantMessage(
            content: blocks,
            api: "faux",
            provider: "faux",
            model: "faux"
        ))
    }

    @Test("multi-line assistant text splits into one element per physical line")
    func noEmbeddedNewlines() {
        let messages: [Message] = [
            .user(UserMessage(text: "first\nprompt")),
            assistant([.text(TextContent(text: "line one\n\n```sh\nswift test\n```\nline two"))]),
        ]
        let lines = TranscriptSnapshot.render(messages, width: 80)
        #expect(!lines.isEmpty)
        #expect(lines.allSatisfy { !$0.contains("\n") })
        #expect(lines.contains { $0.contains("swift test") })
    }

    @Test("recap matches the live renderer's messageStart/messageEnd output")
    func matchesLiveRenderer() {
        let user = Message.user(UserMessage(text: "do the thing"))
        let reply = assistant([.text(TextContent(text: "done\nwith detail"))])

        let live = TranscriptRenderer()
        live.displayWidth = 80
        live.apply(.messageStart(message: user))
        live.apply(.messageStart(message: reply))
        live.apply(.messageEnd(message: reply))
        let liveLines = live.drainCommits()

        let recap = TranscriptSnapshot.render([user, reply], width: 80)
        #expect(recap == liveLines)
    }

    @Test("tool calls replay as ● blocks with their result previews")
    func toolBlocksReplay() {
        let call = ToolCall(id: "t1", name: "bash", arguments: .object(["command": .string("ls")]))
        let messages: [Message] = [
            .user(UserMessage(text: "run ls")),
            assistant([.toolCall(call)]),
            .toolResult(ToolResultMessage(
                toolCallId: "t1",
                toolName: "bash",
                content: [.text(TextContent(text: "a.txt\nb.txt"))]
            )),
        ]
        let lines = TranscriptSnapshot.render(messages, width: 80)
        #expect(lines.contains { $0.contains("● bash") })
        #expect(lines.contains { $0.contains("a.txt") })
        #expect(lines.allSatisfy { !$0.contains("\n") })
    }
}
