import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Wire/transport evidence, independent of UI copy. Optional on persisted messages
/// so transcripts written before structured failures remain decodable.
public struct ProviderFailure: Error, LocalizedError, Codable, Sendable, Hashable {
    public enum Category: String, Codable, Sendable {
        case cancelled, contextOverflow, refusal, quota, authentication, invalidRequest
        case timeout, transport, rateLimit, server, unknown
    }
    public var message: String
    public var httpStatus: Int?
    public var providerCode: String?
    public var transportDomain: String?
    public var transportCode: Int?
    public var requestId: String?
    public var retryAfterMs: Double?
    public var shouldRetry: Bool?
    public var rawStopReason: String?
    public var stopDetails: JSONValue?
    public var errorDescription: String? { message }

    public init(message: String, httpStatus: Int? = nil, providerCode: String? = nil,
                transportDomain: String? = nil, transportCode: Int? = nil,
                requestId: String? = nil, retryAfterMs: Double? = nil, shouldRetry: Bool? = nil,
                rawStopReason: String? = nil, stopDetails: JSONValue? = nil) {
        self.message = message
        self.httpStatus = httpStatus
        self.providerCode = providerCode
        self.transportDomain = transportDomain
        self.transportCode = transportCode
        self.requestId = requestId
        self.retryAfterMs = retryAfterMs
        self.shouldRetry = shouldRetry
        self.rawStopReason = rawStopReason
        self.stopDetails = stopDetails
    }

    public static func capture(_ error: any Error) -> Self {
        if let failure = error as? Self { return failure }
        if let cursor = error as? CursorConnectError {
            let message = cursor.localizedDescription
            switch cursor {
            case .httpStatus(let status, let body):
                var failure = parseJSONObject(body).map { payload($0, fallback: message) } ?? Self(message: message)
                failure.httpStatus = status
                return failure
            case .grpc(let code, _): return Self(message: message, providerCode: code)
            case .tlsSetupFailed: return Self(message: message, transportDomain: NSURLErrorDomain, transportCode: -1200)
            default: return Self(message: message)
            }
        }
        if error is CancellationError { return Self(message: "Request was aborted", transportDomain: NSURLErrorDomain, transportCode: -999) }
        if case HTTPClientError.unexpectedStatus(let status, let body) = error {
            return Self(message: body, httpStatus: status)
        }
        let ns = error as NSError
        // Preserve the governing outer transport error. Only unwrap unknown
        // wrappers; a permanent TLS/cancellation error must not become retryable.
        if ns.domain != NSURLErrorDomain && ns.domain != NSPOSIXErrorDomain,
           let cause = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           cause !== ns, cause.domain == NSURLErrorDomain || cause.domain == NSPOSIXErrorDomain {
            var failure = capture(cause)
            failure.message = String(describing: error)
            return failure
        }
        return Self(message: (error as? LocalizedError)?.errorDescription ?? String(describing: error),
                    transportDomain: ns.domain, transportCode: ns.code)
    }

    /// Parse only recognized fields; never persist headers, credentials or an
    /// unrestricted response dump. A body's code/type is not the HTTP status.
    public static func payload(_ value: JSONValue, fallback: String = "Provider error") -> Self {
        guard case .object(let root) = value else { return Self(message: fallback) }
        if case .string(let message) = root["error"] { return Self(message: String(message.prefix(4096))) }
        let error: [String: JSONValue]
        if case .object(let nested) = root["error"] { error = nested } else { error = root }
        func string(_ value: JSONValue?) -> String? {
            if case .string(let text) = value { return text }
            return nil
        }
        let code = string(error["code"]) ?? string(error["type"]) ?? string(error["status"])
        var status: Int?
        for key in ["status_code", "status", "code"] {
            if case .int(let number) = error[key] ?? root[key], number >= 400, number <= 599 { status = number; break }
        }
        return Self(message: String((string(error["message"]) ?? string(root["message"]) ?? fallback).prefix(4096)),
                    httpStatus: status, providerCode: code,
                    requestId: string(root["request_id"]) ?? string(error["request_id"]))
    }

    static func http(_ response: HTTPURLResponse, body: AsyncThrowingStream<Data, Error>) async -> Self {
        var bytes = Data()
        // A truncated/broken error body must never erase an already received status.
        do {
            for try await chunk in body {
                bytes.append(contentsOf: chunk.prefix(max(0, 4096 - bytes.count)))
                if bytes.count >= 4096 { break }
            }
        } catch { /* status and headers remain authoritative */ }
        let text = String(decoding: bytes, as: UTF8.self)
        var failure = parseJSONObject(text).map { payload($0, fallback: text) }
            ?? Self(message: text.isEmpty ? "HTTP \(response.statusCode)" : text)
        failure.httpStatus = response.statusCode
        failure.requestId = response.value(forHTTPHeaderField: "x-request-id")
            ?? response.value(forHTTPHeaderField: "request-id") ?? failure.requestId
        failure.retryAfterMs = retryDelay(headers: response.allHeaderFields.reduce(into: [:]) { result, entry in
            if let key = entry.key as? String { result[key.lowercased()] = String(describing: entry.value) }
        })
        switch response.value(forHTTPHeaderField: "x-should-retry")?.lowercased() {
        case "true": failure.shouldRetry = true
        case "false": failure.shouldRetry = false
        default: break
        }
        return failure
    }

