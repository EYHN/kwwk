import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent

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

    @Test("fuzzy edit preserves untouched lines byte-for-byte (no data loss)")
    func fuzzyEditPreservesUnchangedLines() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.txt")
        // Untouched lines carry smart quotes, an em-dash, trailing whitespace,
        // and NBSP — all of which fuzzy-normalization would otherwise flatten.
        let untouched1 = "Keep \u{201C}smart\u{201D} quotes \u{2014} and trailing ws   "
        let untouched2 = "NBSP\u{00A0}here and an en\u{2013}dash, plus tabs\t\t"
        let original = [
            untouched1,
            "The price is \u{201C}free\u{201D} today.",
            untouched2,
        ].joined(separator: "\n")
        try write(original, to: file)

        let tool = createEditTool(cwd: dir.path)
        let edits: JSONValue = .array([
            .object(["oldText": .string("\"free\""), "newText": .string("\"$0.00\"")])
        ])
        _ = try await tool.execute(
            "call-2", .object(["path": .string(file.path), "edits": edits]), nil, nil
        )

        let after = try String(contentsOf: file, encoding: .utf8)
        let lines = after.components(separatedBy: "\n")
        #expect(lines.count == 3)
        // The two untouched lines must be byte-identical to the originals.
        #expect(lines[0] == untouched1)
        #expect(lines[2] == untouched2)
        // The edited line changed.
        #expect(lines[1].contains("\"$0.00\""))
    }
}

@Suite("Edit recovery paths")
struct EditRecoveryTests {
    @Test("replaceAll replaces every occurrence")
    func replaceAllReplacesEveryOccurrence() throws {
        let content = "let a = foo()\nlet b = foo()\nlet c = bar()\n"
        let result = try EditDiff.applyEdits(
            to: content,
            edits: [EditDiff.Edit(oldText: "foo()", newText: "baz()", replaceAll: true)],
            path: "test.swift"
        )
        #expect(result.newContent == "let a = baz()\nlet b = baz()\nlet c = bar()\n")
    }

    @Test("multiple matches without replaceAll names both recovery options")
    func multipleMatchesErrorNamesRecovery() {
        let content = "foo\nfoo\n"
        do {
            _ = try EditDiff.applyEdits(
                to: content,
                edits: [EditDiff.Edit(oldText: "foo", newText: "bar")],
                path: "test.swift"
            )
            Issue.record("expected multipleMatches")
        } catch let error as CodingToolError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("replaceAll"))
            #expect(message.contains("surrounding lines"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("textNotFound shows the closest candidate lines from the file")
    func textNotFoundShowsNearMiss() {
        let content = "func total() -> Int {\n    return items.count\n}\n"
        do {
            _ = try EditDiff.applyEdits(
                to: content,
                edits: [EditDiff.Edit(
                    oldText: "func total() -> Int {\n    return items.size\n}",
                    newText: "func total() -> Int { 0 }"
                )],
                path: "test.swift"
            )
            Issue.record("expected textNotFound")
        } catch let error as CodingToolError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("Closest candidate"))
            #expect(message.contains("line 1"))
            // The snippet must show what the file actually contains at the
            // near-miss location, so the model can fix oldText in one shot.
            #expect(message.contains("return items.count"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("textNotFound with no plausible anchor omits the candidate block")
    func textNotFoundWithoutAnchorStaysPlain() {
        let content = "alpha\nbeta\n"
        do {
            _ = try EditDiff.applyEdits(
                to: content,
                edits: [EditDiff.Edit(oldText: "gamma delta", newText: "x")],
                path: "test.swift"
            )
            Issue.record("expected textNotFound")
        } catch let error as CodingToolError {
            let message = error.errorDescription ?? ""
            #expect(!message.contains("Closest candidate"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
