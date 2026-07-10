import Foundation
import Crypto

/// Streaming provider for Cursor subscription models (`api == "cursor-agent"`).
///
/// Cursor does not expose an OpenAI-compatible endpoint. Instead its CLI speaks
/// a bespoke agentic protocol over a full-duplex HTTP/2 Connect stream to
/// `api2.cursor.sh/agent.v1.AgentService/Run`: the client sends an
/// `AgentRunRequest`, then keeps the stream open to answer the server's
/// key-value blob fetches and exec (tool) requests while the server streams
/// `InteractionUpdate`s (text / thinking / tool-call / token deltas) back.
/// This provider ports oh-my-pi's `streamCursor`.
///
/// Tool use is server-driven and inline: kwwk's tools are advertised to Cursor
/// as MCP definitions through the `requestContext` handshake, and the server's
/// exec requests (native shell/read/grep/ls/write and MCP calls) are executed
/// mid-stream through ``CursorExecBridge`` supplied by the agent loop. Each
/// inline-executed call surfaces as a `toolCall` block marked
/// `cursorExecResolved` so the loop does not run it a second time.
public final class CursorAgentProvider: APIProvider, @unchecked Sendable {
    public static let defaultBaseHost = "api2.cursor.sh"
    public static let defaultClientVersion = "cli-2026.01.09-231024f"

    /// kwwk tool names that Cursor provides natively — they are reachable via
    /// the exec channel and must not be double-advertised as MCP tools.
    static let cursorNativeToolNames: Set<String> = [
        "bash", "read", "write", "delete", "ls", "grep", "lsp", "todo",
    ]

    /// Per-conversation blob store and last server checkpoint, kept across
    /// requests so server-maintained state (todos, file states, summary
    /// archives) and server-written blobs survive into the next turn.
    private static let conversations = ConversationRegistry()

    public let api = "cursor-agent"
    public let defaultBaseHost: String
    public let clientVersion: String
    public let defaultAPIKey: String?

    public init(
        defaultBaseHost: String = CursorAgentProvider.defaultBaseHost,
        clientVersion: String = CursorAgentProvider.defaultClientVersion,
        defaultAPIKey: String? = nil
    ) {
        self.defaultBaseHost = defaultBaseHost
        self.clientVersion = clientVersion
        self.defaultAPIKey = defaultAPIKey
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        Task.detached { [self] in
            await run(out: out, model: model, context: context, options: options)
        }
        return out
    }

    /// The model id sent on the wire. Cursor selects thinking by model id
    /// (`…-thinking` variants); the catalog's `thinkingLevelMap` routes each
    /// reasoning level to its wire id.
    static func wireModelId(model: Model, reasoning: ReasoningLevel?) -> String {
        guard let map = model.thinkingLevelMap else { return model.id }
        let requested = ModelThinkingLevel(reasoning: reasoning)
        let clamped = clampThinkingLevel(model, requested)
        if let entry = map[clamped.rawValue], let mapped = entry {
            return mapped
        }
        return model.id
    }

    // MARK: - Run

