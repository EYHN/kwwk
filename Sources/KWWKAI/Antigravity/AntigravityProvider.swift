import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Streaming provider for Antigravity subscription models
/// (`api == "antigravity-codeassist"`).
///
/// An Antigravity subscription is served by Google's Code Assist backend,
/// as the Antigravity Hub is: `POST <daily>/v1internal:streamGenerateContent
/// ?alt=sse` with a Gemini request in Code Assist's envelope
/// (`AntigravityRequest`), answered as Gemini chunks each wrapped in
/// `{response}`. Ported from magpie's `gateway/codeassist.go`.
///
/// The bearer token and the Google Cloud project the login was given arrive
/// per request through `StreamOptions.resolvedAuth` (see
/// `registerAntigravity`). The Hub's version, which every request's
/// User-Agent carries, comes from `AntigravityHubVersion`.
public final class AntigravityProvider: APIProvider, @unchecked Sendable {
    public let api = AntigravityModels.api
    private let client: HTTPClient
    private let hubVersion: AntigravityHubVersion

    public init(client: HTTPClient = URLSessionHTTPClient(), hubVersion: AntigravityHubVersion = .shared) {
        self.client = client
        self.hubVersion = hubVersion
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
        let state = GoogleGeminiState(api: api, provider: model.provider, modelId: model.id)
        state.signal = options?.cancellation
        func fail(_ failure: ProviderFailure) {
            let message = Self.failed(state.snapshot(), failure)
            out.push(.error(reason: .error, error: message))
            out.end(message)
        }
        guard let token = options?.resolvedAuth?.token ?? options?.apiKey, !token.isEmpty else {
            fail(ProviderFailure(message: "Antigravity sign-in is required (run /login antigravity)"))
            return
        }
        guard case .string(let projectId)? = options?.resolvedAuth?.metadata["projectId"], !projectId.isEmpty else {
            fail(ProviderFailure(
                message: "Antigravity: the login names no Google Cloud project; sign in to Antigravity again"
            ))
            return
        }
        let messages = TransformMessages.normalize(context.messages, model: model)
        let sent = AntigravityModels.variantId(model: model, reasoning: options?.reasoning)
        let system = context.systemPrompt
        let cancellation = options?.cancellation
        do {
            let body = try AntigravityRequest.build(
                model: model,
                sent: sent,
                projectId: projectId,
                systemPrompt: system,
                messages: messages,
                tools: context.tools ?? [],
                options: options
            )
            let version = await hubVersion.current(client: client)
            var headers = Self.requestHeaders(token: token, hubVersion: version)
            for (key, value) in options?.headers ?? [:] { headers[key] = value }
            let baseURL = Self.baseURL(model: model, resolved: options?.resolvedAuth?.baseURL)
            let (response, stream) = try await client.stream(
                url: URL(string: baseURL + "/v1internal:streamGenerateContent?alt=sse")!,
                method: "POST",
                headers: headers,
                body: body,
                cancellation: cancellation
            )
            guard (200..<300).contains(response.statusCode) else {
                throw await Self.httpFailure(response: response, body: stream, model: sent, system: system)
            }
            // A web page served 200 is no reply (a proxy's, a captive portal's).
            if response.value(forHTTPHeaderField: "content-type")?.lowercased().hasPrefix("text/html") == true {
                throw ProviderFailure(message: "Antigravity answered with a web page, not an API reply", httpStatus: 502)
            }

            out.push(.start(partial: state.snapshot()))
            let driveTask = Task {
                await Self.drive(events: parseSSE(bytes: stream), state: state, out: out, system: system)
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
            if cancellation?.isCancelled == true {
                let aborted = state.asAborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
            } else {
                fail(.capture(error))
            }
        }
    }

    /// Reads the reply's chunks into `state` and returns the message it ends
    /// as. Each chunk is a Gemini chunk wrapped in `{response}`; an error
    /// comes in a shape of its own, `{error}`, and ends the reply (the
    /// refusal of a system prompt Google turns away arrives this way too,
    /// under a 200).
    private static func drive(
        events: AsyncThrowingStream<SSEMessage, Error>,
        state: GoogleGeminiState,
        out: AssistantMessageStream,
        system: String?
    ) async -> AssistantMessage {
        var rawFinishReason: String?
        var sentImage = false
        do {
            for try await sse in events {
                if state.signal?.isCancelled == true { return state.asAborted() }
                guard case .object(let envelope)? = parseJSONObject(sse.data) else { continue }
                if case .object(let error)? = envelope["error"] {
                    state.finalizeStreamingBlocks(emit: { out.push($0) })
                    return failed(state.snapshot(), streamFailure(error, system: system))
                }
                let chunk: [String: JSONValue]
                if case .object(let response)? = envelope["response"] { chunk = response } else { chunk = envelope }
                if case .object(let feedback)? = chunk["promptFeedback"],
                   case .string(let reason)? = feedback["blockReason"], reason != "BLOCK_REASON_UNSPECIFIED" {
                    state.finalizeStreamingBlocks(emit: { out.push($0) })
                    return failed(state.snapshot(), ProviderFailure(
                        message: "Antigravity: prompt blocked: \(reason)",
                        providerCode: "refusal",
                        rawStopReason: reason
                    ))
                }
                if case .object(let metadata)? = chunk["usageMetadata"] { state.applyUsage(metadata) }
                if case .string(let id)? = chunk["responseId"], state.responseId == nil { state.responseId = id }
                guard case .array(let candidates)? = chunk["candidates"], let first = candidates.first,
                      case .object(let candidate) = first else { continue }
                if case .string(let finishReason)? = candidate["finishReason"],
                   finishReason != "FINISH_REASON_UNSPECIFIED", finishReason != "NULL" {
                    rawFinishReason = finishReason
                    state.stopReason = finish(finishReason)
                    if state.stopReason == .error {
                        state.failure = ProviderFailure(
                            message: "Antigravity: finish reason \(finishReason)",
                            shouldRetry: finishReason == "MALFORMED_FUNCTION_CALL" ? true : nil,
                            rawStopReason: finishReason
                        )
                    }
                }
                guard case .object(let content)? = candidate["content"], case .array(let parts)? = content["parts"] else {
                    continue
                }
                for part in parts {
                    guard case .object(let p) = part else { continue }
                    if p["inlineData"] != nil { sentImage = true }
                    let thought: Bool = { if case .bool(let v)? = p["thought"] { return v }; return false }()
                    let signature: String? = { if case .string(let s)? = p["thoughtSignature"] { return s }; return nil }()
                    if case .string(let text)? = p["text"], !text.isEmpty {
                        if thought {
                            let (index, firstSeen) = state.noteThinkingBlock()
                            if firstSeen { out.push(.thinkingStart(contentIndex: index, partial: state.snapshot())) }
                            state.appendThinking(index: index, text: text)
                            state.setThinkingSignature(index: index, sig: signature)
                            out.push(.thinkingDelta(contentIndex: index, delta: text, partial: state.snapshot()))
                        } else {
                            let (index, firstSeen) = state.noteTextBlock()
                            if firstSeen { out.push(.textStart(contentIndex: index, partial: state.snapshot())) }
                            state.appendText(index: index, text: text)
                            state.setTextSignature(index: index, sig: signature)
                            out.push(.textDelta(contentIndex: index, delta: text, partial: state.snapshot()))
                        }
                    }
                    if case .object(let function)? = p["functionCall"] {
                        let name: String = { if case .string(let v)? = function["name"] { return v }; return "" }()
                        let arguments: JSONValue = {
                            if case .object = function["args"] ?? .null { return function["args"]! }
                            return .object([:])
                        }()
                        // Antigravity names its calls (Claude's and GPT-OSS's
                        // through it); that id is the one the call goes back by.
                        let callId: String? = {
                            if case .string(let v)? = function["id"], !v.isEmpty { return v }
                            return nil
                        }()
                        let index = state.appendToolCall(
                            id: callId,
                            name: toolName(name),
                            args: arguments,
                            signature: signature
                        )
                        out.push(.toolCallStart(contentIndex: index, partial: state.snapshot()))
                        let argumentsJSON = (try? JSONValueEncoder.encode(arguments)) ?? "{}"
                        out.push(.toolCallDelta(contentIndex: index, delta: argumentsJSON, partial: state.snapshot()))
                        let call = ToolCall(
                            id: state.toolCallId(at: index),
                            name: toolName(name),
                            arguments: arguments,
                            thoughtSignature: signature
                        )
                        out.push(.toolCallEnd(contentIndex: index, toolCall: call, partial: state.snapshot()))
                    }
                }
            }
        } catch {
            if state.signal?.isCancelled == true { return state.asAborted() }
            state.finalizeStreamingBlocks(emit: { out.push($0) })
            return failed(state.snapshot(), .capture(error))
        }
        if state.signal?.isCancelled == true { return state.asAborted() }
        state.finalizeStreamingBlocks(emit: { out.push($0) })
        if state.hasToolCalls(), state.stopReason != .error { state.stopReason = .toolUse }
        var final = state.finalize()
        if rawFinishReason == nil {
            // No closing chunk: the reply broke off, a transport failure the
            // retry policy replays, not a finished answer. A short text it
            // ended on is Google's own word on why — a retired model is
            // answered "Gemini 3.5 Flash is no longer available. Please switch
            // to Gemini 3.7 Flash in the latest version of Antigravity." and
            // nothing more — so it leads the failure's message.
            var message = "Antigravity stream ended without a finish reason"
            let text = final.content.compactMap { block -> String? in
                if case .text(let text) = block { return text.text }
                return nil
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text.count <= noticeLength {
                message = "\(text) (\(message))"
            }
            return failed(final, ProviderFailure(message: message))
        }
        if final.stopReason == .stop, !final.hasReplayUnsafeContent, !sentImage {
            // STOP with no parts, or thoughts alone, is a failed reply, not
            // an answer (magpie #667); the "ended without" wording is what the
            // retry policy replays.
            return failed(final, ProviderFailure(
                message: "Antigravity stream ended without content",
                rawStopReason: rawFinishReason
            ))
        }
        if final.stopReason == .error, let failure = state.failure {
            final.errorMessage = failure.message
            final.failure = failure
        }
        return final
    }

    /// The most text a reply that broke off is quoted in its failure: Google's
    /// notices are a sentence or two, a reply cut mid-answer is not.
    static let noticeLength = 300

    /// Gemini's own tools live in a namespace, `default_api`, and a model now
    /// and then names one of the client's with it (magpie #636): the
    /// namespace comes off a call's name.
    static func toolName(_ name: String) -> String {
        for separator in [":", "."] {
            let prefix = "default_api" + separator
            if name.hasPrefix(prefix), name.count > prefix.count { return String(name.dropFirst(prefix.count)) }
        }
        return name
    }

    static func finish(_ raw: String) -> StopReason {
        switch raw {
        case "STOP", "MODEL_STOP": return .stop
        case "MAX_TOKENS": return .length
        case "SAFETY", "PROHIBITED_CONTENT", "RECITATION", "BLOCKLIST", "SPII", "OTHER", "MALFORMED_FUNCTION_CALL":
            return .error
        default: return .stop
        }
    }

    static func failed(_ snapshot: AssistantMessage, _ failure: ProviderFailure) -> AssistantMessage {
        var message = snapshot
        message.stopReason = .error
        message.errorMessage = failure.message
        message.failure = failure
        return message
    }

    // MARK: - Request

    /// The headers the Hub sends: its token, and its own name and version.
    /// No `Accept`: the Hub sends none.
    static func requestHeaders(token: String, hubVersion: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "User-Agent": AntigravityOAuth.userAgent(version: hubVersion),
        ]
    }

    static func baseURL(model: Model, resolved: String?) -> String {
        var url = resolved ?? (model.baseURL.isEmpty ? AntigravityModels.baseURL : model.baseURL)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    // MARK: - Errors

    static func httpFailure(
        response: HTTPURLResponse,
        body: AsyncThrowingStream<Data, Error>,
        model: String,
        system: String?
    ) async -> ProviderFailure {
        let bytes = await ProviderFailure.readBoundedBody(body)
        var failure = httpFailure(status: response.statusCode, body: bytes, model: model, system: system)
        failure.retryAfterMs = ProviderFailure.retryDelay(response: response)
        failure.requestId = response.value(forHTTPHeaderField: "x-request-id") ?? failure.requestId
        return failure
    }

    /// The failure for an error Code Assist answered with, Google's
    /// `{"error": {"code", "message", "status"}}`, read by what it says.
    ///
    /// A 429 is a spent allowance (`.quota`, with the reset the message names:
    /// "You have exhausted your capacity on this model. Your quota will reset
    /// after 3h19m30s.") — unless its words are the refusal's ("Resource has
    /// been exhausted") and the system prompt carries a line Antigravity
    /// turns away (magpie #666): that is the prompt refused, not a quota,
    /// told as a refusal that is neither retried nor read as spent quota. A
    /// 404 "Requested entity was not found" is a model the account isn't
    /// served (magpie #3027).
    static func httpFailure(status: Int, body: Data, model: String, system: String?) -> ProviderFailure {
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var failure = parseJSONObject(text).map { ProviderFailure.payload($0, fallback: text) }
            ?? ProviderFailure(message: text.isEmpty ? "HTTP \(status)" : text)
        failure.httpStatus = status
        // Google's messages may end in a newline (its schema refusals do).
        let said = failure.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 429 {
            classifyExhausted(&failure, said: said, system: system)
        } else if status == 404, said.lowercased().contains("requested entity was not found") {
            failure.message = "Antigravity: this account is not served \(model) (\(said))"
        } else {
            failure.message = "Antigravity: " + said
        }
        return failure
    }

    /// The failure for an error said inside the reply, `{"error": {…}}`
    /// under a 200: the refusal and a spent allowance arrive this way too,
    /// without the 429 the body would carry.
    static func streamFailure(_ error: [String: JSONValue], system: String?) -> ProviderFailure {
        var failure = ProviderFailure.payload(.object(["error": .object(error)]), fallback: "stream error")
        let said = failure.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if AntigravityCloak.refuses(said) {
            failure.httpStatus = failure.httpStatus ?? 429
            classifyExhausted(&failure, said: said, system: system)
        } else {
            failure.message = "Antigravity: " + said
        }
        return failure
    }

    /// Reads a 429 (or its words) as the refusal or the quota it is.
    private static func classifyExhausted(_ failure: inout ProviderFailure, said: String, system: String?) {
        if AntigravityCloak.turnedAway(system: system, said: said) {
            failure.message = "Antigravity: \(said) — \(AntigravityCloak.hint(system: system))"
            failure.providerCode = "prompt_refusal"
            failure.shouldRetry = false
            return
        }
        failure.message = "Antigravity: usage limit reached: " + said
        failure.shouldRetry = false
        if let seconds = resetsAfterSeconds(said) {
            failure.resetsAt = Date().timeIntervalSince1970 + seconds
        }
    }

    /// The seconds in "Your quota will reset after 3h19m30s.", nil when the
    /// message names none.
    static func resetsAfterSeconds(_ said: String) -> Double? {
        guard let range = said.range(of: #"reset after (\d+h)?(\d+m)?(\d+(?:\.\d+)?s)?"#, options: .regularExpression) else {
            return nil
        }
        var seconds = 0.0
        var number = ""
        for character in said[range].dropFirst("reset after ".count) {
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            guard let value = Double(number) else { return nil }
            number = ""
            switch character {
            case "h": seconds += value * 3600
            case "m": seconds += value * 60
            case "s": seconds += value
            default: return nil
            }
        }
        return seconds > 0 ? seconds : nil
    }
}
