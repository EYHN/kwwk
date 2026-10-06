import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKMCP

@Suite("MCP result files")
struct MCPResultFilesTests {
    /// Records what it is asked to save and answers a fake path.
    final class Files: MCPResultFiles, @unchecked Sendable {
        private let lock = NSLock()
        private var _saved: [(data: Data, mimeType: String)] = []
        var saved: [(data: Data, mimeType: String)] { lock.withLock { _saved } }

        func save(_ data: Data, mimeType: String, server: String, tool: String) async throws -> String {
            lock.withLock {
                _saved.append((data, mimeType))
                return "/files/\(server)-\(tool)-\(_saved.count)"
            }
        }
    }

    private static let png = "iVBORw0KGgo=" // the PNG signature, base64

    private func texts(_ result: AgentToolResult) -> [String] {
        result.content.compactMap { block in
            if case .text(let text) = block { return text.text }
            return nil
        }
    }

    @Test("an image stays visible and is also saved, with its path beside it")
    func imageSavedAndShown() async throws {
        let files = Files()
        let result = MCPCallToolResult(content: [.text("Frame 1"), .image(data: Self.png, mimeType: "image/png")])
        let converted = try await MCPToolAdapter.convert(
            server: "figma", tool: "get_screenshot", result: result, options: MCPResultOptions(files: files)
        )
        #expect(converted.content.count == 3)
        guard case .image(let image) = converted.content[1] else {
            Issue.record("expected the image second, got \(converted.content)")
            return
        }
        #expect(image.data == Self.png)
        #expect(texts(converted).last == "[Image saved at /files/figma-get_screenshot-1]")
        #expect(files.saved.count == 1)
        #expect(files.saved.first?.data == Data(base64Encoded: Self.png))
        #expect(files.saved.first?.mimeType == "image/png")
    }

    @Test("audio, binary resources and images the model cannot view are saved instead of dropped")
    func binaryContentSaved() async throws {
        let files = Files()
        let svg = Data("<svg/>".utf8).base64EncodedString()
        let pdf = Data("%PDF-1.7".utf8).base64EncodedString()
        let result = MCPCallToolResult(content: [
            .image(data: svg, mimeType: "image/svg+xml"),
            .audio(data: "AAAA", mimeType: "audio/wav"),
            .resource(uri: "file:///spec.pdf", mimeType: "application/pdf", text: nil, blob: pdf),
            .resource(uri: "file:///a.png", mimeType: "image/png", text: nil, blob: Self.png),
        ])
        let converted = try await MCPToolAdapter.convert(
            server: "s", tool: "t", result: result, options: MCPResultOptions(files: files)
        )
        let lines = texts(converted)
        #expect(lines.contains("[Image (image/svg+xml, 6 B) saved at /files/s-t-1]"))
        #expect(lines.contains("[Audio content (audio/wav, 3 B) saved at /files/s-t-2]"))
        #expect(lines.contains("[Binary resource file:///spec.pdf (application/pdf, 8 B) saved at /files/s-t-3]"))
        #expect(lines.contains("[Image resource file:///a.png saved at /files/s-t-4]"))
        // Only the PNG reaches the model as an image; the SVG would be refused.
        let images = converted.content.filter { if case .image = $0 { return true } else { return false } }
        #expect(images.count == 1)
        #expect(files.saved.map(\.mimeType) == ["image/svg+xml", "audio/wav", "application/pdf", "image/png"])
    }

    @Test("by default results are saved in a private directory under the system temp directory")
    func defaultTemporaryDirectory() async throws {
        let directory = MCPResultOptions.temporaryDirectory
        #expect(directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(directory.lastPathComponent.hasPrefix("kwwk-mcp-"))
        let png = Data("default-\(UUID().uuidString)".utf8).base64EncodedString()
        let converted = try await MCPToolAdapter.convert(
            server: "s", tool: "t",
            result: MCPCallToolResult(content: [.image(data: png, mimeType: "image/png")]),
            options: .default
        )
        let note = try #require(texts(converted).last)
        let path = String(try #require(note.components(separatedBy: " saved at ").last).dropLast())
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(path.hasPrefix(directory.path + "/"))
        #expect(FileManager.default.contents(atPath: path) == Data(base64Encoded: png))
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
    }

    @Test("with saving turned off binary content reads as before, and an unviewable image is left out")
    func withoutStore() async throws {
        let result = MCPCallToolResult(content: [
            .image(data: Self.png, mimeType: "image/png"),
            .image(data: "PHN2Zy8+", mimeType: "image/svg+xml"),
            .audio(data: "AAAA", mimeType: "audio/wav"),
        ])
        let converted = try await MCPToolAdapter.convert(
            server: "s", tool: "t", result: result, options: MCPResultOptions(spill: nil, files: nil)
        )
        #expect(converted.content.count == 3)
        #expect(texts(converted) == [
            "[Image (image/svg+xml, 6 B) omitted]",
            "[Audio content (audio/wav, 3 B) omitted]",
        ])
    }

    @Test("over the limit, left-out images keep their saved paths and are not spilled twice")
    func limitListsSavedFiles() async throws {
        final class Spill: MCPResultSpill, @unchecked Sendable {
            var received: MCPSpilledResult?
            func spill(_ result: MCPSpilledResult) async throws -> String {
                received = result
                return "/tmp/full.txt"
            }
        }
        let files = Files()
        let spill = Spill()
        let result = MCPCallToolResult(content: [
            .text(String(repeating: "x", count: 1_000)),
            .image(data: Self.png, mimeType: "image/png"),
        ])
        let converted = try await MCPToolAdapter.convert(
            server: "s", tool: "t", result: result,
            options: MCPResultOptions(maxTokens: 100, imageTokens: 50, spill: spill, files: files)
        )
        let note = try #require(texts(converted).last)
        #expect(note.contains("1 image left out"))
        #expect(note.contains("The full result is at /tmp/full.txt"))
        #expect(note.contains("Its files are at /files/s-t-1"))
        #expect(spill.received?.images.isEmpty == true)
    }

    @Test("a directory store names files by content and writes each once")
    func directoryStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kwwk-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPDirectoryResultFiles(directory: directory)
        let data = Data("hello".utf8)
        let first = try await store.save(data, mimeType: "image/jpeg", server: "figma", tool: "get-screenshot")
        let again = try await store.save(data, mimeType: "image/jpeg", server: "figma", tool: "get-screenshot")
        let other = try await store.save(Data("bye".utf8), mimeType: "image/jpeg", server: "figma", tool: "get-screenshot")
        #expect(first == again)
        #expect(first != other)
        #expect(URL(fileURLWithPath: first).lastPathComponent.hasPrefix("figma-get_screenshot-"))
        #expect(first.hasSuffix(".jpg"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: first)) == data)
        let listed = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(listed.count == 2)
    }

    @Test("file extensions follow the MIME type")
    func extensions() {
        #expect(MCPDirectoryResultFiles.fileExtension(for: "image/png") == "png")
        #expect(MCPDirectoryResultFiles.fileExtension(for: "image/jpeg") == "jpg")
        #expect(MCPDirectoryResultFiles.fileExtension(for: "image/svg+xml") == "svg")
        #expect(MCPDirectoryResultFiles.fileExtension(for: "application/pdf; charset=binary") == "pdf")
        #expect(MCPDirectoryResultFiles.fileExtension(for: "audio/x-flac") == "flac")
        #expect(MCPDirectoryResultFiles.fileExtension(for: "weird") == "weird")
        #expect(MCPDirectoryResultFiles.fileExtension(for: "") == "bin")
    }
}
