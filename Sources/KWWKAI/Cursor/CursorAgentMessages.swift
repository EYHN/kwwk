import Foundation

/// Typed encoders/decoders for the subset of Cursor's `agent.v1` protobuf
/// schema that the chat transport needs. Field numbers are taken verbatim from
/// `agent.proto` (mirrored from oh-my-pi's bundled schema). Only the messages
/// kwwk sends or reads are modeled; everything else is skipped on decode.
enum CursorProto {

    // MARK: - Encoders (client → server)

    /// `McpToolDefinition { name=1, description=2, input_schema=3(bytes),
    /// provider_identifier=4, tool_name=5 }`. `inputSchema` carries the tool's
    /// JSON schema encoded as a `google.protobuf.Value`.
    static func encodeMcpToolDefinition(
        name: String, description: String, providerIdentifier: String,
        toolName: String, inputSchema: Data
    ) -> Data {
        var w = ProtoWriter()
        w.stringField(1, name)
        if !description.isEmpty { w.stringField(2, description) }
        if !inputSchema.isEmpty { w.bytesField(3, inputSchema) }
        w.stringField(4, providerIdentifier)
        w.stringField(5, toolName)
        return w.data
    }

    /// One image attached to a user message.
    struct UserImage {
        var uuid: String
        var mimeType: String
        var data: Data
    }

    /// `UserMessage { text=1, message_id=2, selected_context=3 }`. Images ride
    /// in `SelectedContext { selected_images=1: SelectedImage { uuid=2,
    /// mime_type=7, data=8 } }`.
    static func encodeUserMessage(text: String, messageId: String, images: [UserImage] = []) -> Data {
        var w = ProtoWriter()
        w.stringField(1, text)
        w.stringField(2, messageId)
        if !images.isEmpty {
            w.messageField(3) { ctx in
                for image in images {
                    ctx.messageField(1) { img in
                        img.stringField(2, image.uuid)
                        img.stringField(7, image.mimeType)
                        img.bytesField(8, image.data)
                    }
                }
            }
        }
        return w.data
    }

    /// `ConversationStep { assistant_message=1: AssistantMessage{ text=1 } }`.
    static func encodeAssistantStep(text: String) -> Data {
        var w = ProtoWriter()
        w.messageField(1) { m in m.stringField(1, text) }
        return w.data
    }

    /// `ConversationTurnStructure { agent_conversation_turn=1:
    /// AgentConversationTurnStructure{ user_message=1(bytes), steps=2(repeated bytes) } }`.
    static func encodeAgentTurn(userMessage: Data, steps: [Data]) -> Data {
        var w = ProtoWriter()
        w.messageField(1) { turn in
            turn.bytesField(1, userMessage)
            for step in steps { turn.bytesField(2, step) }
        }
        return w.data
    }

    /// `ConversationStateStructure { root_prompt_messages_json=1(repeated bytes),
    /// turns=8(repeated bytes) }`. When `preserving` carries the server's last
    /// checkpoint for this conversation, every field except 1 and 8 is copied
    /// through verbatim so server-maintained state (todos, file states, summary
    /// archives, subagent state, …) survives into the next request. The history
    /// fields are always rebuilt fresh — the server's echoed checkpoint replaces
    /// historical user entries with empty placeholders.
    static func encodeConversationState(
        rootPromptIds: [Data], turns: [Data], preserving checkpoint: Data? = nil
    ) -> Data {
        var w = ProtoWriter()
        for id in rootPromptIds { w.bytesField(1, id) }
        for turn in turns { w.bytesField(8, turn) }
        if let checkpoint {
            var reader = ProtoReader(checkpoint)
            while let field = reader.next() {
                guard field.number != 1, field.number != 8 else { continue }
                w.copyField(field)
            }
        }
        return w.data
    }

    /// The `root_prompt_messages_json` (field 1) entries of an encoded
    /// `ConversationStateStructure`, used to decide whether a cached checkpoint
    /// still matches the current system prompt.
    static func rootPromptIds(ofState data: Data) -> [Data] {
        var ids: [Data] = []
        var reader = ProtoReader(data)
        while let field = reader.next() {
            if field.number == 1, let bytes = field.value.asData { ids.append(bytes) }
        }
        return ids
    }