    private func run(
        out: AssistantMessageStream, model: Model, context: Context, options: StreamOptions?
    ) async {
        let apiKey = options?.resolvedAuth?.token ?? options?.apiKey ?? defaultAPIKey
        guard let apiKey, !apiKey.isEmpty else {
            let msg = errorMessage(model: model, text: "Cursor access token is required")
            out.push(.error(reason: .error, error: msg))
            out.end(msg)
            return
        }

        let host = hostFromModel(model)
        let conversationId = options?.sessionId?.isEmpty == false
            ? options!.sessionId!
            : UUID().uuidString

        let conversation = Self.conversations.state(for: conversationId)
        let requestBody = CursorRequestBuilder.build(
            model: model,
            wireModelId: Self.wireModelId(model: model, reasoning: options?.reasoning),
            context: context,
            conversationId: conversationId,
            blobStore: conversation.blobStore,
            cachedCheckpoint: conversation.checkpoint
        )
        let toolDefs = Self.mcpToolDefinitions(context.tools)

        let headers: [(String, String)] = [
            ("content-type", "application/connect+proto"),
            ("connect-protocol-version", "1"),
            ("te", "trailers"),
            ("authorization", "Bearer \(apiKey)"),
            ("x-ghost-mode", "true"),
            ("x-cursor-client-version", clientVersion),
            ("x-cursor-client-type", "cli"),
            ("x-request-id", UUID().uuidString),
        ]

        let state = CursorStreamState(api: api, model: model)
        let heartbeat = HeartbeatBox()

        do {
            let stream = try await CursorConnect.open(
                host: host,
                path: "/agent.v1.AgentService/Run",
                headers: headers,
                initialBody: requestBody
            )
            heartbeat.start(stream: stream)
            defer {
                heartbeat.stop()
                stream.close()
            }

            let cancelReg = options?.cancellation?.onCancel { _ in stream.close() }
            defer { cancelReg?.cancel() }

            out.push(.start(partial: state.snapshot()))

            let session = ExecSession(
                stream: stream,
                state: state,
                out: out,
                blobStore: conversation.blobStore,
                toolDefs: toolDefs,
                bridge: options?.cursorExecBridge
            )

            for try await frame in stream.frames {
                if options?.cancellation?.isCancelled == true {
                    let aborted = state.aborted()
                    out.push(.error(reason: .aborted, error: aborted))
                    out.end(aborted)
                    return
                }
                switch frame {
                case .message(let data):
                    let ended = handleServerMessage(
                        data, session: session, conversationId: conversationId
                    )
                    if ended {
                        finish(out: out, state: state)
                        return
                    }
                case .endStream(let data):
                    if let err = CursorConnectResponse.errorFromEndStream(data) { throw err }
                }
            }
            // Stream ended without an explicit turnEnded. A user cancel closes
            // the stream channel, which surfaces here as a clean end — report
            // it as aborted, not as a completed turn.
            if options?.cancellation?.isCancelled == true {
                let aborted = state.aborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
                return
            }
            finish(out: out, state: state)
        } catch {
            if options?.cancellation?.isCancelled == true {
                let aborted = state.aborted()
                out.push(.error(reason: .aborted, error: aborted))
                out.end(aborted)
            } else {
                let msg = errorMessage(model: model, text: "\(error)")
                out.push(.error(reason: .error, error: msg))
                out.end(msg)
            }
        }
    }

    private func finish(out: AssistantMessageStream, state: CursorStreamState) {
        state.closeOpenBlocks(emit: { out.push($0) })
        let final = state.finalize()
        out.push(.done(reason: final.stopReason, message: final))
        out.end(final)
    }

    private func hostFromModel(_ model: Model) -> String {
        guard !model.baseURL.isEmpty,
              let url = URL(string: model.baseURL), let host = url.host else {
            return defaultBaseHost
        }
        return host
    }

    private func errorMessage(model: Model, text: String) -> AssistantMessage {
        AssistantMessage(
            content: [], api: api, provider: model.provider, model: model.id,
            usage: Usage(), stopReason: .error, errorMessage: text, timestamp: Timestamp.now()
        )
    }

    /// kwwk tools advertised to Cursor as MCP definitions, minus the ones
    /// Cursor provides natively (those arrive through the exec channel).
    static func mcpToolDefinitions(_ tools: [Tool]?) -> [Data] {
        (tools ?? [])
            .filter { !cursorNativeToolNames.contains($0.name) }
            .map { tool in
                CursorProto.encodeMcpToolDefinition(
                    name: tool.name,
                    description: tool.description,
                    providerIdentifier: "kwwk",
                    toolName: tool.name,
                    inputSchema: CursorProto.encodeProtoValue(tool.parameters)
                )
            }
    }

    // MARK: - Server message dispatch

    /// Everything an in-flight Run needs to answer server messages.
    private struct ExecSession {
        let stream: CursorConnectStream
        let state: CursorStreamState
        let out: AssistantMessageStream
        let blobStore: CursorBlobStore
        let toolDefs: [Data]
        let bridge: CursorExecBridge?

        func emit(_ event: AssistantMessageEvent) { out.push(event) }
    }

