import KWWKAI
import Testing
@testable import KWWKAgent

@Suite("Compaction file facts")
struct CompactionFactsExtractorTests {
    @Test("records file operations only after a successful tool result")
    func requiresSuccessfulResult() {
        let missing = call(id: "missing", name: "write", path: "/tmp/missing.swift")
        let failed = call(id: "failed", name: "edit", path: "/tmp/failed.swift")
        let succeeded = call(id: "succeeded", name: "read", path: "/tmp/read.swift")
        let messages: [Message] = [
            assistant(calls: [missing, failed, succeeded]),
            .toolResult(ToolResultMessage(
                toolCallId: failed.id,
                toolName: failed.name,
                content: [.text(TextContent(text: "edit failed"))],
                isError: true
            )),
            .toolResult(ToolResultMessage(
                toolCallId: succeeded.id,
                toolName: succeeded.name,
                content: [.text(TextContent(text: "read complete"))]
            )),
        ]

        let facts = CompactionFactsExtractor.extract(from: messages)

        #expect(facts.readPaths == ["/tmp/read.swift"])
        #expect(facts.modifiedPaths.isEmpty)
    }

    @Test("carry-forward facts are capped by total count and prefer new facts")
    func capsCarriedFactCount() throws {
        let previousLines = (0..<400).map {
            #"<read path="/old/\#($0).swift" />"#
        }.joined(separator: "\n")
        let previousSummary = """
        <file-operations>
        \(previousLines)
        </file-operations>
        """
        let currentPath = "/current/important.swift"
        let facts = CompactionFileFacts(modifiedPaths: [currentPath])

        let rendered = try #require(CompactionFactsExtractor.render(
            facts,
            carryingForwardFrom: previousSummary
        ))
        let lines = factLines(in: rendered)

        #expect(lines.count == CompactionFactsExtractor.maximumRenderedFacts)
        #expect(rendered.contains(#"<modified path="/current/important.swift" />"#))
        #expect(rendered.utf8.count <= CompactionFactsExtractor.maximumRenderedBytes)
    }

    @Test("carry-forward facts are capped by rendered UTF-8 bytes")
    func capsCarriedFactBytes() throws {
        let longSegment = String(repeating: "x", count: 1_000)
        let previousLines = (0..<100).map {
            #"<read path="/old/\#($0)-\#(longSegment).swift" />"#
        }.joined(separator: "\n")
        let previousSummary = """
        <file-operations>
        \(previousLines)
        </file-operations>
        """

        let rendered = try #require(CompactionFactsExtractor.render(
            CompactionFileFacts(),
            carryingForwardFrom: previousSummary
        ))

        #expect(rendered.utf8.count <= CompactionFactsExtractor.maximumRenderedBytes)
        #expect(factLines(in: rendered).count < 100)
    }

    @Test("callers can tighten the fact budget for a small recovery target")
    func supportsTargetScaledByteLimit() throws {
        let facts = CompactionFileFacts(readPaths: Set((0..<100).map {
            "/workspace/very-long-path-\($0)-" + String(repeating: "x", count: 40)
        }))

        let rendered = try #require(CompactionFactsExtractor.render(
            facts,
            carryingForwardFrom: nil,
            maximumBytes: 512
        ))

        #expect(rendered.utf8.count <= 512)
        #expect(factLines(in: rendered).count < 100)
    }

    private func call(id: String, name: String, path: String) -> ToolCall {
        ToolCall(
            id: id,
            name: name,
            arguments: .object(["path": .string(path)])
        )
    }

    private func assistant(calls: [ToolCall]) -> Message {
        .assistant(AssistantMessage(
            content: calls.map(AssistantBlock.toolCall),
            api: "faux",
            provider: "faux",
            model: "faux",
            stopReason: .toolUse
        ))
    }

    private func factLines(in rendered: String) -> [Substring] {
        rendered.split(separator: "\n").filter {
            $0.hasPrefix("<read path=\"") || $0.hasPrefix("<modified path=\"")
        }
    }
}