    /// The `ConversationAction` driving this run: a fresh user message, or a
    /// resume (continue the turn without new user input, e.g. after trailing
    /// tool results).
    enum RunAction {
        case userMessage(Data)
        case resume
    }

    /// Full `AgentClientMessage { run_request=1 }` carrying an
    /// `AgentRunRequest { conversation_state=1, action=2, model_details=3,
    /// conversation_id=5 }`. `action` is a `ConversationAction
    /// { user_message_action=1 | resume_action=2 }`.
    static func encodeRunRequestMessage(
        conversationState: Data,
        action runAction: RunAction,
        modelId: String,
        modelName: String,
        conversationId: String,
        customSystemPrompt: String?
    ) -> Data {
        var action = ProtoWriter()
        switch runAction {
        case .userMessage(let userMessage):
            // ConversationAction { user_message_action=1: UserMessageAction { user_message=1 } }
            action.messageField(1) { uma in
                uma.bytesField(1, userMessage)
            }
        case .resume:
            // ConversationAction { resume_action=2: ResumeAction {} }
            action.messageField(2) { _ in }
        }

        // ModelDetails { model_id=1, display_model_id=3, display_name=4 }
        var modelDetails = ProtoWriter()
        modelDetails.stringField(1, modelId)
        modelDetails.stringField(3, modelId)
        modelDetails.stringField(4, modelName.isEmpty ? modelId : modelName)

        // AgentRunRequest
        var run = ProtoWriter()
        run.bytesField(1, conversationState)
        run.bytesField(2, action.data)
        run.bytesField(3, modelDetails.data)
        run.stringField(5, conversationId)
        if let sys = customSystemPrompt, !sys.isEmpty { run.stringField(8, sys) }

        var msg = ProtoWriter()
        msg.bytesField(1, run.data)
        return msg.data
    }

    /// `AgentClientMessage { client_heartbeat=7: ClientHeartbeat{} }`.
    static func encodeHeartbeat() -> Data {
        var w = ProtoWriter()
        w.messageField(7) { _ in }
        return w.data
    }

    /// `AgentClientMessage { kv_client_message=3: KvClientMessage { id=1,
    /// get_blob_result=2: GetBlobResult{ blob_data=1(optional bytes) } } }`.
    static func encodeGetBlobResult(id: UInt32, blobData: Data?) -> Data {
        var kv = ProtoWriter()
        kv.uint32Field(1, id)
        kv.messageField(2) { r in
            if let blobData, !blobData.isEmpty { r.bytesField(1, blobData) }
        }
        var w = ProtoWriter()
        w.bytesField(3, kv.data)
        return w.data
    }

    /// `AgentClientMessage { kv_client_message=3: KvClientMessage { id=1,
    /// set_blob_result=3: SetBlobResult{} } }`.
    static func encodeSetBlobResult(id: UInt32) -> Data {
        var kv = ProtoWriter()
        kv.uint32Field(1, id)
        kv.messageField(3) { _ in }
        var w = ProtoWriter()
        w.bytesField(3, kv.data)
        return w.data
    }

    /// Wrap a pre-encoded exec-result payload as an
    /// `AgentClientMessage { exec_client_message=2: ExecClientMessage { id=1,
    /// exec_id=15, <resultField>=payload } }`.
    static func encodeExecClientMessage(
        id: UInt32, execId: String, resultField: Int, payload: Data
    ) -> Data {
        var exec = ProtoWriter()
        exec.uint32Field(1, id)
        if !execId.isEmpty { exec.stringField(15, execId) }
        exec.bytesField(resultField, payload)
        var w = ProtoWriter()
        w.bytesField(2, exec.data)
        return w.data
    }

    /// Bare `ExecClientMessage { id=1, exec_id=15 }` acknowledgement (no typed
    /// result) so the server does not hang waiting on an unhandled exec.
    static func encodeExecAck(id: UInt32, execId: String) -> Data {
        var exec = ProtoWriter()
        exec.uint32Field(1, id)
        if !execId.isEmpty { exec.stringField(15, execId) }
        var w = ProtoWriter()
        w.bytesField(2, exec.data)
        return w.data
    }

    /// `AgentClientMessage { exec_client_control_message=5:
    /// ExecClientControlMessage { stream_close=1: ExecClientStreamClose{ id=1 } } }`.
    static func encodeExecStreamClose(id: UInt32) -> Data {
        var ctrl = ProtoWriter()
        ctrl.messageField(1) { c in c.uint32Field(1, id) }
        var w = ProtoWriter()
        w.bytesField(5, ctrl.data)
        return w.data
    }

