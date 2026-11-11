import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Trae's chat channel: the headers its gate reads, the body it takes and
/// the frames it answers with.
///
/// Chats go over `llm_utils_chat`, not `chat_sessions`: the latter runs the
/// model in Trae's own cloud sandbox, which executes tools itself and never
/// hands a `tool_calls` back. `llm_utils_chat` is the raw LLM proxy the
/// client's agent uses, where the caller's tools pass through and pending
/// calls stream back to the caller.
///
/// From JanXiao's provider for Apelin (owngoal-dev/Apelin#40), which chatted
/// through both builds' gates with live accounts.
enum TraeWire {
    static let appID = "6eefa01c-1036-4c7e-9ca5-d891f63bfcd8"
    /// The SOLO generation's build, which the chat gate and the directory
    /// both read. The three version values are one set: a capture showed
    /// `x-ide-version-code: 20260820`, `x-ide-version: 0.1.61` and
    /// `User-Agent: Trae/0.1.61` together are what the gate accepts, and one
    /// of them changed alone no longer matches its configuration table. The
    /// IDE generation's `3.3.x` is a different protocol line, whose
    /// directory is refused.
    static let clientVersion = "0.1.61"
    static let versionCode = 20260820

    /// The directory function a model is asked through when none listed it.
    static let defaultFunction = "solo_work_remote"

    static func chatURL(_ site: TraeSite) -> URL {
        URL(string: site.gateway + "/api/agent/v3/llm_utils_chat")!
    }

    // MARK: - Headers

    /// What the client says of the system it runs on. The requests made of
    /// the gate so far came from iOS, named as below with the device's own
    /// version; another system's version was never tried under that name, so
    /// off iOS a fixed one goes out.
    static let osVersion: String = {
        #if os(iOS)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #else
        return "iOS 18.5.0"
        #endif
    }()

    /// The headers every request carries, whatever the account.
    static func clientHeaders() -> [String: String] {
        [
            "x-plugin-channel": "icube-ai",
            "x-app-id": appID,
            "x-device-type": "ios",
            "x-device-cpu": "arm64",
            "x-os-version": osVersion,
            "x-ide-version-type": "stable",
            "x-app-version": clientVersion,
            "x-ide-version": clientVersion,
            "x-app-version-code": String(versionCode),
            "x-ide-version-code": String(versionCode),
            "request-traffic-type": "prod",
            "User-Agent": "Trae/\(clientVersion)",
        ]
    }

    /// The headers that name the account: its token in the three places the
    /// gate reads it, and the machine and device ids its sign-in registered.
    /// A login that recorded neither gets a machine id made from the
    /// account, the same one on every request.
    static func accountHeaders(token: String, credentials: OAuthCredentials) -> [String: String] {
        let userID = GateEnvelope.string(credentials.extras[TraeOAuth.userIDExtra]) ?? ""
        let machineID = GateEnvelope.string(credentials.extras[TraeOAuth.machineIDExtra])
            ?? derivedMachineID(account: userID.isEmpty ? token : userID)
        let trace = PKCE.randomHex(bytes: 16)
        return [
            "Authorization": "Cloud-IDE-JWT \(token)",
            "X-Ide-Token": token,
            "X-Cloudide-Token": token,
            "x-uid": userID,
            "x-machine-id": machineID,
            "x-device-id": GateEnvelope.string(credentials.extras[TraeOAuth.deviceIDExtra]) ?? machineID,
            "x-custom-trace-id": trace,
            "x-flow-traceparent": "04-\(trace)-\(trace.prefix(16))-01",
        ]
    }