    /// Handle one decoded `AgentServerMessage`. Returns true when the turn ended
    /// (the caller should finalize and stop reading).
    private func handleServerMessage(
        _ data: Data, session: ExecSession, conversationId: String
    ) -> Bool {
        var reader = ProtoReader(data)
        while let field = reader.next() {
            guard let payload = field.value.asData else { continue }
            switch field.number {
            case 1: // interaction_update
                if handleInteractionUpdate(payload, session: session) { return true }
            case 2: // exec_server_message
                handleExec(payload, session: session)
            case 3: // conversation_checkpoint_update (ConversationStateStructure)
                Self.conversations.setCheckpoint(payload, for: conversationId)
                handleCheckpointTokens(payload, state: session.state)
            case 4: // kv_server_message
                handleKv(payload, stream: session.stream, blobStore: session.blobStore)
            default:
                break
            }
        }
        return false
    }

    /// Decode `InteractionUpdate` and emit stream events. Returns true on
    /// `turnEnded`.
    private func handleInteractionUpdate(_ data: Data, session: ExecSession) -> Bool {
        let state = session.state
        var reader = ProtoReader(data)
        guard let field = reader.next() else { return false }
        switch field.number {
        case 1: // text_delta: TextDeltaUpdate { text=1 }
            if let text = firstStringField(field.value.asData, number: 1), !text.isEmpty {
                state.appendText(text, emit: session.emit)
            }
        case 4: // thinking_delta: ThinkingDeltaUpdate { text=1 }
            if let text = firstStringField(field.value.asData, number: 1), !text.isEmpty {
                state.appendThinking(text, emit: session.emit)
            }
        case 5: // thinking_completed
            state.endThinking(emit: session.emit)
        case 2: // tool_call_started
            guard let bytes = field.value.asData else { break }
            let update = CursorProto.decodeToolCallUpdate(bytes)
            switch update.toolCall {
            case .mcp(let mcp):
                let id = mcp.toolCallId.isEmpty
                    ? (update.callId.isEmpty ? UUID().uuidString : update.callId)
                    : mcp.toolCallId
                let name = mcp.toolName.isEmpty ? mcp.name : mcp.toolName
                state.startMcpToolCall(id: id, name: name, emit: session.emit)
            case .todos(let todos):
                let id = update.callId.isEmpty ? UUID().uuidString : update.callId
                state.startTodoToolCall(id: id, arguments: Self.todoArguments(todos), emit: session.emit)
            case nil:
                break
            }
        case 7: // partial_tool_call: cumulative args_text_delta snapshot
            guard let bytes = field.value.asData else { break }
            let update = CursorProto.decodeToolCallUpdate(bytes)
            if !update.argsTextSnapshot.isEmpty {
                state.appendToolCallArgs(snapshot: update.argsTextSnapshot, emit: session.emit)
            }
        case 3: // tool_call_completed
            guard let bytes = field.value.asData else { break }
            let update = CursorProto.decodeToolCallUpdate(bytes)
            let completionArgs: JSONValue?
            switch update.toolCall {
            case .mcp(let mcp): completionArgs = mcp.arguments
            case .todos(let todos): completionArgs = Self.todoArguments(todos)
            case nil: completionArgs = nil
            }
            state.completeToolCall(completionArgs: completionArgs, emit: session.emit)
        case 8: // token_delta: TokenDeltaUpdate { tokens=1 (int32) }
            if let tokens = firstInt32Field(field.value.asData, number: 1) {
                state.addOutputTokens(Int(tokens))
            }
        case 14: // turn_ended
            return true
        default:
            break
        }
        return false
    }

    /// `{"todos": [{id?, content, activeForm, status}]}` in the shape kwwk's
    /// todo consumers expect; proto status 2=in_progress, 3=completed.
    private static func todoArguments(_ todos: [CursorProto.TodoItem]) -> JSONValue {
        .object(["todos": .array(todos.map { todo in
            var obj: [String: JSONValue] = [
                "content": .string(todo.content),
                "activeForm": .string(todo.content),
                "status": .string(todo.status == 2 ? "in_progress" : todo.status == 3 ? "completed" : "pending"),
            ]
            if !todo.id.isEmpty { obj["id"] = .string(todo.id) }
            return .object(obj)
        })])
    }

