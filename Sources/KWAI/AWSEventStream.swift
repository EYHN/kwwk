import Foundation

/// One AWS event-stream message: a map of headers plus a payload. Bedrock's
/// Converse Stream uses this framing for every event.
public struct AWSEventMessage: Sendable {
    public var headers: [String: String]
    public var payload: Data
}

/// Parse a stream of raw bytes in AWS's event-stream framing into
/// `AWSEventMessage` values. Frame layout:
///
///   [total_len u32] [headers_len u32] [prelude_crc u32]
///   [headers...]
///   [payload...]
///   [message_crc u32]
///
/// Each header: [name_len u8] [name utf-8] [value_type u8] [value...].
/// We only decode string-typed values (type 7) and short values for the rest —
/// everything Bedrock Converse Stream actually emits.
public func parseAWSEventStream(
    bytes: AsyncThrowingStream<UInt8, Error>
) -> AsyncThrowingStream<AWSEventMessage, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            var buffer = Data()
            do {
                for try await byte in bytes {
                    buffer.append(byte)
                    while buffer.count >= 12 {
                        let totalLen = Int(readU32BE(buffer, offset: 0))
                        if totalLen <= 0 || totalLen > 1 << 20 {
                            throw NSError(domain: "AWSEventStream", code: 1, userInfo: [
                                NSLocalizedDescriptionKey: "invalid frame length \(totalLen)",
                            ])
                        }
                        if buffer.count < totalLen { break }
                        let frame = Data(buffer.prefix(totalLen))
                        if let msg = decodeFrame(frame) {
                            continuation.yield(msg)
                        }
                        buffer.removeFirst(totalLen)
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private func decodeFrame(_ frame: Data) -> AWSEventMessage? {
    guard frame.count >= 16 else { return nil }
    let headersLen = Int(readU32BE(frame, offset: 4))
    // prelude CRC at offset 8..12 — ignored (we already trust the length).
    let headersStart = 12
    let payloadStart = headersStart + headersLen
    guard frame.count >= payloadStart + 4 else { return nil }

    let headerData = Data(frame[headersStart..<payloadStart])
    let headers = decodeHeaders(headerData)

    let payloadEnd = frame.count - 4
    let payload = Data(frame[payloadStart..<payloadEnd])
    return AWSEventMessage(headers: headers, payload: payload)
}

private func decodeHeaders(_ data: Data) -> [String: String] {
    var out: [String: String] = [:]
    var i = data.startIndex
    let end = data.endIndex
    while i < end {
        // Name length (1 byte)
        guard i < end else { break }
        let nameLen = Int(data[i])
        i = data.index(after: i)
        guard i + nameLen <= end else { break }
        let name = String(data: data[i..<(i + nameLen)], encoding: .utf8) ?? ""
        i = data.index(i, offsetBy: nameLen)

        // Value type (1 byte)
        guard i < end else { break }
        let valueType = data[i]
        i = data.index(after: i)

        switch valueType {
        case 0: // TRUE
            out[name] = "true"
        case 1: // FALSE
            out[name] = "false"
        case 6, 7: // int16 / utf-8 string (both length-prefixed by u16)
            guard i + 2 <= end else { return out }
            let len = Int(readU16BE(data, offset: i - data.startIndex))
            i = data.index(i, offsetBy: 2)
            guard i + len <= end else { return out }
            if valueType == 7 {
                out[name] = String(data: data[i..<(i + len)], encoding: .utf8) ?? ""
            }
            i = data.index(i, offsetBy: len)
        case 2: // byte
            guard i < end else { return out }
            out[name] = "\(data[i])"
            i = data.index(after: i)
        case 3: // int16
            guard i + 2 <= end else { return out }
            out[name] = "\(readU16BE(data, offset: i - data.startIndex))"
            i = data.index(i, offsetBy: 2)
        case 4: // int32
            guard i + 4 <= end else { return out }
            out[name] = "\(readU32BE(data, offset: i - data.startIndex))"
            i = data.index(i, offsetBy: 4)
        case 5: // int64
            guard i + 8 <= end else { return out }
            i = data.index(i, offsetBy: 8)
        case 8: // timestamp (int64 ms)
            guard i + 8 <= end else { return out }
            i = data.index(i, offsetBy: 8)
        case 9: // uuid
            guard i + 16 <= end else { return out }
            i = data.index(i, offsetBy: 16)
        default:
            // Unknown — bail out so we don't misalign.
            return out
        }
    }
    return out
}

/// Encode an outgoing AWS event-stream frame. Only used for tests; Bedrock's
/// Converse Stream client is one-way (we always read).
public func encodeAWSEventFrame(headers: [String: String], payload: Data) -> Data {
    var headerData = Data()
    for (name, value) in headers {
        let nameBytes = Array(name.utf8)
        headerData.append(UInt8(nameBytes.count))
        headerData.append(contentsOf: nameBytes)
        headerData.append(7) // utf-8 string
        let valueBytes = Array(value.utf8)
        headerData.append(UInt8((valueBytes.count >> 8) & 0xff))
        headerData.append(UInt8(valueBytes.count & 0xff))
        headerData.append(contentsOf: valueBytes)
    }
    let totalLen = 12 + headerData.count + payload.count + 4
    var frame = Data()
    frame.appendU32BE(UInt32(totalLen))
    frame.appendU32BE(UInt32(headerData.count))
    // Prelude CRC is real in prod, but parsers accept arbitrary CRCs when
    // they skip verification. For mock traffic we store 0.
    frame.appendU32BE(0)
    frame.append(headerData)
    frame.append(payload)
    // Message CRC.
    frame.appendU32BE(0)
    return frame
}

// MARK: - Big-endian helpers

private func readU32BE(_ data: Data, offset: Int) -> UInt32 {
    let start = data.startIndex.advanced(by: offset)
    let b0 = UInt32(data[start])
    let b1 = UInt32(data[start + 1])
    let b2 = UInt32(data[start + 2])
    let b3 = UInt32(data[start + 3])
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

private func readU16BE(_ data: Data, offset: Int) -> UInt16 {
    let start = data.startIndex.advanced(by: offset)
    let b0 = UInt16(data[start])
    let b1 = UInt16(data[start + 1])
    return (b0 << 8) | b1
}

private extension Data {
    mutating func appendU32BE(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xff))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 8) & 0xff))
        append(UInt8(v & 0xff))
    }
}