    // MARK: Exec result payloads

    /// `RequestContextResult { success=1: RequestContextSuccess { request_context=1:
    /// RequestContext { env=4, tools=7(repeated McpToolDefinition) } } }`.
    /// `workspacePath` populates `RequestContextEnv { os_version=1,
    /// workspace_paths=2, shell=3, time_zone=10 }` — the server-side harness
    /// takes its authoritative cwd from here, not from the system prompt text.
    static func encodeRequestContextResult(
        toolDefs: [Data], workspacePath: String?, osVersion: String, shell: String, timeZone: String
    ) -> Data {
        var requestContext = ProtoWriter()
        if let workspacePath, !workspacePath.isEmpty {
            requestContext.messageField(4) { env in
                env.stringField(1, osVersion)
                env.stringField(2, workspacePath)
                env.stringField(3, shell)
                env.stringField(10, timeZone)
            }
        }
        for def in toolDefs { requestContext.bytesField(7, def) }
        var success = ProtoWriter()
        success.bytesField(1, requestContext.data)
        var result = ProtoWriter()
        result.bytesField(1, success.data)
        return result.data
    }

    /// One MCP tool-result content item: text or image.
    enum McpContent {
        case text(String)
        case image(base64: String, mimeType: String)
    }

    /// `McpResult { success=1: McpSuccess { content=1(repeated), is_error=2 } }`.
    static func encodeMcpSuccess(content: [McpContent], isError: Bool) -> Data {
        var success = ProtoWriter()
        for item in content {
            success.messageField(1) { ci in
                switch item {
                case .text(let t):
                    ci.messageField(1) { tc in tc.stringField(1, t) }
                case .image(let b64, let mime):
                    ci.messageField(2) { ic in
                        if let data = Data(base64Encoded: b64) { ic.bytesField(1, data) }
                        ic.stringField(2, mime)
                    }
                }
            }
        }
        if isError { success.boolField(2, true) }
        var result = ProtoWriter()
        result.bytesField(1, success.data)
        return result.data
    }

    /// `McpResult { error=2: McpError { error=1 } }`.
    static func encodeMcpError(_ message: String) -> Data {
        var err = ProtoWriter()
        err.stringField(1, message)
        var result = ProtoWriter()
        result.bytesField(2, err.data)
        return result.data
    }

    /// `McpResult { tool_not_found=5: McpToolNotFound { name=1 } }`.
    static func encodeMcpToolNotFound(name: String) -> Data {
        var nf = ProtoWriter()
        nf.stringField(1, name)
        var result = ProtoWriter()
        result.bytesField(5, nf.data)
        return result.data
    }

    /// Encode a `*Rejected { path/command=…, reason=… }` result for a native
    /// Cursor tool that kwwk does not execute locally. `pathField`/`reasonField`
    /// give the field numbers inside the specific Rejected message, and
    /// `resultField` gives the `rejected` case number inside the *Result oneof.
    static func encodeRejectedPathResult(
        resultField: Int, path: String, reason: String
    ) -> Data {
        var rejected = ProtoWriter()
        rejected.stringField(1, path)
        rejected.stringField(2, reason)
        var result = ProtoWriter()
        result.bytesField(resultField, rejected.data)
        return result.data
    }

    /// `ShellResult { rejected=4: ShellRejected { command=1, working_directory=2,
    /// reason=3, is_readonly=4 } }`.
    static func encodeShellRejected(command: String, workingDirectory: String, reason: String) -> Data {
        var rejected = ProtoWriter()
        rejected.stringField(1, command)
        rejected.stringField(2, workingDirectory)
        rejected.stringField(3, reason)
        var result = ProtoWriter()
        result.bytesField(4, rejected.data)
        return result.data
    }

    /// `GrepResult { error=2: GrepError { error=1 } }`.
    static func encodeGrepError(_ message: String) -> Data {
        var err = ProtoWriter()
        err.stringField(1, message)
        var result = ProtoWriter()
        result.bytesField(2, err.data)
        return result.data
    }

    /// `FetchResult { error=2: FetchError { url=1, error=2 } }`.
    static func encodeFetchError(url: String, message: String) -> Data {
        var err = ProtoWriter()
        err.stringField(1, url)
        err.stringField(2, message)
        var result = ProtoWriter()
        result.bytesField(2, err.data)
        return result.data
    }

