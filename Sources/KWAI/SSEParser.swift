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

    public init() {}

    public func ingest(bytes: Data) {
        guard let s = String(data: bytes, encoding: .utf8) else { return }
        ingest(s)
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
    bytes: AsyncThrowingStream<UInt8, Error>
) -> AsyncThrowingStream<SSEMessage, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            let parser = SSEParser()
            var chunk = [UInt8]()
            do {
                for try await byte in bytes {
                    chunk.append(byte)
                    if byte == 0x0a {
                        parser.ingest(bytes: Data(chunk))
                        chunk.removeAll()
                        for msg in parser.drain() {
                            continuation.yield(msg)
                        }
                    }
                }
                if !chunk.isEmpty {
                    parser.ingest(bytes: Data(chunk))
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
