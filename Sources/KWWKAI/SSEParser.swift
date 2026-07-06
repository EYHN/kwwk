import Foundation

/// Server-Sent Events message. `event` defaults to "message" when not set on
/// the wire.
public struct SSEMessage: Sendable, Equatable {
    public var event: String
    public var data: String
    public var id: String?
}

/// Line-based SSE parser. Feed raw bytes / strings via `ingest`, pull complete
/// messages via `drain`.
public final class SSEParser: @unchecked Sendable {
    private var lineBuffer = ""
    private var event = "message"
    private var dataLines: [String] = []
    private var id: String?
    private var pending: [SSEMessage] = []
    /// Trailing bytes from the previous `ingest(bytes:)` that formed an
    /// incomplete multi-byte UTF-8 sequence. Prepended to the next chunk so a
    /// character split across a network read is not dropped.
    private var carryBytes = Data()

    public init() {}

    public func ingest(bytes: Data) {
        var buffer = carryBytes
        buffer.append(bytes)
        let (decoded, remaining) = Self.decodeUTF8Prefix(buffer)
        carryBytes = remaining
        if !decoded.isEmpty { ingest(decoded) }
    }

    /// Split `data` into its longest UTF-8-decodable prefix and any trailing
    /// bytes that form an incomplete multi-byte sequence (kept for the next
    /// call). If the data contains a genuinely invalid sequence rather than a
    /// boundary split, decode it lossily so the parser still makes progress.
    static func decodeUTF8Prefix(_ data: Data) -> (String, Data) {
        if data.isEmpty { return ("", Data()) }
        if let s = String(data: data, encoding: .utf8) { return (s, Data()) }
        // A UTF-8 sequence is at most 4 bytes, so an incomplete trailing
        // character lives in the last 3 bytes. Trim them one at a time looking
        // for a valid prefix.
        var end = data.count
        let lower = Swift.max(0, data.count - 3)
        while end > lower {
            end -= 1
            let prefix = data.subdata(in: 0..<end)
            if let s = String(data: prefix, encoding: .utf8) {
                return (s, data.subdata(in: end..<data.count))
            }
        }
        return (String(decoding: data, as: UTF8.self), Data())
    }

    public func ingest(_ text: String) {
        lineBuffer += text
        while let newlineRange = lineBuffer.range(of: "\n") {
            var line = String(lineBuffer[..<newlineRange.lowerBound])
            lineBuffer = String(lineBuffer[newlineRange.upperBound...])
            if line.hasSuffix("\r") { line.removeLast() }
            handle(line: line)
        }
    }

    private func handle(line: String) {
        if line.isEmpty {
            // Dispatch accumulated message.
            if !dataLines.isEmpty || event != "message" {
                let msg = SSEMessage(
                    event: event,
                    data: dataLines.joined(separator: "\n"),
                    id: id
                )
                pending.append(msg)
            }
            event = "message"
            dataLines.removeAll()
            id = nil
            return
        }
        if line.hasPrefix(":") { return } // comment
        if let colon = line.firstIndex(of: ":") {
            let field = String(line[..<colon])
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            switch field {
            case "event": event = value
            case "data": dataLines.append(value)
            case "id": id = value
            default: break // retry / custom fields — ignored
            }
        }
    }

    /// Drain and return buffered messages.
    public func drain() -> [SSEMessage] {
        let out = pending
        pending.removeAll()
        return out
    }

    /// Close parser — emits any trailing message that lacked a final blank
    /// line (rare, but observed from some servers).
    public func finish() -> [SSEMessage] {
        if !dataLines.isEmpty || event != "message" {
            pending.append(SSEMessage(event: event, data: dataLines.joined(separator: "\n"), id: id))
            dataLines.removeAll()
            event = "message"
            id = nil
        }
        return drain()
    }
}

/// Parse a stream of bytes into an async sequence of `SSEMessage`.
public func parseSSE(
    bytes: AsyncThrowingStream<Data, Error>
) -> AsyncThrowingStream<SSEMessage, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            let parser = SSEParser()
            do {
                for try await chunk in bytes {
                    parser.ingest(bytes: chunk)
                    for msg in parser.drain() {
                        continuation.yield(msg)
                    }
                }
                for msg in parser.finish() {
                    continuation.yield(msg)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
