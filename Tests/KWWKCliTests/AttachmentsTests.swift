import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKCli

// MARK: - Path detection

@Suite("looksLikeSinglePath")
struct PathDetectionTests {

    @Test("absolute, home, relative variants accepted")
    func acceptedForms() {
        #expect(looksLikeSinglePath("/tmp/foo.txt"))
        #expect(looksLikeSinglePath("~/Documents/a.png"))
        #expect(looksLikeSinglePath("./local.md"))
        #expect(looksLikeSinglePath("../sibling.ts"))
    }

    @Test("plain text and pasted sentences rejected")
    func rejected() {
        #expect(!looksLikeSinglePath("hello world"))
        #expect(!looksLikeSinglePath("foo"))
        #expect(!looksLikeSinglePath(""))
        // Multi-line rejected even if the first line is a path —
        // likely a code snippet, not a Finder drag.
        #expect(!looksLikeSinglePath("/tmp/foo\nmore stuff"))
    }

    @Test("quoted paths with whitespace still pass")
    func quotedPaths() {
        #expect(looksLikeSinglePath("\"/Users/me/has spaces.png\""))
        #expect(looksLikeSinglePath("'/Users/me/has spaces.png'"))
    }

    @Test("bare whitespace without quotes fails")
    func unquotedSpacesFail() {
        #expect(!looksLikeSinglePath("/Users/me/has spaces.png"))
    }
}

// MARK: - @-token extraction

@Suite("extractAtTokens")
struct AtTokenExtractionTests {

    @Test("pulls multiple tokens from free-form prose")
    func multipleTokens() {
        let tokens = extractAtTokens(from: "please look at @/tmp/a.png and @/tmp/b.txt")
        #expect(tokens == ["/tmp/a.png", "/tmp/b.txt"])
    }

    @Test("strips trailing punctuation")
    func trailingPunctuation() {
        let tokens = extractAtTokens(from: "check @/tmp/a.png, and @/tmp/b.png.")
        #expect(tokens == ["/tmp/a.png", "/tmp/b.png"])
    }

    @Test("dedupes duplicate paths")
    func dedup() {
        let tokens = extractAtTokens(from: "@/x.png appears twice: @/x.png")
        #expect(tokens == ["/x.png"])
    }

    @Test("ignores @ that isn't followed by content")
    func bareAt() {
        #expect(extractAtTokens(from: "email me at @ later").isEmpty)
    }
}

// MARK: - AttachmentStore

@Suite("AttachmentStore pasted-text")
struct AttachmentStoreTests {

    @MainActor
    @Test("add returns the expected placeholder and stores the body")
    func addAndLookup() {
        let store = AttachmentStore()
        let token = store.addPastedText("line1\nline2\nline3")
        #expect(token == "[pasted-text #1]")
        #expect(store.pastedTexts.count == 1)
        let entry = store.pastedText(id: 1)
        #expect(entry?.body == "line1\nline2\nline3")
    }

    @MainActor
    @Test("expandPastedTextPlaceholders substitutes raw bodies, leaves unknown ids alone")
    func expandPlaceholders() {
        let store = AttachmentStore()
        let token = store.addPastedText("one\ntwo")
        let expanded = store.expandPastedTextPlaceholders(in: "see \(token) and [pasted-text #9]")
        #expect(expanded == "see one\ntwo and [pasted-text #9]")
    }

    @MainActor
    @Test("ids increment and clear resets them")
    func idsAndClear() {
        let store = AttachmentStore()
        _ = store.addPastedText("a")
        _ = store.addPastedText("b")
        #expect(store.addPastedText("c") == "[pasted-text #3]")
        store.clear()
        #expect(store.pastedTexts.isEmpty)
        #expect(store.addPastedText("first-again") == "[pasted-text #1]")
    }

    @MainActor
    @Test("clipboard images get separate [image #N] placeholders and reset on clear")
    func clipboardImagesIndependentOfPastedText() {
        let store = AttachmentStore()
        _ = store.addPastedText("prose")
        let imgToken = store.addClipboardImage(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png"
        )
        #expect(imgToken == "[image #1]")
        #expect(store.clipboardImages.count == 1)
        let nextImg = store.addClipboardImage(data: Data(), mimeType: "image/png")
        #expect(nextImg == "[image #2]", "image ids should increment independently of pasted-text ids")
        store.clear()
        #expect(store.clipboardImages.isEmpty)
    }
}

// MARK: - buildPromptWithAttachments

@Suite("buildPromptWithAttachments")
struct BuildPromptTests {

    @MainActor
    @Test("no attachments → text unchanged, no summary")
    func passthrough() {
        let store = AttachmentStore()
        let built = buildPromptWithAttachments(
            text: "hello world",
            store: store,
            cwd: "/tmp",
            modelSupportsImages: true
        )
        #expect(built.text == "hello world")
        #expect(built.images.isEmpty)
        #expect(built.summary == nil)
    }

