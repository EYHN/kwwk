import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Read an image off the system clipboard, if one is present. Returns
/// `nil` when the pasteboard holds nothing image-shaped — callers
/// should fall through to the normal text-paste flow in that case.
///
/// Design note: most macOS terminals, when the user ⌘V's a clipboard
/// image, send the bracketed-paste wrapper with an empty (or otherwise
/// degenerate) body. The image bytes themselves never reach stdin.
/// So on every paste event we peek at NSPasteboard: if there's an
/// image, we grab it here and ignore whatever the terminal sent.
enum ClipboardImageReader {

    /// Cached pasteboard change counter from the last read.
    /// `readIfPresent` only returns an image once per pasteboard
    /// generation, so a user who hits ⌘V three times doesn't get the
    /// same screenshot attached three times unless they actually
    /// re-copy. MainActor-isolated since every read goes through the
    /// UI input handler.
    @MainActor
    private static var lastSeenChangeCount: Int = -1

    @MainActor
    static func readIfPresent() -> (data: Data, mimeType: String)? {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        // `changeCount` increments every time something is written
        // to the pasteboard. If it hasn't moved since our last read,
        // the user is pasting the same clip again — treat as "no new
        // image" so we don't re-attach the same bytes.
        if pb.changeCount == lastSeenChangeCount { return nil }
        guard let data = extractImageData(from: pb) else {
            // Still bump the counter so we don't retry every paste
            // on a pasteboard that has no image.
            lastSeenChangeCount = pb.changeCount
            return nil
        }
        lastSeenChangeCount = pb.changeCount
        return data
        #else
        return nil
        #endif
    }

    #if canImport(AppKit)
    /// Order of preference:
    ///   1. `public.png` bytes — lossless, what screenshots use.
    ///   2. Any other image type we know how to MIME-tag.
    ///   3. Synthesize PNG bytes from an `NSImage` fallback (covers
    ///      screenshots copied via ⇧⌃⌘4 which go to the pasteboard
    ///      as NSImage only).
    private static func extractImageData(from pb: NSPasteboard) -> (data: Data, mimeType: String)? {
        // Preferred: a concrete PNG or similar already in the clip.
        let typeMap: [(NSPasteboard.PasteboardType, String)] = [
            (.init("public.png"), "image/png"),
            (.init("public.jpeg"), "image/jpeg"),
            (.init("public.tiff"), "image/tiff"),
            (.init("public.gif"), "image/gif"),
        ]
        for (type, mime) in typeMap {
            if let data = pb.data(forType: type), !data.isEmpty {
                // TIFF is technically valid per model specs, but
                // Anthropic + OpenAI Responses prefer PNG. Convert if
                // the data looks like TIFF.
                if mime == "image/tiff", let png = convertTIFFToPNG(data) {
                    return (png, "image/png")
                }
                return (data, mime)
            }
        }
        // Fallback: pull an NSImage and re-encode as PNG. Covers the
        // ⇧⌃⌘4 screenshot path on macOS 14+ which sometimes only
        // populates the NSImage representation.
        if let image = NSImage(pasteboard: pb),
           let png = pngData(from: image) {
            return (png, "image/png")
        }
        return nil
    }

    private static func convertTIFFToPNG(_ tiff: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
    #endif
}

/// Write text to the system clipboard. On macOS this drives `NSPasteboard`;
/// everywhere else (and over SSH where there's no local pasteboard) it falls
/// back to the OSC 52 terminal escape, which asks the *outer* terminal
/// emulator to set its own clipboard. Backs `/copy` and `/dump`.
enum ClipboardWriter {

    /// Result of a write so callers can tailor the confirmation message.
    enum Outcome: Equatable {
        /// Wrote via the native macOS pasteboard.
        case pasteboard
        /// Emitted an OSC 52 escape to stdout (remote / non-macOS terminals).
        case osc52
    }

    /// Copy `text` to the clipboard. Prefers the native pasteboard; otherwise
    /// emits OSC 52. `write` lets tests capture the escape without touching the
    /// real terminal — production callers leave it at the stdout default.
    @discardableResult
    static func copy(
        _ text: String,
        write: (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) }
    ) -> Outcome {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return .pasteboard
        #else
        write(osc52Sequence(for: text))
        return .osc52
        #endif
    }

    /// The OSC 52 "set clipboard" escape for `text`. Format:
    /// `ESC ] 52 ; c ; <base64> BEL`. `c` selects the clipboard (vs. the
    /// primary selection). Exposed (internal) so tests can assert the payload.
    static func osc52Sequence(for text: String) -> String {
        let b64 = Data(text.utf8).base64EncodedString()
        return "\u{1B}]52;c;\(b64)\u{07}"
    }
}