    // MARK: - GetUsableModels (used only by the kwwk-generate-cursor-models script)

    /// `GetUsableModelsRequest { custom_model_ids=1(repeated string) }` — sent empty.
    static func encodeGetUsableModelsRequest() -> Data { Data() }

    struct UsableModel {
        var modelId: String
        var displayName: String
        var displayNameShort: String
        var displayModelId: String
        var aliases: [String]
        var hasThinking: Bool
    }

    /// Decode `GetUsableModelsResponse { models=1(repeated ModelDetails) }`.
    /// `ModelDetails { model_id=1, thinking_details=2, display_model_id=3,
    /// display_name=4, display_name_short=5, aliases=6 }`.
    static func decodeUsableModels(_ data: Data) -> [UsableModel] {
        var out: [UsableModel] = []
        var reader = ProtoReader(data)
        while let field = reader.next() {
            guard field.number == 1, let bytes = field.value.asData else { continue }
            var m = UsableModel(
                modelId: "", displayName: "", displayNameShort: "",
                displayModelId: "", aliases: [], hasThinking: false
            )
            var inner = ProtoReader(bytes)
            while let f = inner.next() {
                switch f.number {
                case 1: m.modelId = f.value.asString ?? ""
                case 2: m.hasThinking = true
                case 3: m.displayModelId = f.value.asString ?? ""
                case 4: m.displayName = f.value.asString ?? ""
                case 5: m.displayNameShort = f.value.asString ?? ""
                case 6: if let s = f.value.asString { m.aliases.append(s) }
                default: break
                }
            }
            if !m.modelId.isEmpty { out.append(m) }
        }
        return out
    }

    // MARK: - google.protobuf.Value

    /// Encode a `JSONValue` as a `google.protobuf.Value` message
    /// (`null_value=1(enum), number_value=2(double), string_value=3,
    /// bool_value=4, struct_value=5, list_value=6`). Used for
    /// `McpToolDefinition.input_schema`.
    static func encodeProtoValue(_ value: JSONValue) -> Data {
        var w = ProtoWriter()
        switch value {
        case .null:
            w.varintField(1, 0)
        case .bool(let b):
            w.boolField(4, b)
        case .int(let i):
            w.doubleField(2, Double(i))
        case .double(let d):
            w.doubleField(2, d)
        case .string(let s):
            w.stringField(3, s)
        case .object(let obj):
            // Struct { fields=1: map<string, Value> } — deterministic key order
            // so identical schemas produce identical bytes.
            w.messageField(5) { s in
                for key in obj.keys.sorted() {
                    s.messageField(1) { entry in
                        entry.stringField(1, key)
                        entry.bytesField(2, encodeProtoValue(obj[key]!))
                    }
                }
            }
        case .array(let items):
            // ListValue { values=1: repeated Value }
            w.messageField(6) { l in
                for item in items { l.bytesField(1, encodeProtoValue(item)) }
            }
        }
        return w.data
    }

    /// Strictly decode a `google.protobuf.Value` message. Returns nil unless
    /// the buffer is exactly one well-formed Value field with the right wire
    /// type — strictness is what lets callers distinguish a protobuf Value from
    /// raw JSON text sharing the same bytes.
    static func decodeProtoValue(_ data: Data) -> JSONValue? {
        // An empty Value message is proto3's encoding of explicit null.
        if data.isEmpty { return .null }
        var reader = ProtoReader(data)
        guard let field = reader.next(), reader.isAtEnd else { return nil }
        switch (field.number, field.value) {
        case (1, .varint):
            return .null
        case (2, .fixed64(let bits)):
            let d = Double(bitPattern: bits)
            if d == d.rounded(), abs(d) < 1e15 { return .int(Int(d)) }
            return .double(d)
        case (3, .bytes(let bytes)):
            guard let s = String(data: bytes, encoding: .utf8) else { return nil }
            return .string(s)
        case (4, .varint(let v)):
            return .bool(v != 0)
        case (5, .bytes(let structBytes)):
            // Struct { fields=1: map entries { key=1, value=2 } }
            var obj: [String: JSONValue] = [:]
            var s = ProtoReader(structBytes)
            while let f = s.next() {
                guard f.number == 1, let entry = f.value.asData else { return nil }
                var e = ProtoReader(entry)
                var key: String?
                var value: JSONValue = .null
                while let ef = e.next() {
                    if ef.number == 1 { key = ef.value.asString }
                    if ef.number == 2, let bytes = ef.value.asData {
                        guard let decoded = decodeProtoValue(bytes) else { return nil }
                        value = decoded
                    }
                }
                guard let key else { return nil }
                obj[key] = value
            }
            return .object(obj)
        case (6, .bytes(let listBytes)):
            // ListValue { values=1: repeated Value }
            var items: [JSONValue] = []
            var l = ProtoReader(listBytes)
            while let f = l.next() {
                guard f.number == 1, let bytes = f.value.asData,
                      let decoded = decodeProtoValue(bytes) else { return nil }
                items.append(decoded)
            }
            return .array(items)
        default:
            return nil
        }
    }