    @MainActor
    @Test("pasted-text placeholder expanded to its raw body, @text-file appended as <attachments>")
    func textFileAndPasted() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let filePath = dir.appendingPathComponent("hello.txt").path
        try "GREETINGS".write(toFile: filePath, atomically: true, encoding: .utf8)

        let store = AttachmentStore()
        let placeholder = store.addPastedText("one\ntwo")

        let built = buildPromptWithAttachments(
            text: "see \(placeholder) and @\(filePath).",
            store: store,
            cwd: "/tmp",
            modelSupportsImages: true
        )
        #expect(!built.text.contains("<pasted-text"), "paste expands to raw text, no XML wrapper")
        #expect(built.text.contains("see one\ntwo and @"))
        #expect(built.text.contains("<attachments>"))
        #expect(built.text.contains("<file path=\"\(filePath)\""))
        #expect(built.text.contains("GREETINGS"))
        #expect(built.images.isEmpty)
        #expect(built.summary?.contains("1 file") == true)
        #expect(built.summary?.contains("1 pasted text") == true)
    }

    @MainActor
    @Test("missing path surfaces as a <missing> tag + 'missing' summary entry")
    func missingPath() {
        let store = AttachmentStore()
        let built = buildPromptWithAttachments(
            text: "look at @/definitely/not/here.png",
            store: store,
            cwd: "/tmp",
            modelSupportsImages: true
        )
        #expect(built.text.contains("<missing path=\"/definitely/not/here.png\""))
        #expect(built.images.isEmpty)
        #expect(built.summary?.contains("1 missing") == true)
    }

    @MainActor
    @Test("folder renders a truncated listing")
    func folderListing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.txt", "b.md", "sub"] {
            if name == "sub" {
                try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
            } else {
                try "x".write(toFile: dir.appendingPathComponent(name).path, atomically: true, encoding: .utf8)
            }
        }
        let store = AttachmentStore()
        let built = buildPromptWithAttachments(
            text: "inspect @\(dir.path)",
            store: store,
            cwd: "/tmp",
            modelSupportsImages: true
        )
        #expect(built.text.contains("<folder path=\"\(dir.path)\">"))
        #expect(built.text.contains("a.txt"))
        #expect(built.text.contains("b.md"))
        #expect(built.text.contains("sub/"))
        #expect(built.summary?.contains("1 folder") == true)
    }

    @MainActor
    @Test("image bytes attached when model supports images")
    func imageAttached() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pngHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let imagePath = dir.appendingPathComponent("shot.png")
        try Data(pngHeader).write(to: imagePath)
        let store = AttachmentStore()
        let built = buildPromptWithAttachments(
            text: "@\(imagePath.path) what is this?",
            store: store,
            cwd: "/tmp",
            modelSupportsImages: true
        )
        #expect(built.images.count == 1)
        #expect(built.images.first?.mimeType == "image/png")
        #expect(built.summary?.contains("1 image") == true)
    }

    @MainActor
    @Test("clipboard-image keeps its [image #N] token in the prose and attaches bytes")
    func clipboardImageExpands() {
        let store = AttachmentStore()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let token = store.addClipboardImage(data: bytes, mimeType: "image/png")
        let built = buildPromptWithAttachments(
            text: "what is this: \(token) any ideas?",
            store: store,
            cwd: "/tmp",
            modelSupportsImages: true
        )
        // The `[image #N]` token is left verbatim so the transcript matches the
        // input box; correlation to the bytes happens via the matching id in
        // the <attachments> block, not an inline <clipboard-image/> marker.
        #expect(built.text.contains("[image #1]"),
                "token should stay [image #1], consistent with the input box")
        #expect(!built.text.contains("<clipboard-image"))
        #expect(built.text.contains("<attachments>"))
        #expect(built.text.contains("source=\"clipboard\""))
        #expect(built.text.contains("id=\"1\""))
        #expect(built.images.count == 1)
        #expect(built.images.first?.mimeType == "image/png")
        #expect(built.summary?.contains("1 image") == true)
    }

    @MainActor
    @Test("clipboard-image on a text-only model is skipped with a note")
    func clipboardImageSkippedOnTextOnly() {
        let store = AttachmentStore()
        let token = store.addClipboardImage(data: Data([1, 2, 3]), mimeType: "image/png")
        let built = buildPromptWithAttachments(
            text: "\(token)",
            store: store,
            cwd: "/tmp",
            modelSupportsImages: false
        )
        #expect(built.images.isEmpty)
        #expect(built.text.contains("skipped"))
        #expect(built.summary?.contains("skipped") == true)
    }

    @MainActor
    @Test("image is dropped + noted when model can't accept images")
    func imageSkippedOnTextOnlyModel() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let imagePath = dir.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imagePath)
        let store = AttachmentStore()
        let built = buildPromptWithAttachments(
            text: "@\(imagePath.path)",
            store: store,
            cwd: "/tmp",
            modelSupportsImages: false
        )
        #expect(built.images.isEmpty, "must not attach bytes to a text-only model")
        #expect(built.text.contains("skipped"))
        #expect(built.summary?.contains("skipped") == true)
    }
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("kwwk-attach-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
