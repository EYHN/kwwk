import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Streaming provider for Kiro subscription models (`api == "kiro-assistant"`).
///
/// A Kiro subscription is served through Kiro's own API, the one kiro-cli
/// talks to (CodeWhisperer / Q Developer's `generateAssistantResponse`): each
/// request is sent whole as a conversation (`KiroRequest`) and the reply
/// comes back as an AWS event stream (`KiroReply`). Tools are ordinary
/// client-side tool calls. Ported from magpie's `gateway/kiro.go`.
///
/// The bearer token, the account's profile ARN and the region its API is in
/// arrive per request through `StreamOptions.resolvedAuth` (see
/// `registerKiro`).
public final class KiroProvider: APIProvider, @unchecked Sendable {
    public let api = KiroModels.api
    private let client: HTTPClient

    public init(client: HTTPClient = URLSessionHTTPClient()) {
        self.client = client
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        Task.detached { [self] in
            await run(out: out, model: model, context: context, options: options)
        }
        return out
    }

    // MARK: - Run

    private func run(out: AssistantMessageStream, model: Model, context: Context, options: StreamOptions?) async {
        let messages = TransformMessages.normalize(context.messages, model: model)
        let tools = context.tools ?? []
        let reply = KiroReply(
            api: api,
            model: model,
            thinking: KiroRequest.thinks(model: model, reasoning: options?.reasoning),
            toolNames: KiroRequest.toolNames(tools: tools, messages: messages)
        )
        guard let token = options?.resolvedAuth?.token ?? options?.apiKey, !token.isEmpty else {
            let message = reply.failed(ProviderFailure(message: "Kiro sign-in is required (run /login kiro)"))
            out.push(.error(reason: .error, error: message))
            out.end(message)
            return
        }
        let cancellation = options?.cancellation
        do {
            var profileArn: String?
            if case .string(let profile)? = options?.resolvedAuth?.metadata["profileArn"] { profileArn = profile }
            let body = try KiroRequest.build(
                model: model,
                systemPrompt: context.systemPrompt,
                messages: messages,
                tools: tools,
                profileArn: profileArn,
                reasoning: options?.reasoning
            )
            var headers = Self.requestHeaders(token: token)
            for (key, value) in options?.headers ?? [:] { headers[key] = value }
            let baseURL = Self.baseURL(model: model, resolved: options?.resolvedAuth?.baseURL)
            // The base follows the region the stored login names. One that
            // gives no URL fails the turn rather than ending the process.
            guard let url = URL(string: baseURL + "/generateAssistantResponse") else {
                throw ProviderFailure(message: "The Kiro login names a region that is not one; sign in again")
            }
            let (response, stream) = try await client.stream(
                url: url,
                method: "POST",
                headers: headers,
                body: body,
                cancellation: cancellation
            )
            guard (200..<300).contains(response.statusCode) else {
                throw await Self.httpFailure(response: response, body: stream)
            }
            // A web page served 200 is no reply (a proxy's, a captive portal's).
            if response.value(forHTTPHeaderField: "content-type")?.lowercased().hasPrefix("text/html") == true {
                throw ProviderFailure(message: "Kiro answered with a web page, not an API reply", httpStatus: 502)
            }

            out.push(.start(partial: reply.snapshot()))
            let driveTask = Task {
                await Self.drive(body: stream, reply: reply, out: out, cancellation: cancellation)
            }
            let cancelRegistration = cancellation?.onCancel { _ in driveTask.cancel() }
            defer { cancelRegistration?.cancel() }
            let final = await driveTask.value
            if final.stopReason == .error || final.stopReason == .aborted {
                out.push(.error(reason: final.stopReason, error: final))
            } else {
                out.push(.done(reason: final.stopReason, message: final))
            }
            out.end(final)
        } catch {
            let message = cancellation?.isCancelled == true ? reply.aborted() : reply.failed(.capture(error))
            out.push(.error(reason: message.stopReason, error: message))
            out.end(message)
        }
    }

