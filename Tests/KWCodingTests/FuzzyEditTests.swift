import Foundation
import Testing
@testable import KWAI
@testable import KWAgent
@testable import KWCoding

@Suite("Fuzzy edit matching")
struct FuzzyEditTests {
    @Test("normalizeForFuzzyMatch collapses smart quotes, dashes, and spaces")
    func normalizer() {
        let input = "“hello” — world\u{00A0}trailing   \nnext\tline"
        let expected = "\"hello\" - world trailing\nnext\tline"
        #expect(EditDiff.normalizeForFuzzyMatch(input) == expected)
    }

    @Test("fuzzy matching lets edits match smart-quote text against ASCII")
    func fuzzyMatch() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("quotes.txt")
        try write("The price is \u{201C}free\u{201D} today.", to: file)

        let tool = createEditTool(cwd: dir.path)
        let edits: JSONValue = .array([
            .object([
                "oldText": .string("\"free\""),
                "newText": .string("\"$0.00\""),
            ])
        ])
        let result = try await tool.execute(
            "call-1",
            .object(["path": .string(file.path), "edits": edits]),
            nil, nil
        )
        #expect(textOutput(result).contains("Successfully replaced"))
        let after = try String(contentsOf: file, encoding: .utf8)
        // After fuzzy substitution, the content lives in normalized (ASCII) space.
        #expect(after.contains("\"$0.00\""))
    }
}
