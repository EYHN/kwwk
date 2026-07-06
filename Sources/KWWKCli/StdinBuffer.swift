import Foundation

/// Byte-level accumulator that splits raw stdin into complete key sequences.
///
/// - Incomplete CSI (`ESC [` with no final byte) stays buffered.
/// - Bracketed paste start/end sequences are emitted as single synthetic keys.
/// - Standalone `ESC` waits briefly before flushing, in case an escape
///   sequence is in transit (handled by `flushOnTimeout`).
///
/// Consumed bytes are tracked with a read cursor (`readPos`) instead of being
/// spliced off the front on every key, and the still-accumulating bracketed
/// paste keeps a resumable end-scan cursor. Both keep large pastes linear:
/// naïvely re-`removeFirst`-ing per key and rescanning the whole buffer for the
/// paste terminator on every 64 KB chunk was O(n²) and froze the TUI.
final class StdinBuffer: @unchecked Sendable {
    init() {}

    private let lock = NSLock()
    private var buffer: [UInt8] = []
    /// Start of the unconsumed region. Advanced as sequences are emitted; the
    /// consumed prefix is dropped by `compact()` once nothing is mid-flight.
    private var readPos: Int = 0
    /// While a bracketed-paste body is still arriving across `feed()` chunks,
    /// the absolute buffer index from which the next end-terminator scan should
    /// resume. `nil` when no paste is mid-flight. Persisting it stops each new
    /// chunk from rescanning the whole (possibly multi-MB) accumulated paste
    /// from the start.
    private var pasteEndSearchFrom: Int?

    func feed(_ chunk: Data) -> [String] {
        var out: [String] = []
        lock.withLock {
            buffer.append(contentsOf: chunk)
            while let (consumed, sequence) = takeOne() {
                if let sequence { out.append(sequence) }
                if consumed == 0 { break }
                readPos += consumed
            }
            compact()
        }
        return out
    }

    /// Feed the UTF-8 bytes of a string. Equivalent to `feed(Data(str.utf8))`.
    func feed(_ string: String) -> [String] {
        feed(Data(string.utf8))
    }

    /// Force-flush a lingering `ESC` that arrived without further bytes.
    func flushOnTimeout() -> [String] {
        lock.withLock {
            let avail = buffer.count - readPos
            guard avail > 0, buffer[readPos] == 0x1B else { return [] }
            // A genuine double-Escape that never grew into a meta-CSI: flush
            // BOTH escapes so neither is swallowed nor stranded. If only one
            // were drained, the second 0x1B would linger with no pending timer
            // and later merge with an incoming arrow into a bogus meta-CSI.
            // A real meta-arrow would have completed via feed() by the time
            // this timeout fires.
            if avail == 2 && buffer[readPos + 1] == 0x1B {
                readPos += 2
                compact()
                return ["\u{1B}", "\u{1B}"]
            }
            // A lone ESC: flush it so the key isn't swallowed.
            if avail == 1 {
                readPos += 1
                compact()
                return ["\u{1B}"]
            }
            return []
        }
    }

    /// Drop the consumed prefix so the backing array can't grow without bound.
    /// Rebases the paste-scan cursor (an absolute index) onto the shifted
    /// buffer. Only shifts bytes when something was consumed; a mid-flight
    /// paste consumes nothing, so this is a no-op until the paste lands.
    private func compact() {
        guard readPos > 0 else { return }
        if readPos >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else {
            buffer.removeFirst(readPos)
        }
        if let f = pasteEndSearchFrom { pasteEndSearchFrom = max(0, f - readPos) }
        readPos = 0
    }

    private func takeOne() -> (Int, String?)? {
        let p = readPos
        let n = buffer.count
        let avail = n - p
        guard avail > 0 else { return nil }
        let first = buffer[p]

        // Bracketed paste start: ESC [ 200 ~
        if matchesAt(p, [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) {
            if let endIdx = findBracketedPasteEnd() {
                let bytes = Array(buffer[p..<endIdx])
                pasteEndSearchFrom = nil
                return (endIdx - p, String(data: Data(bytes), encoding: .utf8))
            }
            return nil
        }

        // ESC sequences.
        if first == 0x1B {
            if avail == 1 { return nil } // wait for more
            let second = buffer[p + 1]
            // Meta-prefixed CSI/SS3: `ESC ESC [ … ` or `ESC ESC O X`. macOS
            // terminals using "Option as Meta" encode Option+Arrow this way
            // (a leading ESC modifier in front of the normal arrow sequence).
            // Assemble the whole inner sequence so Keys.parse can mark it alt.
            if second == 0x1B {
                if avail < 3 { return nil } // wait — meta-CSI in transit
                if buffer[p + 2] == 0x5B || buffer[p + 2] == 0x4F {
                    var i = p + 3
                    while i < n {
                        let b = buffer[i]
                        if b >= 0x40 && b <= 0x7E {
                            let bytes = Array(buffer[p..<(i + 1)])
                            return (i + 1 - p, String(data: Data(bytes), encoding: .utf8))
                        }
                        i += 1
                    }
                    return nil // final byte not here yet
                }
                // `ESC ESC <other>`: flush the leading ESC on its own; the
                // remainder parses on the next pass.
                return (1, "\u{1B}")
            }
            if second == 0x5B || second == 0x4F {
                // CSI or SS3 — wait for a final byte (0x40...0x7E).
                var i = p + 2
                while i < n {
                    let b = buffer[i]
                    if (b >= 0x40 && b <= 0x7E) {
                        let bytes = Array(buffer[p..<(i + 1)])
                        return (i + 1 - p, String(data: Data(bytes), encoding: .utf8))
                    }
                    i += 1
                }
                return nil
            }
            // ESC + single byte (alt-prefixed)
            let bytes = Array(buffer[p..<(p + 2)])
            return (2, String(data: Data(bytes), encoding: .utf8))
        }

        // UTF-8 continuation
        let len = utf8Length(leadByte: first)
        if avail < len { return nil }
        let bytes = Array(buffer[p..<(p + len)])
        return (len, String(data: Data(bytes), encoding: .utf8))
    }

    /// True when `pattern` matches the bytes at absolute index `index`.
    /// Compares in place — no per-position `Array` slice allocation.
    private func matchesAt(_ index: Int, _ pattern: [UInt8]) -> Bool {
        guard index >= 0, index + pattern.count <= buffer.count else { return false }
        for k in 0..<pattern.count where buffer[index + k] != pattern[k] { return false }
        return true
    }

    private func findBracketedPasteEnd() -> Int? {
        let end: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        // Body starts right after the 6-byte start marker at `readPos`.
        let dataStart = readPos + 6
        // Resume where the last scan stopped, backing up by `end.count - 1` so
        // a terminator split across the previous chunk boundary is still found.
        var i = max(dataStart, (pasteEndSearchFrom ?? dataStart) - (end.count - 1))
        let last = buffer.count - end.count
        while i <= last {
            if matchesAt(i, end) { return i + end.count }
            i += 1
        }
        // Not found yet — record the resume point for the next chunk.
        pasteEndSearchFrom = max(dataStart, buffer.count - (end.count - 1))
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