    static func derivedMachineID(account: String) -> String {
        SHA256.hash(data: Data(account.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Request body

    /// A request body as `llm_utils_chat` takes it. Of the OpenAI body kwwk
    /// encodes, the messages, the tools and a reasoning effort are kept;
    /// everything else is the gate's own: the model's `config_name`, the
    /// directory `function` that lists it, and the scalar fields the gate
    /// reads.
    static func mend(_ root: inout [String: Any], function: String) {
        let model = root["model"] as? String ?? ""
        var body: [String: Any] = [
            "app_id": appID,
            "app_version_code": versionCode,
            "function": function,
            "model": model,
            "config_name": model,
            "stream": true,
            "messages": mendMessages(root["messages"] as? [[String: Any]] ?? []),
        ]
        if let tools = root["tools"] as? [[String: Any]], !tools.isEmpty {
            body["tools"] = mendTools(tools)
        }
        if let effort = root["reasoning_effort"] as? String, !effort.isEmpty {
            body["reasoning_effort"] = effort
        }
        root = body
    }

    /// `llm_utils_chat` takes every message's content as text blocks. The
    /// mends are the reference client's: `developer` becomes `system`; an
    /// assistant turn with neither text nor calls goes; an interrupted
    /// turn's null or empty content beside its calls becomes an empty block,
    /// which the upstream's validator accepts where it refuses null for
    /// every later request of the conversation; and `tool_calls` are named
    /// `function_call`.
    static func mendMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for var message in messages {
            if message["role"] as? String == "developer" { message["role"] = "system" }
            let calls = message["tool_calls"] as? [[String: Any]] ?? []
            let hasContent: Bool = switch message["content"] {
            case let text as String: !text.isEmpty
            case let blocks as [[String: Any]]: !blocks.isEmpty
            default: false
            }
            let isAssistant = message["role"] as? String == "assistant"
            if isAssistant, !hasContent, calls.isEmpty { continue }
            message["content"] = textBlocks(message["content"])
            message.removeValue(forKey: "reasoning_content")
            message.removeValue(forKey: "reasoning_details")
            if isAssistant, !calls.isEmpty {
                message["function_call"] = calls
                message.removeValue(forKey: "tool_calls")
            }
            out.append(message)
        }
        return out
    }

    /// A message's content as `[{type: "text", text: …}]`: a string wrapped,
    /// text blocks kept, anything else (an image, which the gate does not
    /// take) left out.
    static func textBlocks(_ content: Any?) -> [[String: Any]] {
        switch content {
        case let text as String:
            return [["type": "text", "text": text]]
        case let blocks as [[String: Any]]:
            return blocks.compactMap { block in
                guard block["type"] as? String == "text", let text = block["text"] as? String else { return nil }
                return ["type": "text", "text": text]
            }
        default:
            return [["type": "text", "text": ""]]
        }
    }

    /// `parameters` is a JSON string here, not an object.
    static func mendTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool in
            guard var function = tool["function"] as? [String: Any] else { return nil }
            if let parameters = function["parameters"], !(parameters is NSNull),
               let data = try? JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                function["parameters"] = text
            } else {
                function["parameters"] = #"{"type":"object","properties":{}}"#
            }
            return ["type": "function", "function": function]
        }
    }

    // MARK: - Response frames

    /// What one upstream frame became: the OpenAI data lines to pass on,
    /// whether it carried an answer, and whether it ended the turn.
    struct Translation {
        var lines: [Data] = []
        /// Text, thinking or tool calls the caller can read.
        var answers = false
        /// The turn is over: its finish reason or its refusal has gone out.
        var ends = false
    }

    /// One upstream SSE frame as the OpenAI data lines
    /// `OpenAICompletionsProvider` reads.
    ///
    /// Upstream is `event: output` with `{response, reasoning_content,
    /// tool_calls}`, `event: token_usage`, `event: error {code, message}` and
    /// `event: done {finish_reason}`, with no `choices` anywhere.
    static func translated(event: String, data: String) -> Translation {
        var out = Translation()
        guard let root = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else {
            return out
        }
        // A queue refusal arrives as a 200 frame carrying its own status.
        if let status = (root["statusCodeValue"] as? NSNumber)?.intValue, status != 200 {
            let body = String(describing: root["body"] ?? "")
            out.lines = [errorFrame("Trae answered \(status): \(body.prefix(240))", code: nil, status: status)]
            out.ends = true
            return out
        }
        // A frame with no event name is the gateway's default, `output`.
        switch event.isEmpty || event == "message" ? "output" : event {
        case "error":
            let code = root["code"].map { String(describing: $0) } ?? ""
            let message = root["message"] as? String ?? "unknown"
            out.lines = [errorFrame(
                "Trae \(code.isEmpty ? "error" : "code \(code)"): \(message)",
                code: code.isEmpty ? nil : code,
                status: nil
            )]
            out.ends = true
        case "token_usage":
            out.lines = [usageFrame(root)]
        case "done":
            out.lines = [finishFrame(finishReason(root["finish_reason"] as? String))]
            out.ends = true
        case "output":
            if let reasoning = root["reasoning_content"] as? String, !reasoning.isEmpty {
                out.lines.append(deltaFrame(["reasoning_content": reasoning]))
            }
            if let text = root["response"] as? String, !text.isEmpty {
                out.lines.append(deltaFrame(["content": text]))
            }
            for (position, call) in (root["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
                if let frame = toolCallFrame(call, position: position) { out.lines.append(frame) }
            }
            out.answers = !out.lines.isEmpty
        default:
            break
        }
        return out
    }

    static func finishReason(_ raw: String?) -> String {
        let reason = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        switch reason {
        case "", "stop", "end": return "stop"
        case "length", "max_tokens": return "length"
        case "tool_calls", "function_call": return "tool_calls"
        default: return reason
        }
    }

    static func toolCallFrame(_ call: [String: Any], position: Int) -> Data? {
        let function = (call["function_call"] ?? call["function"]) as? [String: Any] ?? [:]
        var fields: [String: Any] = [:]
        if let name = function["name"] as? String, !name.isEmpty { fields["name"] = name }
        if let arguments = function["arguments"] as? String, !arguments.isEmpty { fields["arguments"] = arguments }
        guard !fields.isEmpty else { return nil }
        var entry: [String: Any] = [
            "index": (call["index"] as? NSNumber)?.intValue ?? position,
            "type": "function",
            "function": fields,
        ]
        if let id = call["id"] as? String, !id.isEmpty { entry["id"] = id }
        return deltaFrame(["tool_calls": [entry]])
    }

    static func deltaFrame(_ delta: [String: Any]) -> Data {
        sseData(["choices": [["index": 0, "delta": delta, "finish_reason": NSNull()] as [String: Any]]])
    }

    static func finishFrame(_ reason: String) -> Data {
        sseData(["choices": [["index": 0, "delta": [String: Any](), "finish_reason": reason] as [String: Any]]])
    }

    static func usageFrame(_ root: [String: Any]) -> Data {
        func number(_ key: String) -> Int { (root[key] as? NSNumber)?.intValue ?? 0 }
        return sseData([
            "choices": [Any](),
            "usage": [
                "prompt_tokens": number("prompt_tokens"),
                "completion_tokens": number("completion_tokens"),
                "total_tokens": number("total_tokens"),
            ],
        ])
    }

    /// A refusal in OpenAI's shape. Trae's own code is the failure's
    /// provider code, and a status a frame carried is its HTTP status, so
    /// the failure is read as any other gateway's is.
    static func errorFrame(_ message: String, code: String?, status: Int?) -> Data {
        var error: [String: Any] = ["message": message, "type": "upstream_error"]
        if let code { error["code"] = code }
        if let status { error["status_code"] = status }
        return sseData(["error": error])
    }

    static func sseData(_ object: [String: Any]) -> Data {
        guard let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return Data("data: {}\n\n".utf8)
        }
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    static let doneFrame = Data("data: [DONE]\n\n".utf8)
}

