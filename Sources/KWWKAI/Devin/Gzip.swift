import Foundation
import CZlib

/// gzip (RFC 1952) compression over the system zlib. The Devin Connect wire
/// gzips request frames (`connect-content-encoding: gzip`) and may gzip
/// response frames and unary bodies, so both directions are needed.
enum Gzip {
    enum GzipError: Error, LocalizedError {
        case zlib(operation: String, code: Int32)
        case outputTooLarge(limit: Int)

        var errorDescription: String? {
            switch self {
            case .zlib(let operation, let code): return "gzip \(operation) failed (zlib code \(code))"
            case .outputTooLarge(let limit): return "gzip output exceeds \(limit)-byte cap"
            }
        }
    }

    /// `windowBits` 15 + 16 selects the gzip wrapper for deflate.
    private static let gzipWindowBits: Int32 = 15 + 16
    /// `windowBits` 15 + 32 makes inflate auto-detect gzip or zlib headers.
    private static let autoDetectWindowBits: Int32 = 15 + 32
    private static let chunkSize = 64 * 1024

    /// Whether `data` starts with the gzip magic bytes.
    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    static func compress(_ input: Data, level: Int32 = Z_DEFAULT_COMPRESSION) throws -> Data {
        var stream = z_stream()
        var status = deflateInit2_(
            &stream, level, Z_DEFLATED, gzipWindowBits, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw GzipError.zlib(operation: "deflateInit", code: status) }
        defer { deflateEnd(&stream) }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var source = [UInt8](input)
        let sourceCount = source.count
        status = source.withUnsafeMutableBufferPointer { sourcePtr -> Int32 in
            stream.next_in = sourcePtr.baseAddress
            stream.avail_in = uInt(sourceCount)
            var code: Int32 = Z_OK
            repeat {
                code = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    let result = deflate(&stream, Z_FINISH)
                    let produced = out.count - Int(stream.avail_out)
                    output.append(out.baseAddress!, count: produced)
                    return result
                }
            } while code == Z_OK
            return code
        }
        guard status == Z_STREAM_END else { throw GzipError.zlib(operation: "deflate", code: status) }
        return output
    }

    /// Inflate a gzip (or zlib) payload. `limit` bounds the decompressed size
    /// so a hostile peer cannot balloon memory with a compression bomb.
    static func decompress(_ input: Data, limit: Int = 64 * 1024 * 1024) throws -> Data {
        var stream = z_stream()
        var status = inflateInit2_(
            &stream, autoDetectWindowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw GzipError.zlib(operation: "inflateInit", code: status) }
        defer { inflateEnd(&stream) }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var source = [UInt8](input)
        let sourceCount = source.count
        var overflow = false
        status = source.withUnsafeMutableBufferPointer { sourcePtr -> Int32 in
            stream.next_in = sourcePtr.baseAddress
            stream.avail_in = uInt(sourceCount)
            var code: Int32 = Z_OK
            repeat {
                code = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    let result = inflate(&stream, Z_NO_FLUSH)
                    let produced = out.count - Int(stream.avail_out)
                    output.append(out.baseAddress!, count: produced)
                    return result
                }
                if output.count > limit { overflow = true; return code }
                // Z_BUF_ERROR with input left means "no progress possible":
                // truncated input. Stop instead of spinning.
                if code == Z_BUF_ERROR { break }
            } while code == Z_OK
            return code
        }
        if overflow { throw GzipError.outputTooLarge(limit: limit) }
        guard status == Z_STREAM_END else { throw GzipError.zlib(operation: "inflate", code: status) }
        return output
    }
}