    private func handleCheckpointTokens(_ data: Data, state: CursorStreamState) {
        // ConversationStateStructure { token_details=5: ConversationTokenDetails { used_tokens=1 } }
        var reader = ProtoReader(data)
        while let field = reader.next() {
            guard field.number == 5, let details = field.value.asData else { continue }
            var inner = ProtoReader(details)
            while let f = inner.next() {
                if f.number == 1, let used = f.value.asUInt64 {
                    state.applyCheckpointUsedTokens(Int(used))
                }
            }
        }
    }

    // MARK: - KV blob handshake

    private func handleKv(_ data: Data, stream: CursorConnectStream, blobStore: CursorBlobStore) {
        // KvServerMessage { id=1, get_blob_args=2, set_blob_args=3 }
        var reader = ProtoReader(data)
        var id: UInt32 = 0
        var getBlobId: Data?
        var setBlobId: Data?
        var setBlobData: Data?
        while let field = reader.next() {
            switch field.number {
            case 1: if let v = field.value.asUInt64 { id = UInt32(truncatingIfNeeded: v) }
            case 2: // GetBlobArgs { blob_id=1 }
                getBlobId = firstDataField(field.value.asData, number: 1)
            case 3: // SetBlobArgs { blob_id=1, blob_data=2 }
                if let bytes = field.value.asData {
                    setBlobId = firstDataField(bytes, number: 1)
                    setBlobData = firstDataField(bytes, number: 2)
                }
            default: break
            }
        }
        if let getBlobId {
            let blob = blobStore.get(getBlobId)
            stream.send(CursorProto.encodeGetBlobResult(id: id, blobData: blob))
        } else if let setBlobId {
            blobStore.set(setBlobId, data: setBlobData ?? Data())
            stream.send(CursorProto.encodeSetBlobResult(id: id))
        }
    }

    // MARK: - Exec handshake