    // MARK: - Exec decoding (server → client)

    /// The typed exec cases kwwk dispatches on. Raw values are the
    /// `ExecServerMessage` oneof field numbers.
    enum ExecCase: Int {
        case shell = 2
        case write = 3
        case delete = 4
        case grep = 5
        case read = 7
        case ls = 8
        case diagnostics = 9
        case requestContext = 10
        case mcp = 11
        case shellStream = 14
        case backgroundShellSpawn = 16
        case listMcpResources = 17
        case readMcpResource = 18
        case fetch = 20
        case recordScreen = 21
        case computerUse = 22
        case writeShellStdin = 23
    }

    struct ExecMessage {
        var id: UInt32 = 0
        var execId = ""
        var execCase: ExecCase?
        var payload = Data()
    }

    /// Decode `ExecServerMessage { id=1, exec_id=15, span_context=19, oneof }`.
    /// The oneof case is matched against the known field-number set, so an
    /// optional `span_context` (or any future non-oneof field) can never be
    /// mistaken for the exec case.
    static func decodeExecMessage(_ data: Data) -> ExecMessage {
        var msg = ExecMessage()
        var reader = ProtoReader(data)
        while let field = reader.next() {
            switch field.number {
            case 1: if let v = field.value.asUInt64 { msg.id = UInt32(truncatingIfNeeded: v) }
            case 15: msg.execId = field.value.asString ?? ""
            default:
                if let execCase = ExecCase(rawValue: field.number), let payload = field.value.asData {
                    msg.execCase = execCase
                    msg.payload = payload
                }
            }
        }
        return msg
    }

    struct ShellArgs {
        var command = ""
        var workingDirectory = ""
        var timeout: Int32 = 0
        var toolCallId = ""
    }

    /// `ShellArgs { command=1, working_directory=2, timeout=3, tool_call_id=4 }`.
    static func decodeShellArgs(_ data: Data) -> ShellArgs {
        var args = ShellArgs()
        var reader = ProtoReader(data)
        while let f = reader.next() {
            switch f.number {
            case 1: args.command = f.value.asString ?? ""
            case 2: args.workingDirectory = f.value.asString ?? ""
            case 3: args.timeout = f.value.asInt32 ?? 0
            case 4: args.toolCallId = f.value.asString ?? ""
            default: break
            }
        }
        return args
    }

    struct PathArgs {
        var path = ""
        var toolCallId = ""
    }

    /// `ReadArgs`/`DeleteArgs`/`DiagnosticsArgs { path=1, tool_call_id=2 }` and
    /// `LsArgs { path=1, …, tool_call_id=3 }` — pass the tool_call_id field
    /// number of the specific message.
    static func decodePathArgs(_ data: Data, toolCallIdField: Int = 2) -> PathArgs {
        var args = PathArgs()
        var reader = ProtoReader(data)
        while let f = reader.next() {
            if f.number == 1 { args.path = f.value.asString ?? "" }
            if f.number == toolCallIdField { args.toolCallId = f.value.asString ?? "" }
        }
        return args
    }

    struct GrepArgs {
        var pattern = ""
        var path = ""
        var glob = ""
        var outputMode = ""
        var caseInsensitive = false
        var toolCallId = ""
    }

