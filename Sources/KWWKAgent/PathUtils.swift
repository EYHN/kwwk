import Foundation

public enum PathUtils {
    private static let unicodeSpaceScalars = Set<UInt32>(
        [UInt32(0x00A0), UInt32(0x202F), UInt32(0x205F), UInt32(0x3000)]
            + (0x2000...0x200A).map(UInt32.init)
    )

    /// Resolve a possibly-relative path against `cwd` and expand leading `~`.
    public static func resolveToCwd(_ path: String, cwd: String) -> String {
        let p = expandPath(path)
        let resolved: String
        if p.hasPrefix("/") {
            resolved = p
        } else {
            let base = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
            resolved = "\(base)/\(p)"
        }
        return URL(fileURLWithPath: resolved).standardized.path
    }

    /// Normalize model/user path spelling the same way pi's `expandPath` does:
    /// strip a leading `@`, normalize Unicode spaces, and expand `~`/`~/...`.
    public static func expandPath(_ path: String) -> String {
        var p = path.hasPrefix("@") ? String(path.dropFirst()) : path
        p = normalizeUnicodeSpaces(p)
        if p == "~" {
            return NSHomeDirectory()
        }
        if p.hasPrefix("~/") {
            return NSHomeDirectory() + String(p.dropFirst())
        }
        return p
    }

    public static func normalizeUnicodeSpaces(_ path: String) -> String {
        var out = ""
        out.reserveCapacity(path.count)
        for scalar in path.unicodeScalars {
            if unicodeSpaceScalars.contains(scalar.value) {
                out.append(" ")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Detect a supported image MIME type by sniffing leading magic bytes.
    /// Mirrors pi-coding-agent's `detectSupportedImageMimeTypeFromFile`.
    public static func detectImageMimeType(from data: Data) -> String? {
        if data.count >= 8 {
            // PNG: 89 50 4E 47 0D 0A 1A 0A
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        }
        if data.count >= 3 {
            // JPEG: FF D8 FF
            if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
            // GIF: 47 49 46 (GIF)
            if data.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        }
        if data.count >= 12 {
            // WebP: RIFF ... WEBP
            if data.starts(with: [0x52, 0x49, 0x46, 0x46]) {
                let sub = data[8..<12]
                if Array(sub) == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
            }
        }
        return nil
    }
}