    private func handleExec(_ data: Data, session: ExecSession) {
        let msg = CursorProto.decodeExecMessage(data)
        let stream = session.stream

        let reply: @Sendable (Int, Data) -> Void = { resultField, payload in
            stream.send(CursorProto.encodeExecClientMessage(
                id: msg.id, execId: msg.execId, resultField: resultField, payload: payload
            ))
        }

        switch msg.execCase {
        case .requestContext:
            reply(10, CursorProto.encodeRequestContextResult(
                toolDefs: session.toolDefs,
                workspacePath: session.bridge?.cwd,
                osVersion: osVersionString(),
                shell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                timeZone: TimeZone.current.identifier
            ))

        case .read:
            let args = CursorProto.decodePathArgs(msg.payload)
            bridgeNativeExec(
                session: session,
                toolCallId: args.toolCallId,
                toolName: "read",
                arguments: .object(["path": .string(args.path)]),
                rejected: { CursorProto.encodeRejectedPathResult(resultField: 3, path: args.path, reason: $0) },
                success: { CursorProto.encodeReadSuccess(path: args.path, content: $0) },
                failure: { CursorProto.encodePathError(resultField: 2, path: args.path, error: $0) },
                send: { reply(7, $0) }
            )

        case .ls:
            let args = CursorProto.decodePathArgs(msg.payload, toolCallIdField: 3)
            bridgeNativeExec(
                session: session,
                toolCallId: args.toolCallId,
                toolName: "ls",
                arguments: .object(["path": .string(args.path)]),
                rejected: { CursorProto.encodeRejectedPathResult(resultField: 3, path: args.path, reason: $0) },
                success: { CursorProto.encodeLsSuccess(path: args.path, listing: $0) },
                failure: { CursorProto.encodePathError(resultField: 2, path: args.path, error: $0) },
                send: { reply(8, $0) }
            )

        case .grep:
            let args = CursorProto.decodeGrepArgs(msg.payload)
            guard !args.pattern.isEmpty else {
                // Cursor's model sometimes sends an empty pattern with a glob,
                // expecting a file listing. Reject with an actionable message so
                // it retries with a real regex or switches tools.
                reply(5, CursorProto.encodeGrepError(
                    "grep requires a non-empty regex pattern; use ls or read to list files"
                ))
                return
            }
            var grepArgs: [String: JSONValue] = ["pattern": .string(args.pattern)]
            if !args.path.isEmpty { grepArgs["path"] = .string(args.path) }
            if !args.glob.isEmpty { grepArgs["glob"] = .string(args.glob) }
            if args.caseInsensitive { grepArgs["ignoreCase"] = .bool(true) }
            bridgeNativeExec(
                session: session,
                toolCallId: args.toolCallId,
                toolName: "grep",
                arguments: .object(grepArgs),
                rejected: { CursorProto.encodeGrepError($0) },
                success: { CursorProto.encodeGrepSuccess(pattern: args.pattern, path: args.path, output: $0) },
                failure: { CursorProto.encodeGrepError($0) },
                send: { reply(5, $0) }
            )

        case .shell:
            let args = CursorProto.decodeShellArgs(msg.payload)
            bridgeNativeExec(
                session: session,
                toolCallId: args.toolCallId,
                toolName: "bash",
                arguments: Self.bashArguments(args),
                rejected: {
                    CursorProto.encodeShellRejected(
                        command: args.command, workingDirectory: args.workingDirectory, reason: $0
                    )
                },
                success: {
                    CursorProto.encodeShellSuccess(
                        command: args.command, workingDirectory: args.workingDirectory, stdout: $0
                    )
                },
                failure: {
                    CursorProto.encodeShellFailure(
                        command: args.command, workingDirectory: args.workingDirectory, error: $0
                    )
                },
                send: { reply(2, $0) }
            )

        case .shellStream:
            let args = CursorProto.decodeShellArgs(msg.payload)
            handleShellStream(args, msg: msg, session: session)

        case .write:
            let args = CursorProto.decodeWriteArgs(msg.payload)
            let content = args.fileText.isEmpty && !args.fileBytes.isEmpty
                ? String(data: args.fileBytes, encoding: .utf8) ?? ""
                : args.fileText
            let byteCount = args.fileBytes.isEmpty ? args.fileText.utf8.count : args.fileBytes.count
            bridgeNativeExec(
                session: session,
                toolCallId: args.toolCallId,
                toolName: "write",
                arguments: .object(["path": .string(args.path), "content": .string(content)]),
                rejected: { CursorProto.encodeRejectedPathResult(resultField: 6, path: args.path, reason: $0) },
                success: { _ in
                    CursorProto.encodeWriteSuccess(path: args.path, fileText: content, byteCount: byteCount)
                },
                failure: { CursorProto.encodePathError(resultField: 5, path: args.path, error: $0) },
                send: { reply(3, $0) }
            )

        case .delete:
            let args = CursorProto.decodePathArgs(msg.payload)
            bridgeNativeExec(
                session: session,
                toolCallId: args.toolCallId,
                toolName: "delete",
                arguments: .object(["path": .string(args.path)]),
                rejected: { CursorProto.encodeRejectedPathResult(resultField: 6, path: args.path, reason: $0) },
                success: { _ in
                    var success = ProtoWriter()
                    success.stringField(1, args.path)
                    var result = ProtoWriter()
                    result.bytesField(1, success.data)
                    return result.data
                },
                failure: { CursorProto.encodePathError(resultField: 7, path: args.path, error: $0) },
                send: { reply(4, $0) }
            )

        case .diagnostics:
            // kwwk has no LSP tool; reject so the model falls back to grep/read.
            let args = CursorProto.decodePathArgs(msg.payload)
            reply(9, CursorProto.encodeRejectedPathResult(
                resultField: 3, path: args.path, reason: "Diagnostics not available"
            ))

        case .mcp:
            let args = CursorProto.decodeMcpArgs(msg.payload)
            let name = args.toolName.isEmpty ? args.name : args.toolName
            guard let bridge = session.bridge else {
                reply(11, CursorProto.encodeMcpToolNotFound(name: name))
                return
            }
            let callId = args.toolCallId.isEmpty ? UUID().uuidString : args.toolCallId
            Task {
                let result = await bridge.execute(
                    ToolCall(id: callId, name: name, arguments: args.arguments, cursorExecResolved: true)
                )
                // The streamed mcp block (from tool_call_started) pairs with this
                // result; mark it resolved so the agent loop skips it. Without a
                // streamed block, synthesize one so the transcript stays paired.
                if !session.state.markToolCallResolved(id: callId) {
                    session.state.synthesizeResolvedToolCall(
                        id: callId, name: name, arguments: args.arguments, emit: session.emit
                    )
                }
                if result.isError {
                    reply(11, CursorProto.encodeMcpError(Self.toolResultText(result)))
                } else {
                    reply(11, CursorProto.encodeMcpSuccess(
                        content: Self.mcpContent(result), isError: false
                    ))
                }
            }

        case .fetch:
            let url = firstStringField(msg.payload, number: 1) ?? ""
            reply(20, CursorProto.encodeFetchError(url: url, message: "Not implemented"))

        case .backgroundShellSpawn:
            let args = CursorProto.decodeShellArgs(msg.payload)
            // BackgroundShellSpawnResult { rejected=3: ShellRejected }
            var result = ProtoWriter()
            var rejected = ProtoWriter()
            rejected.stringField(1, args.command)
            rejected.stringField(2, args.workingDirectory)
            rejected.stringField(3, "Not implemented")
            result.bytesField(3, rejected.data)
            reply(16, result.data)

        case .writeShellStdin:
            // WriteShellStdinResult { error=2: WriteShellStdinError { error=1 } }
            var err = ProtoWriter()
            err.stringField(1, "Not implemented")
            var result = ProtoWriter()
            result.bytesField(2, err.data)
            reply(23, result.data)

        case .listMcpResources:
            reply(17, Data())
        case .readMcpResource:
            reply(18, Data())
        case .recordScreen:
            reply(21, Data())
        case .computerUse:
            reply(22, Data())

        case nil:
            // Unknown exec — bare ack so the server does not hang.
            stream.send(CursorProto.encodeExecAck(id: msg.id, execId: msg.execId))
        }
    }

