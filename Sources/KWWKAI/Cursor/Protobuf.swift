import Foundation

/// Minimal protobuf (proto3) wire-format reader and writer, hand-rolled for the
/// subset of the Cursor `agent.v1` schema kwwk speaks. This intentionally does
/// not depend on a protobuf runtime: we only need to encode a handful of
/// request messages and decode a handful of streamed server messages, so a
/// tiny wire codec keeps the dependency surface small.
///
/// Wire types used here: varint (0), 64-bit (1), length-delimited (2), 32-bit
/// (5). Only fields we actually read/write are handled; unknown fields are
/// skipped on decode.
enum ProtoWireType: Int {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

// MARK: - Writer

/// Accumulates protobuf-encoded bytes. Field encoders append a tag (field
/// number + wire type) followed by the value. Proto3 semantics: scalar zero /
/// empty-string / empty-bytes fields are omitted by the callers (they simply
/// don't call the encoder), matching the reference wire output.
struct ProtoWriter {
    private(set) var data = Data()

    mutating func rawVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private mutating func tag(_ field: Int, _ type: ProtoWireType) {
        rawVarint((UInt64(field) << 3) | UInt64(type.rawValue))
    }

    mutating func varintField(_ field: Int, _ value: UInt64) {
        tag(field, .varint)
        rawVarint(value)
    }

    mutating func boolField(_ field: Int, _ value: Bool) {
        varintField(field, value ? 1 : 0)
    }

    mutating func int32Field(_ field: Int, _ value: Int32) {
        // proto3 int32 is encoded as a (possibly 10-byte) varint.
        tag(field, .varint)
        rawVarint(UInt64(bitPattern: Int64(value)))
    }

    mutating func uint32Field(_ field: Int, _ value: UInt32) {
        varintField(field, UInt64(value))
    }

    mutating func stringField(_ field: Int, _ value: String) {
        bytesField(field, Data(value.utf8))
    }

    mutating func bytesField(_ field: Int, _ value: Data) {
        tag(field, .lengthDelimited)
        rawVarint(UInt64(value.count))
        data.append(value)
    }

    /// Append a nested message under `field`, built by `body` into its own
    /// writer, length-prefixed.
    mutating func messageField(_ field: Int, _ body: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        body(&inner)
        bytesField(field, inner.data)
    }

    mutating func doubleField(_ field: Int, _ value: Double) {
        tag(field, .fixed64)
        var v = value.bitPattern.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    /// Re-encode a field read by `ProtoReader` verbatim (used to copy unknown
    /// fields of a message we only partially model).
    mutating func copyField(_ field: ProtoReader.Field) {
        switch field.value {
        case .varint(let v):
            varintField(field.number, v)
        case .fixed64(let v):
            tag(field.number, .fixed64)
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        case .bytes(let d):
            bytesField(field.number, d)
        case .fixed32(let v):
            tag(field.number, .fixed32)
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
    }
}

// MARK: - Reader

/// Sequentially reads protobuf fields out of a buffer. `next()` yields the next
/// `(fieldNumber, value)` or nil at end. Unknown wire types are skipped.
struct ProtoReader {
    private let bytes: [UInt8]
    private var offset: Int

    init(_ data: Data) {
        self.bytes = [UInt8](data)
        self.offset = 0
    }

    private init(bytes: [UInt8], range: Range<Int>) {
        self.bytes = Array(bytes[range])
        self.offset = 0
    }

    var isAtEnd: Bool { offset >= bytes.count }

    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    struct Field {
        let number: Int
        let value: Value
    }

    private mutating func readRawVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count {
            let b = bytes[offset]
            offset += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    mutating func next() -> Field? {
        guard !isAtEnd, let tag = readRawVarint() else { return nil }
        let field = Int(tag >> 3)
        let wire = ProtoWireType(rawValue: Int(tag & 0x7))
        switch wire {
        case .varint:
            guard let v = readRawVarint() else { return nil }
            return Field(number: field, value: .varint(v))
        case .fixed64:
            guard offset + 8 <= bytes.count else { return nil }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * i) }
            offset += 8
            return Field(number: field, value: .fixed64(v))
        case .lengthDelimited:
            guard let len = readRawVarint(), len <= UInt64(bytes.count) else { return nil }
            let count = Int(len)
            guard count <= bytes.count - offset else { return nil }
            let slice = Data(bytes[offset..<offset + count])
            offset += count
            return Field(number: field, value: .bytes(slice))
        case .fixed32:
            guard offset + 4 <= bytes.count else { return nil }
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (8 * i) }
            offset += 4
            return Field(number: field, value: .fixed32(v))
        case .none:
            return nil
        }
    }
}

extension ProtoReader.Value {
    var asUInt64: UInt64? { if case .varint(let v) = self { return v }; return nil }
    var asInt32: Int32? { if case .varint(let v) = self { return Int32(truncatingIfNeeded: Int64(bitPattern: v)) }; return nil }
    var asBool: Bool? { if case .varint(let v) = self { return v != 0 }; return nil }
    var asData: Data? { if case .bytes(let d) = self { return d }; return nil }
    var asString: String? {
        if case .bytes(let d) = self { return String(data: d, encoding: .utf8) }
        return nil
    }
}