    /// `GrepArgs { pattern=1, path=2, glob=3, output_mode=4, case_insensitive=8,
    /// tool_call_id=11 }`.
    static func decodeGrepArgs(_ data: Data) -> GrepArgs {
        var args = GrepArgs()
        var reader = ProtoReader(data)
        while let f = reader.next() {
            switch f.number {
            case 1: args.pattern = f.value.asString ?? ""
            case 2: args.path = f.value.asString ?? ""
            case 3: args.glob = f.value.asString ?? ""
            case 4: args.outputMode = f.value.asString ?? ""
            case 8: args.caseInsensitive = f.value.asBool ?? false
            case 11: args.toolCallId = f.value.asString ?? ""
            default: break
            }
        }
        return args
    }

    struct WriteArgs {
        var path = ""
        var fileText = ""
        var fileBytes = Data()
        var returnFileContentAfterWrite = false
        var toolCallId = ""
    }

    /// `WriteArgs { path=1, file_text=2, tool_call_id=3,
    /// return_file_content_after_write=4, file_bytes=5 }`.
    static func decodeWriteArgs(_ data: Data) -> WriteArgs {
        var args = WriteArgs()
        var reader = ProtoReader(data)
        while let f = reader.next() {
            switch f.number {
            case 1: args.path = f.value.asString ?? ""
            case 2: args.fileText = f.value.asString ?? ""
            case 3: args.toolCallId = f.value.asString ?? ""
            case 4: args.returnFileContentAfterWrite = f.value.asBool ?? false
            case 5: args.fileBytes = f.value.asData ?? Data()
            default: break
            }
        }
        return args
    }

    struct McpArgs {
        var name = ""
        var toolName = ""
        var toolCallId = ""
        var providerIdentifier = ""
        /// Raw map values; each is a protobuf-encoded `google.protobuf.Value`
        /// (with raw JSON text as a legacy fallback shape).
        var rawArgs: [String: Data] = [:]

        var arguments: JSONValue {
            var out: [String: JSONValue] = [:]
            for (key, bytes) in rawArgs {
                out[key] = CursorProto.decodeMcpArgValue(bytes)
            }
            return .object(out)
        }
    }

    /// Decode one `McpArgs.args` map value, mirroring oh-my-pi's
    /// `decodeMcpArgValue`: the bytes are a protobuf `google.protobuf.Value`;
    /// a Value that holds a string may itself be JSON text (double-encoded), so
    /// it gets one more parse attempt. Bytes that don't decode as a Value fall
    /// back to JSON text, then to a bare string.
    static func decodeMcpArgValue(_ bytes: Data) -> JSONValue {
        if let value = decodeProtoValue(bytes) {
            if case .string(let s) = value {
                return decodeLooseJSON(Data(s.utf8))
            }
            return value
        }
        return decodeLooseJSON(bytes)
    }

    /// `McpArgs { name=1, args=2(map<string,bytes>), tool_call_id=3,
    /// provider_identifier=4, tool_name=5 }`.
    static func decodeMcpArgs(_ data: Data) -> McpArgs {
        var args = McpArgs()
        var reader = ProtoReader(data)
        while let f = reader.next() {
            switch f.number {
            case 1: args.name = f.value.asString ?? ""
            case 2:
                guard let entry = f.value.asData else { break }
                var e = ProtoReader(entry)
                var key = ""
                var value = Data()
                while let ef = e.next() {
                    if ef.number == 1 { key = ef.value.asString ?? "" }
                    if ef.number == 2 { value = ef.value.asData ?? Data() }
                }
                if !key.isEmpty { args.rawArgs[key] = value }
            case 3: args.toolCallId = f.value.asString ?? ""
            case 4: args.providerIdentifier = f.value.asString ?? ""
            case 5: args.toolName = f.value.asString ?? ""
            default: break
            }
        }
        return args
    }

    /// Parse bytes as JSON; fall back to treating them as a bare string.
    static func decodeLooseJSON(_ bytes: Data) -> JSONValue {
        if let decoded = try? JSONDecoder().decode(JSONValue.self, from: bytes) {
            return decoded
        }
        return .string(String(data: bytes, encoding: .utf8) ?? "")
    }

    // MARK: - Interaction-update tool calls

    struct TodoItem {
        var id = ""
        var content = ""
        /// 1=pending, 2=in_progress, 3=completed (proto enum raw values).
        var status: Int32 = 0
    }

    /// A decoded `ToolCall` (the interaction-update variant) — only the two
    /// cases kwwk surfaces: MCP calls and the server-native todo tool.
    enum InteractionToolCall {
        case mcp(McpArgs)
        case todos([TodoItem])
    }