    public static func retryDelay(headers: [String: String], now: Date = Date()) -> Double? {
        let headers = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        if let value = headers["retry-after-ms"], let number = Double(value), number.isFinite, number >= 0 { return number }
        guard let value = headers["retry-after"] else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0, (seconds * 1000).isFinite { return seconds * 1000 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now) * 1000) }
    }

    public var category: Category {
        let text = [providerCode, rawStopReason, message].compactMap { $0 }.joined(separator: " ").lowercased()
        let domain = transportDomain ?? Self.match(#"\bdomain\s*=\s*(NSURLErrorDomain|NSPOSIXErrorDomain)\s+code"#, in: message)
        let code = transportCode ?? Self.match(#"\bdomain\s*=\s*(?:NSURLErrorDomain|NSPOSIXErrorDomain)\s+code\s*=\s*(-?\d+)\b"#, in: message).flatMap(Int.init)
        if domain?.lowercased() == NSURLErrorDomain.lowercased(), let code {
            if code == -999 { return .cancelled }
            if code == -1001 { return .timeout }
            return [-1003, -1004, -1005, -1006, -1009].contains(code) ? .transport : .invalidRequest
        }
        if httpStatus != 429, ProviderContextLimit.isInputOverflow(text) { return .contextOverflow }
        if ["refusal", "content_filter", "sensitive", "safety", "guardrail_intervened", "prohibited_content", "blocklist", "recitation", "spii"].contains(where: text.contains) { return .refusal }
        if ["insufficient_quota", "quota exceeded", "out of budget", "available balance", "billing",
            "monthly usage limit", "usage limit reached", "usage_limit_reached", "gousagelimiterror", "freeusagelimiterror"].contains(where: text.contains) { return .quota }
        let status = httpStatus ?? Self.legacyStatus(message)
        if status == 401 || status == 403 { return .authentication }
        if let status, (400..<500).contains(status), status != 408, status != 429 { return .invalidRequest }
        if status == 408 { return .timeout }
        if status == 429 { return .rateLimit }
        if let status, (500..<600).contains(status) { return .server }
        if domain?.lowercased() == NSPOSIXErrorDomain.lowercased(), let code {
            return [Int(ECONNRESET), Int(ECONNABORTED), Int(ENOTCONN), Int(EPIPE), Int(ETIMEDOUT), Int(ECONNREFUSED), Int(ENETUNREACH), Int(EHOSTUNREACH)].contains(code) ? .transport : .invalidRequest
        }
        if ["unauthorized", "forbidden", "invalid api key", "authentication_error", "permission_denied", "unauthenticated"].contains(where: text.contains) { return .authentication }
        if ["invalid", "validation", "bad request", "unsupported", "schema", "missing required", "not found"].contains(where: text.contains) { return .invalidRequest }
        if text.contains("timeout") || text.contains("timed out") || text.contains("deadline_exceeded") { return .timeout }
        if ["rate limit", "rate_limit", "throttlingexception", "too many requests", "resourceexhausted", "resource_exhausted", "resource exhausted"].contains(where: text.contains) { return .rateLimit }
        if ["overloaded", "internal error", "server error", "service unavailable", "bad gateway", "temporarily",
            "server_error", "internalserverexception", "serviceunavailableexception", "no_capacity", "at capacity", "insufficient capacity", "capacity exhausted",
            "you can retry your request", "try your request again", "exceeded request buffer limit"].contains(where: text.contains) { return .server }
        if ["network", "connection", "disconnect", "econnreset", "enotconn", "epipe", "broken pipe", "reset by peer",
            "socket closed", "socket error", "closed before", "closed unexpectedly", "stream stall", "fetch failed",
            "enotfound", "eai_again", "getaddrinfo", "ended without", "stream ended before", "terminated"].contains(where: text.contains) { return .transport }
        return .unknown
    }

    public var isRetryable: Bool {
        if shouldRetry == false { return false }
        switch category {
        case .timeout, .transport, .rateLimit, .server: return true
        case .unknown: return shouldRetry == true
        default: return false
        }
    }

    private static func legacyStatus(_ text: String) -> Int? {
        // Anchored/contextual statuses, never arbitrary digits in request IDs.
        match(#"(?:^\s*|\bhttp\s+|\bstatus(?:\s+code)?\s*[:=]?\s*|\breturned\s+|\bauth-gateway\s+|\bsummarization failed:\s*)([45]\d\d)\b"#, in: text).flatMap(Int.init)
    }
    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(result.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

public extension AssistantMessage {
    /// Thinking-only attempts can be replayed. Once text or tool calls escape,
    /// do not assume rewinding in-memory state reverses external effects.
    var hasReplayUnsafeContent: Bool {
        content.contains { block in
            switch block {
            case .text(let text): return !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .thinking: return false
            default: return true
            }
        }
    }

    var providerFailure: ProviderFailure? {
        failure ?? (stopReason == .error ? ProviderFailure(message: errorMessage ?? "Unknown provider error") : nil)
    }
}