/// Trae's transport: passes the shaped body through and rewrites the frame
/// stream into the OpenAI one `OpenAICompletionsProvider` reads.
struct TraeChatClient: HTTPClient {
    let inner: HTTPClient

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let (response, upstream) = try await inner.stream(
            url: url,
            method: method,
            headers: headers,
            body: body,
            cancellation: cancellation
        )
        // An HTTP refusal is `ProviderFailure`'s to read as it came; only a
        // stream is rewritten.
        guard response.statusCode < 400 else { return (response, upstream) }
        return (response, Self.rewritten(upstream))
    }

    /// Reads Trae's SSE and yields OpenAI data lines. A stream that ends
    /// without its `done` frame still gets a finish reason, so an answer cut
    /// short reads as `length` rather than as a finished one.
    static func rewritten(_ upstream: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var answered = false
                var ended = false
                do {
                    for try await message in parseSSE(bytes: upstream) {
                        let data = message.data.trimmingCharacters(in: .whitespaces)
                        if data.isEmpty { continue }
                        if data == "[DONE]" {
                            ended = true
                            break
                        }
                        let frame = TraeWire.translated(event: message.event, data: data)
                        for line in frame.lines { continuation.yield(line) }
                        if frame.answers { answered = true }
                        if frame.ends {
                            ended = true
                            break
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                if !ended {
                    continuation.yield(
                        answered
                            ? TraeWire.finishFrame("length")
                            : TraeWire.errorFrame("Trae ended the stream without an answer.", code: nil, status: nil)
                    )
                }
                continuation.yield(TraeWire.doneFrame)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