    struct ToolCallUpdate {
        var callId = ""
        var toolCall: InteractionToolCall?
        /// Cumulative JSON-text snapshot of the args so far
        /// (`PartialToolCallUpdate.args_text_delta`).
        var argsTextSnapshot = ""
    }

    /// Decode `ToolCallStartedUpdate` / `ToolCallCompletedUpdate
    /// { call_id=1, tool_call=2 }` or `PartialToolCallUpdate { call_id=1,
    /// tool_call=2, args_text_delta=3 }`.
    static func decodeToolCallUpdate(_ data: Data) -> ToolCallUpdate {
        var update = ToolCallUpdate()
        var reader = ProtoReader(data)
        while let f = reader.next() {
            switch f.number {
            case 1: update.callId = f.value.asString ?? ""
            case 2:
                guard let bytes = f.value.asData else { break }
                update.toolCall = decodeInteractionToolCall(bytes)
            case 3: update.argsTextSnapshot = f.value.asString ?? ""
            default: break
            }
        }
        return update
    }

    /// `ToolCall { update_todos_tool_call=9: UpdateTodosToolCall { args=1:
    /// UpdateTodosArgs { todos=1 } }, mcp_tool_call=15: McpToolCall { args=1:
    /// McpArgs } }` — every other native tool case is ignored (those arrive via
    /// the exec channel instead).
    private static func decodeInteractionToolCall(_ data: Data) -> InteractionToolCall? {
        var reader = ProtoReader(data)
        while let f = reader.next() {
            switch f.number {
            case 15:
                guard let call = f.value.asData,
                      let args = firstSubmessage(call, number: 1) else { break }
                return .mcp(decodeMcpArgs(args))
            case 9:
                guard let call = f.value.asData,
                      let args = firstSubmessage(call, number: 1) else { break }
                var todos: [TodoItem] = []
                var a = ProtoReader(args)
                while let tf = a.next() {
                    guard tf.number == 1, let bytes = tf.value.asData else { continue }
                    var todo = TodoItem()
                    var t = ProtoReader(bytes)
                    while let field = t.next() {
                        switch field.number {
                        case 1: todo.id = field.value.asString ?? ""
                        case 2: todo.content = field.value.asString ?? ""
                        case 3: todo.status = field.value.asInt32 ?? 0
                        default: break
                        }
                    }
                    todos.append(todo)
                }
                return .todos(todos)
            default:
                break
            }
        }
        return nil
    }

    private static func firstSubmessage(_ data: Data, number: Int) -> Data? {
        var reader = ProtoReader(data)
        while let f = reader.next() {
            if f.number == number { return f.value.asData }
        }
        return nil
    }

    // MARK: - Exec success results (client → server)

    /// `ReadResult { success=1: ReadSuccess { path=1, content=2, total_lines=3,
    /// file_size=4, truncated=6 } }`.
    static func encodeReadSuccess(path: String, content: String) -> Data {
        var success = ProtoWriter()
        success.stringField(1, path)
        success.stringField(2, content)
        success.int32Field(3, Int32(content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count))
        success.varintField(4, UInt64(content.utf8.count))
        var result = ProtoWriter()
        result.bytesField(1, success.data)
        return result.data
    }

    /// `ReadResult { error=2: ReadError { path=1, error=2 } }` — the same shape
    /// serves `WriteError(5)`, `LsError(2)`, `DeleteError(7)`,
    /// `DiagnosticsError(2)`: `{ path=1, error=2 }` under `resultField`.
    static func encodePathError(resultField: Int, path: String, error: String) -> Data {
        var err = ProtoWriter()
        err.stringField(1, path)
        err.stringField(2, error)
        var result = ProtoWriter()
        result.bytesField(resultField, err.data)
        return result.data
    }

    /// `WriteResult { success=1: WriteSuccess { path=1, lines_created=2,
    /// file_size=3 } }`.
    static func encodeWriteSuccess(path: String, fileText: String, byteCount: Int) -> Data {
        var success = ProtoWriter()
        success.stringField(1, path)
        success.int32Field(2, Int32(fileText.isEmpty ? 0 : fileText.split(separator: "\n", omittingEmptySubsequences: false).count))
        success.int32Field(3, Int32(byteCount))
        var result = ProtoWriter()
        result.bytesField(1, success.data)
        return result.data
    }