    /// Reads the reply's frames into `reply` and returns the message it ends
    /// as.
    ///
    /// Kiro's stream has no closing event, so a reply cut off shows only in
    /// its framing: bytes that stop inside a frame, or no frame at all. Both
    /// fail the turn as retryable transport errors, as magpie's `decodeKiro`
    /// ("the reply broke off") and `notAnAPIReply` do, instead of passing for
    /// a finished answer.
    private static func drive(
        body: AsyncThrowingStream<Data, Error>,
        reply: KiroReply,
        out: AssistantMessageStream,
        cancellation: CancellationHandle?
    ) async -> AssistantMessage {
        var reply = reply
        var decoder = AWSEventStreamDecoder(maxFrameLength: maxFrameLength)
        do {
            for try await chunk in body {
                if cancellation?.isCancelled == true { return reply.aborted() }
                for frame in try decoder.append(chunk) {
                    try reply.apply(frame, emit: { out.push($0) })
                }
            }
            if cancellation?.isCancelled == true { return reply.aborted() }
            if decoder.isMidFrame {
                throw ProviderFailure(message: "Kiro stream ended before its last frame was complete")
            }
            if reply.frames == 0 {
                throw ProviderFailure(message: "Kiro stream ended before any reply frame (empty reply)")
            }
            return reply.finish(emit: { out.push($0) })
        } catch {
            if cancellation?.isCancelled == true { return reply.aborted() }
            reply.close(emit: { out.push($0) })
            return reply.failed(.capture(error))
        }
    }

    /// The longest frame a reply may hold, as magpie's `readKiroFrame` takes
    /// it: a call's arguments can arrive as one object in one frame.
    static let maxFrameLength = 16 << 20

    // MARK: - Request

    /// The headers kiro-cli's own client sends (its AWS SDK for Rust build),
    /// with a fresh invocation id per request.
    static func requestHeaders(token: String) -> [String: String] {
        let userAgent = "aws-sdk-rust/1.0.0 ua/2.1 os/other lang/rust api/codewhispererstreaming#1.28.3 m/E "
            + "app/AmazonQ-For-CLI md/appVersion-1.28.3-"
            + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "Accept": "application/vnd.amazon.eventstream",
            "x-amzn-codewhisperer-optout": "true",
            "amz-sdk-invocation-id": UUID().uuidString.lowercased(),
            "amz-sdk-request": "attempt=1; max=1",
            "x-amzn-kiro-agent-mode": "vibe",
            "x-amz-user-agent": userAgent,
            "User-Agent": userAgent,
        ]
    }

    static func baseURL(model: Model, resolved: String?) -> String {
        var url = resolved ?? (model.baseURL.isEmpty ? KiroModels.runtimeURL(region: "us-east-1") : model.baseURL)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    // MARK: - Errors

    static func httpFailure(
        response: HTTPURLResponse,
        body: AsyncThrowingStream<Data, Error>
    ) async -> ProviderFailure {
        let bytes = await ProviderFailure.readBoundedBody(body)
        var failure = httpFailure(status: response.statusCode, body: bytes)
        failure.retryAfterMs = ProviderFailure.retryDelay(response: response)
        return failure
    }

    /// The failure for an error Kiro answered with, `{"message": "...",
    /// "reason": "..."}`, under the status the rest of kwwk reads it by
    /// (magpie `kiroFailure`): a conversation that no longer fits is a 400
    /// worded as an input overflow, a model out of capacity a 503, and a
    /// spent allowance — which Kiro answers 402 or 429 — a 429 worded as a
    /// usage limit.
    static func httpFailure(status: Int, body: Data) -> ProviderFailure {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let reason = object?["reason"] as? String ?? ""
        var message = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let said = object?["message"] as? String, !said.isEmpty {
            message = reason.isEmpty ? said : "\(said) (\(reason))"
        }
        if message.isEmpty { message = "HTTP \(status)" }
        var status = status
        if message.contains("CONTENT_LENGTH_EXCEEDS_THRESHOLD") || message.lowercased().contains("input is too long") {
            status = 400
            message = "input is too long for the model's context: " + message
        } else if message.contains("INSUFFICIENT_MODEL_CAPACITY") {
            status = 503
        } else if saysUsageLimit(message) {
            status = 429
            message = "usage limit reached: " + message
        }
        return ProviderFailure(
            message: "Kiro: " + message,
            httpStatus: status,
            providerCode: reason.isEmpty ? nil : reason
        )
    }

    /// Whether an error's words name a spent allowance: Kiro's reasons for
    /// one, whichever status or exception carries them.
    static func saysUsageLimit(_ message: String) -> Bool {
        message.contains("MONTHLY_REQUEST_COUNT") || message.contains("USAGE_LIMIT")
    }
}
