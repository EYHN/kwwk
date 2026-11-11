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
    /// Bounded provider-owned diagnostic (e.g. OpenRouter metadata.raw), kept
    /// separate from display copy so a wrapper cannot hide the actual cause.
    public var upstreamMessage: String?
    /// When a spent plan or subscription window opens again, in unix
    /// seconds. Optional so values encoded before it existed still decode.
    public var resetsAt: Double?
    /// The provider's name for the spent window (Anthropic's representative
    /// claim, e.g. `five_hour`, `seven_day`).
    public var limitWindow: String?
    /// When the provider's rate-limit window reopens (ms from the failure),
    /// read from `x-ratelimit-reset*` on a 429 without Retry-After. A floor
    /// on the backoff, not a server-requested delay.
    public var rateLimitResetMs: Double?
    public var errorDescription: String? { message }

    public init(
        message: String,
        httpStatus: Int? = nil,
        providerCode: String? = nil,
        transportDomain: String? = nil,
        transportCode: Int? = nil,
        requestId: String? = nil,
        retryAfterMs: Double? = nil,
        shouldRetry: Bool? = nil,
        rawStopReason: String? = nil,
        stopDetails: JSONValue? = nil,
        upstreamMessage: String? = nil,
        resetsAt: Double? = nil,
        limitWindow: String? = nil,
        rateLimitResetMs: Double? = nil
    ) {
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
        self.upstreamMessage = upstreamMessage.map(Self.boundedDiagnostic)
        self.resetsAt = resetsAt
        self.limitWindow = limitWindow
        self.rateLimitResetMs = rateLimitResetMs
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
            case .grpc(let code, _): return Self(message: message, providerCode: Self.grpcCode(code))
            case .tlsSetupFailed: return Self(message: message, transportDomain: NSURLErrorDomain, transportCode: -1200)
            default: return Self(message: message)
            }
        }
        if error is CancellationError {
            return Self(message: "Request was aborted", transportDomain: NSURLErrorDomain, transportCode: -999)
        }
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
            failure.message = error.displayDescription
            return failure
        }
        // The message is shown to people: the error's own localized
        // description when it has one (curl's sentence, on Linux), and its
        // description when it has none. The category reads the domain and
        // code below, and that same wording.
        var message = error.displayDescription
        // Linux URLSession reports unmapped curl failures as a bare -1 whose
        // only evidence is curl's text, sometimes on the underlying error.
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorUnknown {
            let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            for detail in [ns.userInfo[NSLocalizedDescriptionKey] as? String,
                           underlying?.userInfo[NSLocalizedDescriptionKey] as? String].compactMap({ $0 })
            where !message.contains(detail) {
                message += ": \(detail)"
            }
        }
        return Self(message: message, transportDomain: ns.domain, transportCode: ns.code)
    }

    /// Parse only recognized fields; never persist headers, credentials or an
    /// unrestricted response dump. A body's code/type is not the HTTP status.
    public static func payload(
        _ value: JSONValue,
        fallback: String = "Provider error",
        now: Date = Date()
    ) -> Self {
        guard case .object(let root) = value else { return Self(message: fallback) }
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
        let metadata: [String: JSONValue]
        if case .object(let value) = error["metadata"] ?? root["metadata"] { metadata = value } else { metadata = [:] }
        let upstream: String?
        if let raw = metadata["raw"] {
            if case .string(let text) = raw { upstream = text }
            else if let data = try? JSONEncoder().encode(raw) { upstream = String(decoding: data, as: UTF8.self) }
            else { upstream = nil }
        } else { upstream = nil }
        // Codex's usage_limit_reached says when the plan window opens again,
        // as an absolute `resets_at` or a relative `resets_in_seconds`.
        func seconds(_ value: JSONValue?) -> Double? {
            switch value {
            case .int(let number): return Double(number)
            case .double(let number) where number.isFinite: return number
            case .string(let text): return Double(text).flatMap { $0.isFinite ? $0 : nil }
            default: return nil
            }
        }
        let resetsAt = seconds(error["resets_at"]).flatMap { $0 > 0 ? $0 : nil }
            ?? seconds(error["resets_in_seconds"]).flatMap { $0 >= 0 ? now.timeIntervalSince1970 + $0 : nil }
        return Self(
            message: String(
                (string(root["error"]) ?? string(error["message"]) ?? string(root["message"]) ?? fallback).prefix(4096)
            ),
            httpStatus: status,
            providerCode: code,
            requestId: string(root["request_id"]) ?? string(error["request_id"]),
            upstreamMessage: upstream,
            resetsAt: resetsAt
        )
    }

    /// The first 4096 bytes of an error body.
    static func readBoundedBody(_ body: AsyncThrowingStream<Data, Error>) async -> Data {
        var bytes = Data()
        // A truncated/broken error body must never erase an already received status.
        do {
            for try await chunk in body {
                bytes.append(contentsOf: chunk.prefix(max(0, 4096 - bytes.count)))
                if bytes.count >= 4096 { break }
            }
        } catch { /* status and headers remain authoritative */ }
        return bytes
    }

    static func http(
        _ response: HTTPURLResponse,
        body: AsyncThrowingStream<Data, Error>,
        now: Date = Date()
    ) async -> Self {
        let bytes = await readBoundedBody(body)
        let text = String(decoding: bytes, as: UTF8.self)
        var failure = parseJSONObject(text).map { payload($0, fallback: text, now: now) }
            ?? Self(message: text.isEmpty ? "HTTP \(response.statusCode)" : text)
        failure.httpStatus = response.statusCode
        failure.requestId = response.value(forHTTPHeaderField: "x-request-id")
            ?? response.value(forHTTPHeaderField: "request-id") ?? failure.requestId
        failure.retryAfterMs = retryDelay(response: response)
        if response.statusCode == 429, failure.retryAfterMs == nil {
            failure.rateLimitResetMs = rateLimitReset(headers: headerFields(response), now: now)
        }
        switch response.value(forHTTPHeaderField: "x-should-retry")?.lowercased() {
        case "true": failure.shouldRetry = true
        case "false": failure.shouldRetry = false
        default: break
        }
        failure.applyAnthropicUnifiedLimit(response)
        return failure
    }

    /// A Claude subscription whose plan window is spent answers 429 with the
    /// generic "would exceed your account's rate limit" body; only the
    /// unified rate-limit headers tell it apart from a momentary burst. Reads
    /// just these named headers and never keeps the header set.
    private mutating func applyAnthropicUnifiedLimit(_ response: HTTPURLResponse) {
        func header(_ name: String) -> String? {
            response.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespaces)
        }
        guard response.statusCode == 429,
              header("anthropic-ratelimit-unified-status")?.lowercased() == "rejected" else { return }
        // Paid overage still serving means the request can go through again;
        // the subscription is not spent.
        if let overage = header("anthropic-ratelimit-unified-overage-status")?.lowercased(),
           overage == "allowed" || overage == "allowed_warning" { return }
        providerCode = "usage_limit_reached"
        shouldRetry = false
        if let reset = header("anthropic-ratelimit-unified-reset").flatMap(Double.init), reset.isFinite, reset > 0 {
            resetsAt = reset
        }
        if let claim = header("anthropic-ratelimit-unified-representative-claim"), !claim.isEmpty {
            limitWindow = String(claim.prefix(64))
        }
    }

    public static func retryDelay(headers: [String: String], now: Date = Date()) -> Double? {
        let headers = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        if let value = headers["retry-after-ms"], let number = Double(value), number.isFinite, number >= 0 {
            return number
        }
        guard let value = headers["retry-after"] else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0, (seconds * 1000).isFinite {
            return seconds * 1000
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now) * 1000) }
    }

    static func retryDelay(response: HTTPURLResponse) -> Double? {
        retryDelay(headers: headerFields(response))
    }

    private static func headerFields(_ response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [:]) { result, entry in
            if let key = entry.key as? String { result[key] = String(describing: entry.value) }
        }
    }

    /// Milliseconds until the rate-limit window reopens, from the headers
    /// OpenAI-compatible APIs send: `x-ratelimit-reset-requests` /
    /// `x-ratelimit-reset-tokens` as a duration ("1s", "6m0s", "20ms";
    /// OpenAI, Groq, DeepSeek) and `x-ratelimit-reset` as a unix time in
    /// milliseconds (OpenRouter) or seconds, or as delta seconds. The
    /// latest of them, since a 429 does not say which window is spent.
    public static func rateLimitReset(headers: [String: String], now: Date = Date()) -> Double? {
        let headers = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        let nowMs = now.timeIntervalSince1970 * 1000
        var latest: Double?
        for name in ["x-ratelimit-reset-requests", "x-ratelimit-reset-tokens", "x-ratelimit-reset"] {
            guard let raw = headers[name]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { continue }
            let ms: Double?
            if let number = Double(raw) {
                guard number.isFinite, number >= 0 else { continue }
                if number >= 1e12 { ms = number - nowMs }
                else if number >= 1e9 { ms = number * 1000 - nowMs }
                else { ms = number * 1000 }
            } else {
                ms = durationMs(raw)
            }
            if let ms, ms.isFinite { latest = max(latest ?? 0, max(0, ms)) }
        }
        return latest
    }

    /// A Go-style duration ("1h2m3.5s", "6m0s", "250ms") in milliseconds.
    private static func durationMs(_ text: String) -> Double? {
        let units: [(String, Double)] = [("ms", 1), ("h", 3_600_000), ("m", 60_000), ("s", 1000)]
        var rest = Substring(text)
        var total = 0.0
        while !rest.isEmpty {
            let digits = rest.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
            guard let value = Double(digits), let unit = units.first(where: { rest.dropFirst(digits.count).hasPrefix($0.0) })
            else { return nil }
            total += value * unit.1
            rest = rest.dropFirst(digits.count + unit.0.count)
        }
        return total
    }

    public var category: Category {
        let status = httpStatus ?? Self.legacyStatus(message)
        // Payment/account failures cannot be repaired by replay, even when a
        // proxy includes transient transport prose or an explicit retry hint.
        if status == 402 { return .quota }
        // A provider that names spent credit by code means it under any
        // refusal status: WorkBuddy's code 14018 comes with one nobody has
        // recorded, and neither a new login nor a mended request brings
        // credit back. Moonshot's empty balance (`exceeded_current_quota_error`)
        // is named the same way.
        if let status, (400..<500).contains(status),
           ["insufficient_quota", "exceeded_current_quota_error"].contains(providerCode?.lowercased()) {
            return .quota
        }
        let text = [providerCode, rawStopReason, message, upstreamMessage]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        // The outer HTTP response governs nested transport prose. Overflow is
        // a distinct recovery only for an input rejection, never auth/limits.
        if status == 401 || status == 403 {
            // Kimi refuses an over-plan context as 401; it is an input
            // rejection, so it takes the shrinking path, not a login error.
            if ProviderContextLimit.isPlanContextLimit(text) { return .contextOverflow }
            // Kimi Code reports a spent 5-hour / weekly / monthly plan window
            // as 403 "You've reached your … usage limit". The login is fine;
            // treating it as authentication would send the user to sign in again.
            if Self.isPlanUsageLimit(text) { return .quota }
            return .authentication
        }
        if status == nil || status == 400 || status == 413,
           ProviderContextLimit.isInputOverflow(text) { return .contextOverflow }
        // Anthropic answers an API key with no credit as 400
        // invalid_request_error "Your credit balance is too low…". Kept to
        // that wording: a 400 that merely mentions billing is a bad request.
        if status == 400, text.contains("credit balance is too low") { return .quota }
        if let status, (400..<500).contains(status), status != 408, status != 429 { return .invalidRequest }
        switch providerCode?.lowercased() {
        case "canceled", "cancelled": return .cancelled
        // Cursor answers a team it does not serve in this region as
        // `unauthenticated` "This region is not yet available for your
        // team"; signing in again changes nothing.
        case "permission_denied" where text.contains("region is not yet available"),
             "unauthenticated" where text.contains("region is not yet available"): return .invalidRequest
        case "permission_denied", "unauthenticated": return .authentication
        case "invalid_argument", "not_found", "already_exists", "failed_precondition",
             "aborted", "out_of_range", "unimplemented", "data_loss": return .invalidRequest
        default: break
        }
        let domain = transportDomain
            ?? Self.match(#"\bdomain\s*=\s*(NSURLErrorDomain|NSPOSIXErrorDomain)\s+code"#, in: message)
        let code = transportCode
            ?? Self.match(
                #"\bdomain\s*=\s*(?:NSURLErrorDomain|NSPOSIXErrorDomain)\s+code\s*=\s*(-?\d+)\b"#,
                in: message
            ).flatMap(Int.init)
        if ["refusal", "content_filter", "sensitive", "safety", "guardrail_intervened", "prohibited_content", "blocklist", "recitation", "spii"].contains(where: text.contains) { return .refusal }
        if ["insufficient_quota", "out of budget", "available balance", "billing", "monthly quota", "daily quota", "insufficient credits", "credits exhausted",
            "monthly usage limit", "usage limit reached", "usage_limit_reached", "gousagelimiterror", "freeusagelimiterror",
            // Moonshot open platform 429: the account is suspended for an
            // empty balance (kimi-code #1857 captured it).
            "exceeded_current_quota_error",
            // Z.ai / Zhipu 429 code 1113: no balance or no plan behind the key.
            "insufficient balance", "no resource package", "余额不足", "请充值"].contains(where: text.contains) { return .quota }
        // Cursor's plan refusals arrive as `resource_exhausted` marked not
        // retryable ("Free plans can only use Auto…"); a bare
        // `resource_exhausted` is still a busy server.
        if providerCode?.lowercased() == "resource_exhausted", shouldRetry == false { return .quota }
        // An actual concurrency/short-window cap is backpressure, not spent
        // account credit. Match cap signals, not benign concurrency wording.
        if Self.isTransientLimit(text) { return .rateLimit }
        if text.contains("quota exceeded") { return .quota }
        if status == 408 { return .timeout }
        if status == 429 { return .rateLimit }
        if let status, (500..<600).contains(status) { return .server }
        if domain?.lowercased() == NSURLErrorDomain.lowercased(), let code {
            if code == -999 { return .cancelled }
            if code == -1001 { return .timeout }
            if code == NSURLErrorUnknown, Self.isCurlTransferInterrupted(text) { return .transport }
            // Connectivity that can come back: host lookup/connect failures,
            // a dropped connection (-1005), no network (-1009, -1018, -1020),
            // and -1011, which FoundationNetworking reports for curl's
            // "Empty reply from server" (a gateway closing an idle request).
            return [-1003, -1004, -1005, -1006, -1009, -1011, -1018, -1020].contains(code) ? .transport : .invalidRequest
        }
        if domain?.lowercased() == NSPOSIXErrorDomain.lowercased() {
            if transportDomain?.lowercased() == NSPOSIXErrorDomain.lowercased(), let code = transportCode {
                // Structured transport evidence uses the producer's native
                // errno constants. Never interpret a legacy text's number as
                // local errno: Darwin and Linux assign different values.
                return [
                    Int(ECONNRESET), Int(ECONNABORTED), Int(ENOTCONN), Int(EPIPE),
                    Int(ETIMEDOUT), Int(ECONNREFUSED), Int(ENETUNREACH), Int(EHOSTUNREACH)
                ].contains(code) ? .transport : .invalidRequest
            }
            // Legacy diagnostics can cross platform boundaries. Require a
            // specific socket failure, not a bare number or generic "network".
            if ["permission denied", "operation not permitted", "invalid", "unsupported", "not supported", "not found"].contains(where: text.contains) { return .invalidRequest }
            if ["connection reset", "connection aborted", "socket is not connected", "transport endpoint is not connected",
                "broken pipe", "connection timed out", "operation timed out", "connection refused", "network is unreachable",
                "host is unreachable", "no route to host"].contains(where: text.contains) { return .transport }
            return .unknown
        }
        switch providerCode?.lowercased() {
        case "deadline_exceeded": return .timeout
        case "resource_exhausted": return .rateLimit
        case "unavailable", "internal": return .server
        default: break
        }
        if ["unauthorized", "forbidden", "invalid api key", "authentication_error", "permission_denied", "unauthenticated"].contains(where: text.contains) { return .authentication }
        if ["invalid", "validation", "bad request", "unsupported", "schema", "missing required", "not found"].contains(where: text.contains) { return .invalidRequest }
        if text.contains("timeout") || text.contains("timed out") || text.contains("deadline_exceeded") {
            return .timeout
        }
        if ["rate limit", "rate_limit", "throttlingexception", "too many requests", "resourceexhausted", "resource_exhausted", "resource exhausted"].contains(where: text.contains) { return .rateLimit }
        if ["overloaded", "internal error", "internal_error", "server error", "service unavailable", "service_unavailable", "bad gateway", "temporarily",
            "server_error", "internalserverexception", "serviceunavailableexception", "no_capacity", "at capacity", "insufficient capacity", "capacity exhausted",
            "you can retry your request", "please retry your request", "try your request again", "exceeded request buffer limit"].contains(where: text.contains) { return .server }
        if ["network", "connection", "disconnect", "econnreset", "enotconn", "epipe", "broken pipe", "reset by peer",
            "socket closed", "socket error", "socket hang up", "other side closed", "reset before headers", "http2 request did not get a response", "closed before", "closed unexpectedly", "stream stall", "fetch failed",
            "enotfound", "eai_again", "getaddrinfo", "ended without", "stream ended before", "terminated",
            // Gateway / proxy stream drops (pi retry.ts:55-63, omp
            // error/flags.ts STREAM_DROP_PATTERN). OpenRouter's mid-stream
            // error chunk reads "Upstream response stream was interrupted".
            "stream was interrupted", "stream interrupted", "upstream_stream_read_error",
            "unable to forward upstream", "upstream request failed", "upstream_request_failed",
            "http/2 stream failed", "http2 stream failed", "stream disconnected before completion",
            "pending stream has been canceled"].contains(where: text.contains) { return .transport }
        return .unknown
    }

    // gRPC trailers use numbers; Connect end-streams use the equivalent names.
    // Normalize only at the gRPC boundary, never arbitrary provider/HTTP codes.
    private static func grpcCode(_ raw: String) -> String {
        let names = ["ok", "cancelled", "unknown", "invalid_argument", "deadline_exceeded", "not_found",
                     "already_exists", "permission_denied", "resource_exhausted", "failed_precondition",
                     "aborted", "out_of_range", "unimplemented", "internal", "unavailable", "data_loss",
                     "unauthenticated"]
        if let index = Int(raw), names.indices.contains(index) { return names[index] }
        return raw.lowercased()
    }

    /// curl's own wording for a connection that dropped mid-response
    /// (CURLE_PARTIAL_FILE, an HTTP/2 stream reset). FoundationNetworking has
    /// no URLError for these and surfaces them as NSURLErrorUnknown.
    private static func isCurlTransferInterrupted(_ text: String) -> Bool {
        ["transfer closed with", "was not closed cleanly", "stream error in the http/2 framing layer",
         // CURLE_GOT_NOTHING, and CURLE_RECV_ERROR / CURLE_SEND_ERROR
         // without ECONNRESET (which maps to -1005).
         "empty reply from server", "recv failure", "send failure"]
            .contains(where: text.contains)
    }

    /// What a failure means for the person who hit it, in terms a host can
    /// show and act on without knowing any provider's wire. kwwk owns every
    /// provider quirk that decides this (Kimi's over-plan 401 is a context
    /// limit, its spent plan window a quota, xAI's and Kiro's 403 a refused
    /// login, Anthropic's organization 403 an account limit, Cursor's region
    /// refusal a rejected request); a host maps these cases to its own copy
    /// and never reads statuses or provider codes itself.
    public enum Outcome: String, Codable, Sendable, CaseIterable {
        /// The provider refused the login itself: sign in again.
        case signInRequired
        /// Signed in, but this account may not do this (plan, organization
        /// policy, model entitlement). Signing in again does not help.
        case accessDenied
        /// The account's allowance or credit is spent.
        case quotaExhausted
        /// A short-window limit; asking again later works.
        case rateLimited
        /// The conversation is too long for the model or the plan.
        case contextTooLong
        /// The provider refused this request as made.
        case requestRejected
        /// The provider is down or overloaded.
        case serviceUnavailable
        case timeout
        /// The connection to the provider failed.
        case network
        /// The provider declined the content.
        case contentRefused
        case cancelled
        case unknown
    }

    /// Conservative on purpose, since a host turns it into a sentence the
    /// user acts on: prose alone (no status, code, stop reason or transport
    /// code) names no cause; a 5xx is the provider's outage whatever code
    /// rides along (504 a timeout); and transport evidence alone only says
    /// network, timeout or cancelled. `category` stays the retry signal.
    public var outcome: Outcome {
        if httpStatus == nil, providerCode == nil, rawStopReason == nil, transportCode == nil { return .unknown }
        if let status = httpStatus, (500...599).contains(status) { return status == 504 ? .timeout : .serviceUnavailable }
        if httpStatus == nil, providerCode == nil, rawStopReason == nil {
            switch category {
            case .transport: return .network
            case .timeout: return .timeout
            case .cancelled: return .cancelled
            default: return .unknown
            }
        }
        return switch category {
        case .authentication: isCredentialRejection ? .signInRequired : .accessDenied
        case .contextOverflow: .contextTooLong
        case .quota: .quotaExhausted
        case .rateLimit: .rateLimited
        case .invalidRequest: .requestRejected
        case .server: .serviceUnavailable
        case .timeout: .timeout
        case .transport: .network
        case .refusal: .contentRefused
        case .cancelled: .cancelled
        case .unknown: .unknown
        }
    }

    /// Whether this failure says the credential itself was refused, so that
    /// renewing the login could help. Narrower than `.authentication`: a 401
    /// or a gRPC `unauthenticated` is a refused credential, but a 403 (or
    /// `permission_denied`, or an auth word in bare text) is believed only
    /// with evidence about the token, and never when it names a policy. A
    /// 403 for a model the plan lacks, an organization that disallows OAuth,
    /// or a region is about the account, and renewing the login there would
    /// only spend a refresh, or tell the user to sign in for nothing.
    /// xAI and Kiro do refuse a bad token with 403, hence the evidence check
    /// instead of excluding 403 outright.
    public var isCredentialRejection: Bool {
        guard category == .authentication else { return false }
        let status = httpStatus ?? Self.legacyStatus(message)
        let code = providerCode?.lowercased()
        if status == 401 || (status == nil && code == "unauthenticated") { return true }
        let text = [providerCode, rawStopReason, message, upstreamMessage].compactMap { $0 }.joined(separator: " ").lowercased()
        let policy = ["not allowed", "not supported", "not available", "not enabled", "does not have access", "do not have access",
                      "doesn't have access", "your plan", "upgrade", "region", "country", "subscription"]
        if policy.contains(where: text.contains) { return false }
        let credential = ["unauthenticated", "unauthorized", "bad-credentials", "bad credentials", "invalid_token", "invalid token",
                          "token is invalid", "token_expired", "token expired", "token has expired", "expired token", "expiredtoken",
                          "could not be validated", "invalid api key", "invalid_api_key", "invalid authentication",
                          "invalid_authentication", "authentication_error", "authentication failed", "authentication token",
                          "access token", "bearer token", "security token", "revoked", "unrecognizedclient"]
        return credential.contains(where: text.contains)
    }

    /// Plan-window exhaustion wording delivered on 401/403 (Kimi Code:
    /// https://www.kimi.com/code/docs/en/kimi-code/error-reference.html).
    /// Concurrency caps on 403 are not included: they are not spent quota.
    static func isPlanUsageLimit(_ text: String) -> Bool {
        guard !text.contains("concurrent request limit") else { return false }
        return Self.match(#"\b(reached your [a-z0-9() -]{0,40}usage limit)\b"#, in: text) != nil
            || text.contains("quota will reset")
            || text.contains("quota will be refreshed")
    }

    private static func isTransientLimit(_ text: String) -> Bool {
        let patterns = [
            #"\bconcurren\w*\b[^\n]{0,60}\b(?:limit|quota|exceed\w*|reach\w*)\b"#,
            #"\b(?:limit|quota|exceed\w*|reach\w*)\b[^\n]{0,60}\bconcurren\w*\b"#,
            #"\btoo many\s+concurren\w*\s+(?:requests?|invocations?)\b"#,
            #"\b(?:rate|quota|limit)\b[^\n]{0,80}\bper (?:second|minute)\b"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func boundedDiagnostic(_ input: String) -> String {
        var text = String(input.prefix(4096))
        for pattern in [#"(?i)\bbearer\s+[A-Za-z0-9._~+/-]+=*"#,
                        #"(?i)\"(?:authorization|api[_-]?key|access[_-]?token|refresh[_-]?token)\"\s*:\s*\"[^\"]*(?:\"|$)"#] {
            text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return text
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

extension AssistantMessage {
    static func makeError(
        api: String,
        model: Model,
        text: String,
        failure: ProviderFailure? = nil
    ) -> AssistantMessage {
        AssistantMessage(
            content: [],
            api: api,
            provider: model.provider,
            model: model.id,
            usage: Usage(),
            stopReason: .error,
            errorMessage: text,
            failure: failure ?? ProviderFailure(message: text),
            timestamp: Timestamp.now()
        )
    }

    static func makeAborted(api: String, model: Model) -> AssistantMessage {
        AssistantMessage(
            content: [],
            api: api,
            provider: model.provider,
            model: model.id,
            usage: Usage(),
            stopReason: .aborted,
            errorMessage: "Request was aborted",
            timestamp: Timestamp.now()
        )
    }
}