    private static func bashArguments(_ args: CursorProto.ShellArgs) -> JSONValue {
        var out: [String: JSONValue] = ["command": .string(args.command)]
        // Cursor sends the shell timeout in milliseconds; kwwk's bash tool
        // takes seconds.
        if args.timeout > 0 { out["timeout"] = .int(max(1, Int(args.timeout) / 1000)) }
        return .object(out)
    }

    /// Run one native exec through the bridge: synthesize the resolved
    /// `toolCall` block up front (so the transcript shows the call), execute the
    /// mapped kwwk tool, then answer the exec with a typed success/failure
    /// payload built from the tool result text. Without a bridge the exec is
    /// rejected.
    private func bridgeNativeExec(
        session: ExecSession,
        toolCallId: String,
        toolName: String,
        arguments: JSONValue,
        rejected: @escaping @Sendable (String) -> Data,
        success: @escaping @Sendable (String) -> Data,
        failure: @escaping @Sendable (String) -> Data,
        send: @escaping @Sendable (Data) -> Void
    ) {
        guard let bridge = session.bridge else {
            send(rejected("Tool not available"))
            return
        }
        let callId = toolCallId.isEmpty ? UUID().uuidString : toolCallId
        session.state.synthesizeResolvedToolCall(
            id: callId, name: toolName, arguments: arguments, emit: session.emit
        )
        Task {
            let result = await bridge.execute(
                ToolCall(id: callId, name: toolName, arguments: arguments, cursorExecResolved: true)
            )
            let text = Self.toolResultText(result)
            send(result.isError ? failure(text.isEmpty ? "\(toolName) failed" : text) : success(text))
        }
    }