    /// `ShellResult { success=1: ShellSuccess { command=1, working_directory=2,
    /// exit_code=3, stdout=5 } }`.
    static func encodeShellSuccess(command: String, workingDirectory: String, stdout: String) -> Data {
        var success = ProtoWriter()
        success.stringField(1, command)
        success.stringField(2, workingDirectory)
        success.stringField(5, stdout)
        var result = ProtoWriter()
        result.bytesField(1, success.data)
        return result.data
    }

    /// `ShellResult { failure=2: ShellFailure { command=1, working_directory=2,
    /// exit_code=3, stderr=6 } }`.
    static func encodeShellFailure(command: String, workingDirectory: String, error: String) -> Data {
        var failure = ProtoWriter()
        failure.stringField(1, command)
        failure.stringField(2, workingDirectory)
        failure.int32Field(3, 1)
        failure.stringField(6, error)
        var result = ProtoWriter()
        result.bytesField(2, failure.data)
        return result.data
    }

    /// `LsResult { success=1: LsSuccess { directory_tree_root=1 } }` from the
    /// text listing of kwwk's `ls` tool: `dir/`-suffixed entries become child
    /// dirs, everything else child files.
    static func encodeLsSuccess(path: String, listing: String) -> Data {
        let rootPath = path.isEmpty ? "." : path
        let entries = listing
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }

        var root = ProtoWriter()
        root.stringField(1, rootPath)
        var fileCount = 0
        for entry in entries {
            let name = String(entry.split(separator: " (").first ?? Substring(entry))
            if name.hasSuffix("/") {
                root.messageField(2) { dir in
                    let dirName = String(name.dropLast())
                    dir.stringField(1, "\(rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath)/\(dirName)")
                }
            } else {
                root.messageField(3) { file in file.stringField(1, name) }
                fileCount += 1
            }
        }
        root.boolField(4, true)
        root.varintField(6, UInt64(fileCount))

        var success = ProtoWriter()
        success.bytesField(1, root.data)
        var result = ProtoWriter()
        result.bytesField(1, success.data)
        return result.data
    }

    /// `GrepResult { success=1: GrepSuccess { pattern=1, path=2, output_mode=3,
    /// workspace_results=4(map) } }` with the match text folded into a single
    /// content-mode `GrepFileMatch` per file parsed from `path:line:text`
    /// output lines.
    static func encodeGrepSuccess(pattern: String, path: String, output: String) -> Data {
        struct Match {
            var line: Int32
            var content: String
        }
        var byFile: [(file: String, matches: [Match])] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard !line.hasPrefix("["), !line.lowercased().hasPrefix("no matches") else { continue }
            // Parse `file:line:content`; anything else attaches to a "" file.
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            var file = ""
            var lineNumber: Int32 = 0
            var content = line
            if parts.count == 3, let n = Int32(parts[1]) {
                file = String(parts[0])
                lineNumber = n
                content = String(parts[2])
            }
            if let idx = byFile.firstIndex(where: { $0.file == file }) {
                byFile[idx].matches.append(Match(line: lineNumber, content: content))
            } else {
                byFile.append((file, [Match(line: lineNumber, content: content)]))
            }
        }

        // GrepUnionResult { content=3: GrepContentResult { matches=1, total_lines=2, total_matched_lines=3 } }
        var contentResult = ProtoWriter()
        var total = 0
        for entry in byFile {
            contentResult.messageField(1) { fm in
                fm.stringField(1, entry.file)
                for match in entry.matches {
                    fm.messageField(2) { cm in
                        cm.int32Field(1, match.line)
                        cm.stringField(2, match.content)
                    }
                }
            }
            total += entry.matches.count
        }
        contentResult.int32Field(2, Int32(total))
        contentResult.int32Field(3, Int32(total))
        var union = ProtoWriter()
        union.bytesField(3, contentResult.data)

        var success = ProtoWriter()
        success.stringField(1, pattern)
        success.stringField(2, path)
        success.stringField(3, "content")
        // workspace_results map entry { key=1, value=2 }
        success.messageField(4) { entry in
            entry.stringField(1, path.isEmpty ? "." : path)
            entry.bytesField(2, union.data)
        }
        var result = ProtoWriter()
        result.bytesField(1, success.data)
        return result.data
    }
}
