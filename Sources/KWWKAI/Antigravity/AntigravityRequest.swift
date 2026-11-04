import Crypto
import Foundation

/// The body of a `streamGenerateContent` call on Code Assist, ported from
/// magpie's `buildCodeAssistSent` and `codeAssistEnvelope`
/// (gateway/codeassist.go, provider/google.go).
///
/// Code Assist takes a Gemini request wrapped in an envelope — `{model,
/// project, request}` — and Antigravity's own ids beside it. The request is
/// Gemini's, shaped as Antigravity needs it: tool-call ids of its charset,
/// `functionResponse` under the `result` key, a Claude model's calls each
/// carrying the stand-in thought signature and its calls checked against
/// the schema, a history that neither opens nor closes on the model's turn,
/// schemas cut to the subset its declarations take, and a second answer to
/// one call dropped.
enum AntigravityRequest {
    /// Stands in for a thought signature on a function call Gemini did not
    /// sign here: Google checks the ones Gemini 3 hands out, and this one
    /// tells it not to.
    static let skipThoughtSignature = "skip_thought_signature_validator"
    /// The user turn put before a history that opens with the model's: Gemini
    /// turns one away ("function call turn comes immediately after a user
    /// turn"), and Gemini CLI's `hardenHistory` puts this one before it.
    static let continuingText = "[Continuing from previous AI thoughts...]"
    /// The user turn put after a history that ends with the model's:
    /// "Requests ending with a model turn are not supported".
    static let continueText = "Continue."
    /// What Antigravity's envelope names itself.
    static let userAgentField = "antigravity"
    static let requestType = "agent"

    // MARK: - Ids and names

    /// A tool call's id as Antigravity takes one, `^[A-Za-z0-9_-]{1,64}$`
    /// (Claude behind Code Assist refuses any other): every other character
    /// an underscore, and an id longer than 64 (OpenAI Responses'
    /// `call_…|fc_…`) cut to its first 47 and a hash of the whole, so two
    /// long ids that begin alike stay apart and a call and its result still
    /// meet (pi and oh-my-pi cap at 64 too).
    static func toolID(_ id: String) -> String {
        let sanitized = String(String.UnicodeScalarView(id.unicodeScalars.map { scalar in
            let allowed = ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-"
            return allowed ? scalar : "_"
        }))
        guard sanitized.count > maxToolIDLength else { return sanitized }
        let digest = Array(SHA256.hash(data: Data(id.utf8))).prefix(8).map { String(format: "%02x", $0) }.joined()
        return String(sanitized.prefix(maxToolIDLength - 1 - digest.count)) + "_" + digest
    }

    static let maxToolIDLength = 64

    static func isClaude(_ id: String) -> Bool { id.lowercased().contains("claude") }
    static func isGPTOSS(_ id: String) -> Bool { id.lowercased().hasPrefix("gpt-oss") }

