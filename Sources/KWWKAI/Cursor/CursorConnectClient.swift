import Foundation
import NIOCore
import NIOPosix
import NIOHTTP2
import NIOSSL
import NIOHPACK

/// One de-framed Connect-protocol message off the wire. Connect frames a
/// 5-byte prefix (`[flags:1][length:4 big-endian]`) in front of each payload;
/// the end-of-stream frame sets bit `0b10` and its payload is a JSON object
/// that may carry a trailing `error`.
enum CursorConnectFrame: Sendable {
    case message(Data)
    case endStream(Data)
}

enum CursorConnectError: Error, LocalizedError {
    case tlsSetupFailed(String)
    case connectionFailed(String)
    case httpStatus(Int, String)
    case grpc(status: String, message: String)
    case endStream(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .tlsSetupFailed(let s): return "Cursor TLS setup failed: \(s)"
        case .connectionFailed(let s): return "Cursor connection failed: \(s)"
        case .httpStatus(let code, let body): return "Cursor HTTP \(code): \(body)"
        case .grpc(let status, let message): return "Cursor gRPC error \(status): \(message)"
        case .endStream(let s): return "Cursor stream error: \(s)"
        case .transport(let s): return "Cursor transport error: \(s)"
        }
    }
}

/// Helpers for interpreting a Connect end-stream frame payload.
enum CursorConnectResponse {
    /// Parse a Connect end-stream JSON payload; returns an error when it carries
    /// a trailing `{ "error": { code, message } }`.
    static func errorFromEndStream(_ data: Data) -> CursorConnectError? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let error = obj["error"] as? [String: Any] else { return nil }
        let code = error["code"] as? String ?? "unknown"
        let message = error["message"] as? String ?? "Unknown error"
        return CursorConnectError.endStream("\(code): \(message)")
    }
}

/// A single full-duplex Connect-over-HTTP/2 stream to `api2.cursor.sh`. The
/// caller writes framed request messages with ``send(_:)`` (the run request
/// first, then heartbeats / KV / exec replies as the server asks for them) and
/// consumes de-framed server messages from ``frames``. Mirrors the Node
/// `http2` full-duplex usage in oh-my-pi's `streamCursor`.
final class CursorConnectStream: @unchecked Sendable {
    private let channel: Channel
    let frames: AsyncThrowingStream<CursorConnectFrame, Error>

    fileprivate init(channel: Channel, frames: AsyncThrowingStream<CursorConnectFrame, Error>) {
        self.channel = channel
        self.frames = frames
    }

    /// Frame `payload` with the Connect 5-byte prefix and write it as an
    /// HTTP/2 DATA frame. Best-effort: write failures surface on the read side.
    func send(_ payload: Data, flags: UInt8 = 0) {
        var framed = Data(capacity: payload.count + 5)
        framed.append(flags)
        let len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: len) { framed.append(contentsOf: $0) }
        framed.append(payload)

        var buffer = channel.allocator.buffer(capacity: framed.count)
        buffer.writeBytes(framed)
        let frame = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer), endStream: false))
        channel.writeAndFlush(frame, promise: nil)
    }

    func close() {
        channel.close(promise: nil)
    }
}

/// Opens Connect-over-HTTP/2 streams to the Cursor API. Owns a shared event
/// loop group for the process; kwwk is a short-lived CLI so a single lazily
/// created group is fine.
enum CursorConnect {
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    /// Open a POST stream to `path` on `host` with `headers`, send `initialBody`
    /// (already Connect-framed by the caller? no — we frame it here), and return
    /// a live duplex stream. The initial request body is sent as the first
    /// Connect frame; `endStream` is left open so the caller can keep writing.
    static func open(
        host: String,
        port: Int = 443,
        path: String,
        headers: [(String, String)],
        initialBody: Data
    ) async throws -> CursorConnectStream {
        let sslContext: NIOSSLContext
        do {
            var config = TLSConfiguration.makeClientConfiguration()
            config.applicationProtocols = ["h2"]
            sslContext = try NIOSSLContext(configuration: config)
        } catch {
            throw CursorConnectError.tlsSetupFailed(String(describing: error))
        }

        // Bring up the TCP + TLS + HTTP/2 connection channel.
        let connection: Channel
        do {
            connection = try await ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    do {
                        let ssl = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                        return channel.pipeline.addHandler(ssl).flatMap {
                            channel.configureHTTP2Pipeline(mode: .client) { _ in
                                channel.eventLoop.makeSucceededVoidFuture()
                            }.map { _ in }
                        }
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .connect(host: host, port: port)
                .get()
        } catch {
            throw CursorConnectError.connectionFailed(String(describing: error))
        }

        let multiplexer = try await connection.pipeline.handler(type: HTTP2StreamMultiplexer.self).get()

        let (stream, continuation) = AsyncThrowingStream<CursorConnectFrame, Error>.makeStream()
        let handler = CursorStreamHandler(
            host: host, path: path, headers: headers, initialBody: initialBody,
            continuation: continuation
        )

        let streamChannelPromise = connection.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: streamChannelPromise) { streamChannel in
            streamChannel.pipeline.addHandler(handler)
        }

        let streamChannel: Channel
        do {
            streamChannel = try await streamChannelPromise.futureResult.get()
        } catch {
            connection.close(promise: nil)
            throw CursorConnectError.connectionFailed(String(describing: error))
        }

        // Tear the parent connection down when the stream closes so we don't
        // leak the socket/event-loop registration.
        streamChannel.closeFuture.whenComplete { _ in
            connection.close(promise: nil)
        }

        return CursorConnectStream(channel: streamChannel, frames: stream)
    }
}

