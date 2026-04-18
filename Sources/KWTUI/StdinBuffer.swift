import Foundation

/// Byte-level accumulator that splits raw stdin into complete key sequences.
///
/// - Incomplete CSI (`ESC [` with no final byte) stays buffered.
/// - Bracketed paste start/end sequences are emitted as single synthetic keys.
/// - Standalone `ESC` waits briefly before flushing, in case an escape
///   sequence is in transit (handled by `flushOnTimeout`).
public final class StdinBuffer: @unchecked Sendable {
    public init() {}

    private let lock = NSLock()
    private var buffer: [UInt8] = []

    public func feed(_ chunk: Data) -> [String] {
        var out: [String] = []
        lock.withLock {
            buffer.append(contentsOf: chunk)
            while let (consumed, sequence) = takeOne() {
                if let sequence { out.append(sequence) }
                if consumed == 0 { break }
                buffer.removeFirst(consumed)
            }
        }
        return out
    }

    /// Feed the UTF-8 bytes of a string. Equivalent to `feed(Data(str.utf8))`.
    public func feed(_ string: String) -> [String] {
        feed(Data(string.utf8))
    }

    /// Force-flush a lingering `ESC` that arrived without further bytes.
    public func flushOnTimeout() -> [String] {
        lock.withLock {
            guard let first = buffer.first else { return [] }
            if first == 0x1B && buffer.count == 1 {
                buffer.removeFirst()
                return ["\u{1B}"]
            }
            return []
        }
    }

    private func takeOne() -> (Int, String?)? {
        guard !buffer.isEmpty else { return nil }
        let first = buffer[0]

        // Bracketed paste start: ESC [ 200 ~
        if startsWith([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) {
            if let endIdx = findBracketedPasteEnd() {
                let bytes = Array(buffer[..<endIdx])
                let consumed = endIdx
                return (consumed, String(data: Data(bytes), encoding: .utf8))
            }
            return nil
        }

        // ESC sequences.
        if first == 0x1B {
            if buffer.count == 1 { return nil } // wait for more
            let second = buffer[1]
            if second == 0x5B || second == 0x4F {
                // CSI or SS3 — wait for a final byte (0x40...0x7E).
                var i = 2
                while i < buffer.count {
                    let b = buffer[i]
                    if (b >= 0x40 && b <= 0x7E) {
                        let bytes = Array(buffer[..<(i + 1)])
                        return (i + 1, String(data: Data(bytes), encoding: .utf8))
                    }
                    i += 1
                }
                return nil
            }
            // ESC + single byte (alt-prefixed)
            let bytes = Array(buffer[..<2])
            return (2, String(data: Data(bytes), encoding: .utf8))
        }

        // UTF-8 continuation
        let len = utf8Length(leadByte: first)
        if buffer.count < len { return nil }
        let bytes = Array(buffer[..<len])
        return (len, String(data: Data(bytes), encoding: .utf8))
    }

    private func startsWith(_ prefix: [UInt8]) -> Bool {
        guard buffer.count >= prefix.count else { return false }
        for i in 0..<prefix.count where buffer[i] != prefix[i] { return false }
        return true
    }

    private func findBracketedPasteEnd() -> Int? {
        let end: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        if buffer.count < end.count { return nil }
        for i in 0...(buffer.count - end.count) {
            if Array(buffer[i..<(i + end.count)]) == end {
                return i + end.count
            }
        }
        return nil
    }

    private func utf8Length(leadByte: UInt8) -> Int {
        switch leadByte {
        case 0x00...0x7F: return 1
        case 0xC0...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF7: return 4
        default: return 1
        }
    }
}