    /// shell_stream_args: reply over the `shell_stream=14` event channel —
    /// start, the command's output as one stdout chunk, exit, then streamClose.
    private func handleShellStream(
        _ args: CursorProto.ShellArgs,
        msg: CursorProto.ExecMessage,
        session: ExecSession
    ) {
        let stream = session.stream

        func sendEvent(_ body: (inout ProtoWriter) -> Void) {
            var event = ProtoWriter()
            body(&event)
            stream.send(CursorProto.encodeExecClientMessage(
                id: msg.id, execId: msg.execId, resultField: 14, payload: event.data
            ))
        }

        guard let bridge = session.bridge else {
            // ShellStream { rejected=5: ShellRejected }
            sendEvent { w in
                w.messageField(5) { r in
                    r.stringField(1, args.command)
                    r.stringField(2, args.workingDirectory)
                    r.stringField(3, "Tool not available")
                }
            }
            stream.send(CursorProto.encodeExecStreamClose(id: msg.id))
            return
        }

        let callId = args.toolCallId.isEmpty ? UUID().uuidString : args.toolCallId
        session.state.synthesizeResolvedToolCall(
            id: callId, name: "bash", arguments: Self.bashArguments(args), emit: session.emit
        )
        Task {
            sendEvent { w in w.messageField(4) { _ in } } // start
            let result = await bridge.execute(
                ToolCall(id: callId, name: "bash", arguments: Self.bashArguments(args), cursorExecResolved: true)
            )
            let text = Self.toolResultText(result)
            if !text.isEmpty {
                sendEvent { w in
                    w.messageField(result.isError ? 2 : 1) { chunk in chunk.stringField(1, text) }
                }
            }
            sendEvent { w in
                w.messageField(3) { exit in // ShellStreamExit { code=1, cwd=2 }
                    if result.isError { exit.varintField(1, 1) }
                    exit.stringField(2, args.workingDirectory)
                }
            }
            stream.send(CursorProto.encodeExecStreamClose(id: msg.id))
        }
    }

    private func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        return "darwin \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #else
        return "linux \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    private static func toolResultText(_ result: ToolResultMessage) -> String {
        result.content.compactMap { block -> String? in
            switch block {
            case .text(let t): return t.text
            case .image(let i): return "[\(i.mimeType) image]"
            }
        }.joined(separator: "\n")
    }

    private static func mcpContent(_ result: ToolResultMessage) -> [CursorProto.McpContent] {
        result.content.map { block in
            switch block {
            case .text(let t): return .text(t.text)
            case .image(let i): return .image(base64: i.data, mimeType: i.mimeType)
            }
        }
    }
}

// MARK: - Small proto field helpers

private func firstStringField(_ data: Data?, number: Int) -> String? {
    guard let data else { return nil }
    var reader = ProtoReader(data)
    while let f = reader.next() {
        if f.number == number { return f.value.asString }
    }
    return nil
}

private func firstInt32Field(_ data: Data?, number: Int) -> Int32? {
    guard let data else { return nil }
    var reader = ProtoReader(data)
    while let f = reader.next() {
        if f.number == number { return f.value.asInt32 }
    }
    return nil
}

private func firstDataField(_ data: Data?, number: Int) -> Data? {
    guard let data else { return nil }
    var reader = ProtoReader(data)
    while let f = reader.next() {
        if f.number == number { return f.value.asData }
    }
    return nil
}

// MARK: - Conversation registry & blob store

/// Blob store and last server checkpoint per conversation, shared across the
/// requests of a session so server-side conversation state survives turns.
private final class ConversationRegistry: @unchecked Sendable {
    struct Entry {
        let blobStore: CursorBlobStore
        var checkpoint: Data?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func state(for conversationId: String) -> Entry {
        lock.withLock {
            if let entry = entries[conversationId] { return entry }
            let entry = Entry(blobStore: CursorBlobStore(), checkpoint: nil)
            entries[conversationId] = entry
            return entry
        }
    }

    func setCheckpoint(_ data: Data, for conversationId: String) {
        lock.withLock {
            var entry = entries[conversationId] ?? Entry(blobStore: CursorBlobStore(), checkpoint: nil)
            entry.checkpoint = data
            entries[conversationId] = entry
        }
    }
}

/// Key/value blob store the server reads from and writes to during a Run. Keys
/// are the raw blob ids (hex-encoded internally for dictionary use).
final class CursorBlobStore: @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    /// Store `data` under its sha256 hash and return that blob id.
    func store(_ data: Data) -> Data {
        let id = Data(SHA256.hash(data: data))
        set(id, data: data)
        return id
    }

    func set(_ id: Data, data: Data) {
        lock.withLock { blobs[id.hexString] = data }
    }

    func get(_ id: Data) -> Data? {
        lock.withLock { blobs[id.hexString] }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Heartbeat

/// Sends a `ClientHeartbeat` every 5 seconds to keep the Run stream alive,
/// mirroring oh-my-pi's heartbeat timer.
private final class HeartbeatBox: @unchecked Sendable {
    private var task: Task<Void, Never>?

    func start(stream: CursorConnectStream) {
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                stream.send(CursorProto.encodeHeartbeat())
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