/// Per-stream NIO handler: writes the request headers + the first framed body
/// on channel-active, then translates inbound HTTP/2 frames into de-framed
/// Connect messages pushed to an `AsyncThrowingStream` continuation.
private final class CursorStreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    private let host: String
    private let path: String
    private let headers: [(String, String)]
    private let initialBody: Data
    private let continuation: AsyncThrowingStream<CursorConnectFrame, Error>.Continuation

    private var pending = Data()
    private var status: Int?
    private var finished = false
    /// Whether a Connect end-of-stream frame (flags 0b10) was seen — after it,
    /// connection teardown is a clean end rather than truncation.
    private var sawConnectEndStream = false

    init(
        host: String, path: String, headers: [(String, String)], initialBody: Data,
        continuation: AsyncThrowingStream<CursorConnectFrame, Error>.Continuation
    ) {
        self.host = host
        self.path = path
        self.headers = headers
        self.initialBody = initialBody
        self.continuation = continuation
    }

    func channelActive(context: ChannelHandlerContext) {
        var hpack = HPACKHeaders()
        hpack.add(name: ":method", value: "POST")
        hpack.add(name: ":scheme", value: "https")
        hpack.add(name: ":authority", value: host)
        hpack.add(name: ":path", value: path)
        for (name, value) in headers {
            hpack.add(name: name.lowercased(), value: value)
        }
        let headerFrame = HTTP2Frame.FramePayload.headers(.init(headers: hpack, endStream: false))
        context.write(self.wrapOutboundOut(headerFrame), promise: nil)

        // Request body. Connect streaming (`application/connect+proto`) frames
        // each message with a 5-byte prefix. `endStream` is left open so the
        // caller can keep writing (heartbeats / exec replies).
        var framed = Data(capacity: initialBody.count + 5)
        framed.append(0)
        let len = UInt32(initialBody.count).bigEndian
        withUnsafeBytes(of: len) { framed.append(contentsOf: $0) }
        framed.append(initialBody)
        var buffer = context.channel.allocator.buffer(capacity: framed.count)
        buffer.writeBytes(framed)
        let dataFrame = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer), endStream: false))
        context.writeAndFlush(self.wrapOutboundOut(dataFrame), promise: nil)

        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = self.unwrapInboundIn(data)
        switch payload {
        case .headers(let headerFrame):
            if let statusValue = headerFrame.headers.first(name: ":status"), let code = Int(statusValue) {
                status = code
            }
            // Trailing gRPC status on the closing HEADERS frame.
            if let grpcStatus = headerFrame.headers.first(name: "grpc-status"), grpcStatus != "0" {
                let msg = headerFrame.headers.first(name: "grpc-message") ?? ""
                finish(throwing: CursorConnectError.grpc(status: grpcStatus, message: msg.removingPercentEncoding ?? msg))
            }
            // END_STREAM riding a HEADERS frame ends the response too —
            // headers-only errors (e.g. a body-less 401) and clean trailers
            // would otherwise leave the stream hanging until timeout.
            if headerFrame.endStream { finishSuccessfully() }
        case .data(let dataFrame):
            if case .byteBuffer(let buffer) = dataFrame.data {
                pending.append(contentsOf: buffer.readableBytesView)
                drainFrames()
            }
            if dataFrame.endStream { finishSuccessfully() }
        default:
            break
        }
    }

    /// Split accumulated bytes into complete Connect frames.
    private func drainFrames() {
        while pending.count >= 5 {
            let flags = pending[pending.startIndex]
            let lenBytes = pending.subdata(in: pending.startIndex + 1 ..< pending.startIndex + 5)
            let msgLen = lenBytes.reduce(0) { ($0 << 8) | Int($1) }
            guard pending.count >= 5 + msgLen else { break }
            let start = pending.startIndex + 5
            let messageBytes = pending.subdata(in: start ..< start + msgLen)
            pending.removeSubrange(pending.startIndex ..< start + msgLen)

            if flags & 0b0000_0010 != 0 {
                sawConnectEndStream = true
                continuation.yield(.endStream(messageBytes))
            } else {
                continuation.yield(.message(messageBytes))
            }
        }
    }

    private func finishSuccessfully() {
        if let status, status >= 400 {
            let body = String(data: pending, encoding: .utf8) ?? ""
            finish(throwing: CursorConnectError.httpStatus(status, body))
            return
        }
        finish(throwing: nil)
    }

    private func finish(throwing error: Error?) {
        guard !finished else { return }
        finished = true
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(throwing: CursorConnectError.transport(String(describing: error)))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // The connection died without an end-of-response marker (no END_STREAM,
        // no Connect end-stream frame): the response was truncated. Reporting a
        // clean end here would silently pass off a partial message as complete.
        // (A close after the consumer already stopped reading — normal turn end
        // or user cancel — finishes a continuation nobody is reading; the
        // provider maps the cancel case to `aborted` itself.)
        if sawConnectEndStream {
            finish(throwing: nil)
        } else {
            finish(throwing: CursorConnectError.transport("connection closed before end of stream"))
        }
        context.fireChannelInactive()
    }
}