    /// The generation of a Gemini id (`gemini-3.8-flash` is 3), 0 for an id
    /// that names none. From Gemini 3 a model is told a thinking level;
    /// Gemini 4 turns a budget away.
    static func geminiGeneration(_ id: String) -> Int {
        let lower = id.lowercased()
        guard let range = lower.range(of: #"(?:^|/)gemini-(\d+)"#, options: .regularExpression) else { return 0 }
        let digits = lower[range].reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits)) ?? 0
    }

    // MARK: - Thinking

    /// How long Claude may think at a level (magpie `budgetOf`): a level it
    /// isn't told is medium's.
    static func claudeBudget(_ reasoning: ReasoningLevel?) -> Int {
        switch reasoning {
        case .minimal, .low: return 4096
        case .medium, nil: return 10_000
        case .high: return 24_000
        case .xhigh, .max: return 32_000
        }
    }

    /// How hard the model should think (magpie `thinkingConfig`): a level for
    /// Gemini 3 and later, a budget for Claude. A model that doesn't think
    /// (GPT-OSS, a Claude whose id doesn't say thinking) gets none, and one
    /// whose id already says its level (`said`: Antigravity's
    /// `gemini-3.8-flash-low`) is told that level and no other — the effort
    /// asked for picked that id. Told no level, Antigravity's variants all
    /// but stop thinking once the request has tools (magpie #636). A Gemini
    /// asked no level and saying none thinks as it likes; Claude asked to
    /// think still has to be told how much.
    ///
    /// Gemini 3's levels: medium goes as medium to Flash and up to high to
    /// Pro, which took low and high only; a later Gemini takes the medium it
    /// was asked. Minimal goes only to a Flash variant that says it; asked
    /// otherwise it goes at low, which every Gemini 3 text model takes.
    static func thinkingConfig(
        sent: String,
        reasoning: ReasoningLevel?,
        said: ModelThinkingLevel?,
        requestedMaxTokens: Int?
    ) -> (config: [String: Any]?, claudeBudget: Int?) {
        let lower = sent.lowercased()
        let claude = isClaude(sent)
        if isGPTOSS(sent) || (claude && !lower.contains("thinking")) { return (nil, nil) }
        if reasoning == nil, said == nil, !claude { return (nil, nil) }
        var config: [String: Any] = ["includeThoughts": true]
        let generation = geminiGeneration(sent)
        if generation >= 3 || lower.hasPrefix("gemini-pro-agent") {
            if let effort = said ?? reasoning.map(ModelThinkingLevel.init(reasoning:)) {
                let flash = lower.contains("flash")
                let level: String
                switch effort {
                case .low: level = "low"
                case .minimal: level = said != nil && flash ? "minimal" : "low"
                case .medium: level = flash || generation > 3 ? "medium" : "high"
                case .off, .high, .xhigh, .max: level = "high"
                }
                config["thinkingLevel"] = level
            }
            return (config, nil)
        }
        var budget = claudeBudget(reasoning)
        if claude, let requested = requestedMaxTokens, requested > 0, budget >= requested {
            // Claude's answer has to have room past its thinking.
            budget = requested - 1
            if budget < 1024 { return (nil, nil) }
        }
        config["thinkingBudget"] = budget
        return (config, claude ? budget : nil)
    }

    // MARK: - Build

    /// The envelope for one turn: `model` is the catalog row, `sent` the id
    /// the request goes out under (`AntigravityModels.variantId`).
    static func build(
        model: Model,
        sent: String,
        projectId: String,
        systemPrompt: String?,
        messages: [Message],
        tools: [Tool],
        options: StreamOptions?
    ) throws -> Data {
        let claude = isClaude(sent)
        var contents = Self.contents(messages: messages, model: model, claude: claude)
        if contents.first?["role"] as? String == "model" {
            contents.insert(["role": "user", "parts": [["text": continuingText]]], at: 0)
        }
        if contents.last?["role"] as? String == "model" {
            contents.append(["role": "user", "parts": [["text": continueText]]])
        }
        var request: [String: Any] = ["contents": contents]
        if let system = systemPrompt, !system.isEmpty {
            // The lines Google turns away, broken up (AntigravityCloak).
            request["systemInstruction"] = ["role": "user", "parts": [["text": AntigravityCloak.cloak(system)]]]
        }

        var sendsTools = !tools.isEmpty
        if case .none? = options?.toolChoice { sendsTools = false }
        if sendsTools {
            request["tools"] = [["functionDeclarations": tools.map(declaration)]]
            var functionCalling: [String: Any] = ["mode": "AUTO"]
            switch options?.toolChoice {
            case .required?:
                functionCalling["mode"] = "ANY"
            case .tool(let name)?:
                functionCalling["mode"] = "ANY"
                functionCalling["allowedFunctionNames"] = [name]
            default:
                // Antigravity's Claude wants its calls checked against the schema.
                if claude { functionCalling["mode"] = "VALIDATED" }
            }
            request["toolConfig"] = ["functionCallingConfig": functionCalling]
        }

        var generation: [String: Any] = [:]
        if let temperature = options?.temperature { generation["temperature"] = temperature }
        let requested = options?.maxTokens.flatMap { $0 > 0 ? OutputTokenPolicy.effectiveLimit(for: model, requested: $0) : nil }
        let thinking = thinkingConfig(
            sent: sent,
            reasoning: options?.reasoning,
            said: AntigravityModels.levelSaid(by: sent, model: model),
            requestedMaxTokens: requested
        )
        // Only Claude is told how long its answer may be: it has to have room
        // past its thinking. Antigravity's Gemini is left to its own.
        if claude {
            if let requested {
                generation["maxOutputTokens"] = requested
            } else if let budget = thinking.claudeBudget {
                generation["maxOutputTokens"] = budget + 32_000
            } else if let limit = OutputTokenPolicy.effectiveLimit(for: model, requested: nil) {
                generation["maxOutputTokens"] = limit
            }
        }
        if let config = thinking.config { generation["thinkingConfig"] = config }
        if !generation.isEmpty { request["generationConfig"] = generation }
        request["sessionId"] = sessionId(contents: contents)

        let envelope: [String: Any] = [
            "model": sent,
            "project": projectId,
            "request": request,
            "userAgent": userAgentField,
            "requestType": requestType,
            "requestId": "agent-" + randomToken(bytes: 12),
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// One of the request's function declarations: the schema cut to the
    /// subset Antigravity takes; a tool with none takes an empty object's.
    static func declaration(_ tool: Tool) -> [String: Any] {
        var out: [String: Any] = ["name": tool.name]
        if !tool.description.isEmpty { out["description"] = tool.description }
        let schema = tool.parameters == .null ? AntigravitySchema.emptyObject : tool.parameters
        out["parameters"] = anyFromJSONValue(AntigravitySchema.plain(schema)) ?? [:] as Any
        return out
    }

    // MARK: - Contents

    /// kwwk's transcript as Gemini's turns.
    ///
    /// A tool's result goes back under `result`, named by its call's id; its
    /// images follow its response, as Gemini CLI sends a file it read. The
    /// user's own words go in a turn of their own after the tools' responses:
    /// Gemini answers a turn mixing a `functionResponse` with text "Requests
    /// ending with a model turn are not supported" (magpie #1533). Antigravity
    /// hands a Claude model the turn back as Anthropic blocks, where an image
    /// between two responses splits them from their calls ("tool_use ids were
    /// found without tool_result blocks immediately after"): there the images
    /// wait until every response is in, each after a line saying whose it is,
    /// and what the user said stays in that one turn, the tool_result turn
    /// Anthropic reads it as. Thinking isn't sent back: its signatures belong
    /// to whoever made them, and Google turns away ones it didn't.
    static func contents(messages: [Message], model: Model, claude: Bool) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var names: [String: String] = [:]
        /// A Claude model's tool images, held until the run of responses ends.
        var held: [[String: Any]] = []

        func hasResponse(_ parts: [[String: Any]]) -> Bool {
            parts.contains { $0["functionResponse"] != nil }
        }
        func append(role: String, parts: [[String: Any]]) {
            guard !parts.isEmpty else { return }
            if var last = out.last, last["role"] as? String == role, let lastParts = last["parts"] as? [[String: Any]],
               role != "user" || claude || hasResponse(lastParts) == hasResponse(parts) {
                last["parts"] = lastParts + parts
                out[out.count - 1] = last
            } else {
                out.append(["role": role, "parts": parts])
            }
        }
        func releaseHeld() {
            guard !held.isEmpty else { return }
            append(role: "user", parts: held)
            held = []
        }
        func image(_ image: ImageContent) -> [String: Any]? {
            guard !image.data.isEmpty else { return nil }
            return ["inlineData": ["mimeType": image.mimeType, "data": image.data]]
        }

        for message in dropSecondAnswers(messages) {
            switch message {
            case .system:
                continue
            case .user(let user):
                releaseHeld()
                append(role: "user", parts: user.content.compactMap { block in
                    switch block {
                    case .text(let text): return text.text.isEmpty ? nil : ["text": text.text]
                    case .image(let content): return image(content)
                    }
                })
            case .assistant(let assistant):
                releaseHeld()
                // Gemini's signatures go back as it gave them, to the model
                // that made them; another's are not sent.
                let own = assistant.api == model.api && assistant.provider == model.provider
                func signature(_ value: String?) -> String? {
                    guard own, !claude, let value, GoogleGeminiProvider.isValidThoughtSignature(value) else { return nil }
                    return value
                }
                // A step Gemini signed, whose later calls go without, as
                // Gemini signs the first (magpie #1445).
                let signed = assistant.content.contains {
                    if case .toolCall(let call) = $0 { return signature(call.thoughtSignature) != nil }
                    return false
                }
                var parts: [[String: Any]] = []
                for block in assistant.content {
                    switch block {
                    case .text(let text):
                        let textSignature = signature(text.textSignature)
                        guard !text.text.isEmpty || textSignature != nil else { continue }
                        var part: [String: Any] = ["text": text.text]
                        if let textSignature { part["thoughtSignature"] = textSignature }
                        parts.append(part)
                    case .toolCall(let call):
                        names[call.id] = call.name
                        var function: [String: Any] = [
                            "name": call.name,
                            "args": anyFromJSONValue(call.arguments.objectValue == nil ? .object([:]) : call.arguments) ?? [:] as Any,
                        ]
                        let id = toolID(call.id)
                        if !id.isEmpty { function["id"] = id }
                        var part: [String: Any] = ["functionCall": function]
                        if claude {
                            part["thoughtSignature"] = skipThoughtSignature
                        } else if let own = signature(call.thoughtSignature) {
                            part["thoughtSignature"] = own
                        } else if !signed {
                            part["thoughtSignature"] = skipThoughtSignature
                        }
                        parts.append(part)
                    case .thinking, .fallback:
                        break
                    }
                }
                append(role: "model", parts: parts)
            case .toolResult(let result):
                var name = names[result.toolCallId] ?? result.toolName
                if name.isEmpty { name = "tool" }
                var text = result.content.compactMap { block -> String? in
                    if case .text(let text) = block { return text.text }
                    return nil
                }.joined(separator: "\n")
                if result.isError { text = "Error: " + text }
                var response: [String: Any] = ["name": name, "response": ["result": text]]
                let id = toolID(result.toolCallId)
                if !id.isEmpty { response["id"] = id }
                var parts: [[String: Any]] = [["functionResponse": response]]
                let images = result.content.compactMap { block -> [String: Any]? in
                    if case .image(let content) = block { return image(content) }
                    return nil
                }
                if claude, !images.isEmpty {
                    let label = images.count == 1
                        ? "Image returned by tool \(name) (call \(id)):"
                        : "\(images.count) images returned by tool \(name) (call \(id)):"
                    held.append(["text": label])
                    held += images
                } else {
                    parts += images
                }
                append(role: "user", parts: parts)
            }
        }
        releaseHeld()
        return out
    }

    /// The transcript with a tool result whose call an earlier result already
    /// answered left out (magpie `dropSecondAnswers`): the first answer
    /// stands. Google turns a call turn away when its functionResponse count
    /// differs from its functionCall count, so a client that answers one call
    /// twice had every later turn refused. A call made again under the same
    /// id takes an answer of its own.
    static func dropSecondAnswers(_ messages: [Message]) -> [Message] {
        var answered: Set<String> = []
        return messages.filter { message in
            switch message {
            case .assistant(let assistant):
                for case .toolCall(let call) in assistant.content { answered.remove(call.id) }
                return true
            case .toolResult(let result):
                guard !result.toolCallId.isEmpty else { return true }
                return answered.insert(result.toolCallId).inserted
            case .user, .system:
                return true
            }
        }
    }

    // MARK: - Ids

    /// The conversation as Antigravity names it (magpie `antigravitySession`):
    /// from its first user text, so every turn of one conversation has the
    /// same; random when it has none.
    static func sessionId(contents: [[String: Any]]) -> String {
        var first = ""
        search: for content in contents where content["role"] as? String == "user" {
            for part in content["parts"] as? [[String: Any]] ?? [] {
                if let text = part["text"] as? String, !text.isEmpty {
                    first = text
                    break search
                }
            }
            break
        }
        if first.isEmpty { first = randomToken(bytes: 16) }
        let digest = Array(SHA256.hash(data: Data(first.utf8)))
        var value: UInt64 = 0
        for byte in digest.prefix(8) { value = value << 8 | UInt64(byte) }
        return "-" + String(value & 0x7fff_ffff_ffff_ffff)
    }

    /// `bytes` random bytes, base64url (magpie `randomToken`).
    static func randomToken(bytes: Int) -> String {
        var random = [UInt8](repeating: 0, count: bytes)
        for index in random.indices { random[index] = UInt8.random(in: 0...255) }
        return PKCE.base64URL(Data(random))
    }
}
