import Foundation
import Testing
@testable import KWWKAI

@Suite("Cursor protobuf codec")
struct CursorProtoTests {

    @Test("varint round-trips through writer and reader")
    func varintRoundTrip() {
        var w = ProtoWriter()
        w.varintField(1, 0)
        w.varintField(2, 300)
        w.varintField(3, UInt64(UInt32.max))
        var r = ProtoReader(w.data)
        var got: [(Int, UInt64)] = []
        while let f = r.next() { got.append((f.number, f.value.asUInt64 ?? 0)) }
        #expect(got.count == 3)
        #expect(got[0] == (1, 0))
        #expect(got[1] == (2, 300))
        #expect(got[2] == (3, UInt64(UInt32.max)))
    }

    @Test("string and bytes fields decode back")
    func stringBytes() {
        var w = ProtoWriter()
        w.stringField(1, "hello")
        w.bytesField(2, Data([0xDE, 0xAD, 0xBE, 0xEF]))
        var r = ProtoReader(w.data)
        let a = r.next()
        let b = r.next()
        #expect(a?.number == 1)
        #expect(a?.value.asString == "hello")
        #expect(b?.number == 2)
        #expect(b?.value.asData == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test("nested message field is length-delimited and re-readable")
    func nestedMessage() {
        var w = ProtoWriter()
        w.messageField(5) { inner in
            inner.stringField(1, "nested")
            inner.varintField(2, 42)
        }
        var r = ProtoReader(w.data)
        let outer = r.next()
        #expect(outer?.number == 5)
        var inner = ProtoReader(outer!.value.asData!)
        #expect(inner.next()?.value.asString == "nested")
        #expect(inner.next()?.value.asUInt64 == 42)
    }

    @Test("decodeUsableModels parses ModelDetails entries")
    func usableModels() {
        // Build a GetUsableModelsResponse { models=1 (repeated ModelDetails) }.
        func modelDetails(id: String, name: String, thinking: Bool) -> Data {
            var m = ProtoWriter()
            m.stringField(1, id)
            if thinking { m.messageField(2) { _ in } } // thinking_details present
            m.stringField(4, name)
            return m.data
        }
        var w = ProtoWriter()
        w.bytesField(1, modelDetails(id: "claude-4.5-sonnet", name: "Claude 4.5 Sonnet", thinking: true))
        w.bytesField(1, modelDetails(id: "gpt-5", name: "GPT-5", thinking: false))

        let models = CursorProto.decodeUsableModels(w.data)
        #expect(models.count == 2)
        #expect(models[0].modelId == "claude-4.5-sonnet")
        #expect(models[0].displayName == "Claude 4.5 Sonnet")
        #expect(models[0].hasThinking == true)
        #expect(models[1].modelId == "gpt-5")
        #expect(models[1].hasThinking == false)
    }

    @Test("normalize maps discovered models to cursor-agent Models")
    func normalize() {
        let discovered = [
            CursorProto.UsableModel(
                modelId: "gpt-5", displayName: "GPT-5", displayNameShort: "",
                displayModelId: "", aliases: [], hasThinking: true
            )
        ]
        let models = CursorModelCatalog.normalize(discovered, host: "api2.cursor.sh")
        #expect(models.count == 1)
        #expect(models[0].id == "gpt-5")
        #expect(models[0].api == "cursor-agent")
        #expect(models[0].provider == "cursor")
        #expect(models[0].reasoning == true)
        #expect(models[0].baseURL == "https://api2.cursor.sh")
        #expect(models[0].input == [.text, .image])
    }

    @Test("normalize infers image input from the model family for uncurated ids")
    func inferredInputModalities() {
        func model(_ id: String) -> CursorProto.UsableModel {
            CursorProto.UsableModel(
                modelId: id, displayName: id, displayNameShort: "",
                displayModelId: "", aliases: [], hasThinking: false
            )
        }
        let models = CursorModelCatalog.normalize(
            [model("claude-9-sonnet"), model("gemini-9-pro"), model("gpt-9"),
             model("codex-9"), model("composer-9"), model("grok-code-fast-9")],
            host: "api2.cursor.sh"
        )
        let byId = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        #expect(byId["claude-9-sonnet"]?.input == [.text, .image])
        #expect(byId["gemini-9-pro"]?.input == [.text, .image])
        #expect(byId["gpt-9"]?.input == [.text, .image])
        #expect(byId["codex-9"]?.input == [.text, .image])
        #expect(byId["composer-9"]?.input == [.text])
        #expect(byId["grok-code-fast-9"]?.input == [.text])
    }

    @Test("bundled cursor-models.json loads into the catalog")
    func bundledCursorCatalog() {
        let models = ModelsCatalog.models(for: "cursor")
        #expect(!models.isEmpty)
        #expect(models.allSatisfy { $0.api == "cursor-agent" && $0.provider == "cursor" })
        #expect(ModelsCatalog.model(provider: "cursor", id: "default") != nil)
    }

    // MARK: Request building

    private func buildRequest(
        messages: [Message],
        systemPrompt: String = "You are helpful.",
        blobStore: CursorBlobStore = CursorBlobStore(),
        checkpoint: Data? = nil
    ) -> (run: Data, blobStore: CursorBlobStore) {
        let model = Model(id: "auto", api: "cursor-agent", provider: "cursor")
        let bytes = CursorRequestBuilder.build(
            model: model,
            wireModelId: model.id,
            context: Context(systemPrompt: systemPrompt, messages: messages),
            conversationId: "conv-1",
            blobStore: blobStore,
            cachedCheckpoint: checkpoint
        )
        var top = ProtoReader(bytes)
        let runField = top.next()
        #expect(runField?.number == 1)
        return (runField!.value.asData!, blobStore)
    }

    private func field(_ data: Data, _ number: Int) -> Data? {
        var reader = ProtoReader(data)
        while let f = reader.next() {
            if f.number == number { return f.value.asData }
        }
        return nil
    }

    private func repeatedField(_ data: Data, _ number: Int) -> [Data] {
        var out: [Data] = []
        var reader = ProtoReader(data)
        while let f = reader.next() {
            if f.number == number, let d = f.value.asData { out.append(d) }
        }
        return out
    }

    @Test("run request encodes with a decodable AgentRunRequest envelope")
    func runRequestEnvelope() throws {
        let (run, _) = buildRequest(messages: [.user(UserMessage(text: "hi there"))])
        var reader = ProtoReader(run)
        var seen: Set<Int> = []
        var conversationId: String?
        while let f = reader.next() {
            seen.insert(f.number)
            if f.number == 5 { conversationId = f.value.asString }
        }
        #expect(seen.isSuperset(of: [1, 2, 3]))
        #expect(conversationId == "conv-1")
    }

    @Test("turns and steps are sha256 blob IDs resolvable through the blob store")
    func turnsAreBlobIds() throws {
        let assistant = AssistantMessage(
            content: [.text(TextContent(text: "first answer"))],
            api: "cursor-agent", provider: "cursor", model: "auto"
        )
        let (run, blobStore) = buildRequest(messages: [
            .user(UserMessage(text: "first question")),
            .assistant(assistant),
            .toolResult(ToolResultMessage(
                toolCallId: "t1", toolName: "grep",
                content: [.text(TextContent(text: "3 matches"))]
            )),
            .user(UserMessage(text: "second question")),
        ])

        let state = field(run, 1)!
        let turns = repeatedField(state, 8)
        #expect(turns.count == 1)
        // The turn entry is a 32-byte blob id, not inline message bytes.
        #expect(turns[0].count == 32)
        let turnBytes = blobStore.get(turns[0])
        #expect(turnBytes != nil)

        // ConversationTurnStructure { agent_conversation_turn=1 { user_message=1, steps=2 } }
        let agentTurn = field(turnBytes!, 1)!
        let userMessageId = field(agentTurn, 1)!
        #expect(userMessageId.count == 32)
        let userMessage = blobStore.get(userMessageId)
        #expect(userMessage != nil)
        var um = ProtoReader(userMessage!)
        #expect(um.next()?.value.asString == "first question")

        let stepIds = repeatedField(agentTurn, 2)
        #expect(stepIds.count == 2) // assistant text + folded tool result
        let step0 = blobStore.get(stepIds[0])
        #expect(step0 != nil)
        var step = ProtoReader(field(step0!, 1)!)
        #expect(step.next()?.value.asString == "first answer")
        let step1 = String(data: blobStore.get(stepIds[1])!, encoding: .utf8) ?? ""
        #expect(step1.contains("[Tool Result]"))
        #expect(step1.contains("3 matches"))
    }

    @Test("rootPromptMessagesJson carries system prompt plus prior history as JSON blobs")
    func rootPromptCarriesHistory() throws {
        let assistant = AssistantMessage(
            content: [.text(TextContent(text: "the answer"))],
            api: "cursor-agent", provider: "cursor", model: "auto"
        )
        let (run, blobStore) = buildRequest(messages: [
            .user(UserMessage(text: "old question")),
            .assistant(assistant),
            .user(UserMessage(text: "new question")),
        ])
        let state = field(run, 1)!
        let ids = repeatedField(state, 1)
        // system + prior user + prior assistant; the active message rides in the action.
        #expect(ids.count == 3)
        let decoded = ids.map { id -> [String: Any] in
            let bytes = blobStore.get(id)!
            return try! JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        }
        #expect(decoded[0]["role"] as? String == "system")
        #expect(decoded[1]["role"] as? String == "user")
        #expect(decoded[2]["role"] as? String == "assistant")
        let userContent = decoded[1]["content"] as! [[String: Any]]
        #expect(userContent[0]["text"] as? String == "old question")
    }

    @Test("trailing tool result yields a resume action and keeps history")
    func resumeAction() throws {
        let assistant = AssistantMessage(
            content: [.text(TextContent(text: "calling a tool"))],
            api: "cursor-agent", provider: "cursor", model: "auto"
        )
        let (run, _) = buildRequest(messages: [
            .user(UserMessage(text: "do something")),
            .assistant(assistant),
            .toolResult(ToolResultMessage(
                toolCallId: "t1", toolName: "bash",
                content: [.text(TextContent(text: "done"))]
            )),
        ])
        // ConversationAction { resume_action=2 }, no user_message_action.
        let action = field(run, 2)!
        #expect(field(action, 1) == nil)
        var reader = ProtoReader(action)
        var sawResume = false
        while let f = reader.next() {
            if f.number == 2 { sawResume = true }
        }
        #expect(sawResume)
        // The completed turn (user + assistant + tool result) stays serialized.
        let state = field(run, 1)!
        #expect(repeatedField(state, 8).count == 1)
    }

    @Test("images ride in the user message's selected_context")
    func imagesInUserMessage() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let (run, _) = buildRequest(messages: [
            .user(UserMessage(content: [
                .text(TextContent(text: "what is this?")),
                .image(ImageContent(data: png.base64EncodedString(), mimeType: "image/png")),
            ])),
        ])
        // action → user_message_action=1 → user_message=1 → selected_context=3
        let action = field(run, 2)!
        let uma = field(action, 1)!
        let userMessage = field(uma, 1)!
        let selectedContext = field(userMessage, 3)
        #expect(selectedContext != nil)
        let image = field(selectedContext!, 1)!
        var reader = ProtoReader(image)
        var mime: String?
        var bytes: Data?
        while let f = reader.next() {
            if f.number == 7 { mime = f.value.asString }
            if f.number == 8 { bytes = f.value.asData }
        }
        #expect(mime == "image/png")
        #expect(bytes == png)
    }

    @Test("conversation state preserves non-history checkpoint fields")
    func checkpointPreserved() throws {
        // A fake server checkpoint: same system prompt head, plus todos=3 payload
        // and stale turns that must NOT survive.
        let systemBlob = CursorBlobStore()
        let (firstRun, firstStore) = buildRequest(messages: [.user(UserMessage(text: "hi"))], blobStore: systemBlob)
        _ = firstStore
        let systemId = repeatedField(field(firstRun, 1)!, 1)[0]

        var checkpoint = ProtoWriter()
        checkpoint.bytesField(1, systemId)
        checkpoint.bytesField(8, Data([0xAA])) // stale turn — must be dropped
        checkpoint.messageField(3) { todos in todos.stringField(1, "todo-state") }

        let (run, _) = buildRequest(messages: [.user(UserMessage(text: "hi"))], checkpoint: checkpoint.data)
        let state = field(run, 1)!
        // Preserved: field 3 (todos). Rebuilt: fields 1/8 (no stale turn).
        #expect(field(state, 3) != nil)
        #expect(repeatedField(state, 8).isEmpty)
        #expect(!repeatedField(state, 1).isEmpty)
    }
}

@Suite("Cursor exec decoding")
struct CursorExecDecodeTests {

    @Test("span_context before the oneof case does not confuse dispatch")
    func spanContextSkipped() {
        // ExecServerMessage { id=1, span_context=19, fetch_args=20, exec_id=15 }
        var w = ProtoWriter()
        w.uint32Field(1, 7)
        w.messageField(19) { span in span.stringField(1, "trace") }
        w.messageField(20) { fetch in fetch.stringField(1, "https://example.com") }
        w.stringField(15, "exec-1")
        let msg = CursorProto.decodeExecMessage(w.data)
        #expect(msg.id == 7)
        #expect(msg.execId == "exec-1")
        #expect(msg.execCase == .fetch)
    }

    @Test("shell args decode")
    func shellArgs() {
        var w = ProtoWriter()
        w.stringField(1, "ls -la")
        w.stringField(2, "/tmp")
        w.int32Field(3, 30)
        w.stringField(4, "call-9")
        let args = CursorProto.decodeShellArgs(w.data)
        #expect(args.command == "ls -la")
        #expect(args.workingDirectory == "/tmp")
        #expect(args.timeout == 30)
        #expect(args.toolCallId == "call-9")
    }

    @Test("mcp args decode the raw map into loose JSON")
    func mcpArgs() {
        var w = ProtoWriter()
        w.stringField(1, "search")
        w.messageField(2) { entry in
            entry.stringField(1, "query")
            entry.bytesField(2, Data("\"hello\"".utf8))
        }
        w.messageField(2) { entry in
            entry.stringField(1, "limit")
            entry.bytesField(2, Data("5".utf8))
        }
        w.stringField(3, "call-1")
        w.stringField(5, "search_tool")
        let args = CursorProto.decodeMcpArgs(w.data)
        #expect(args.name == "search")
        #expect(args.toolName == "search_tool")
        #expect(args.toolCallId == "call-1")
        guard case .object(let obj) = args.arguments else {
            Issue.record("expected object")
            return
        }
        #expect(obj["query"] == .string("hello"))
        #expect(obj["limit"] == .int(5))
    }

    @Test("mcp arg map values decode as protobuf Values (the wire shape)")
    func mcpArgsProtoValues() {
        // McpArgs whose map values are protobuf-encoded google.protobuf.Value,
        // matching what Cursor actually sends. A plain enum string like "get"
        // must come out as the bare string, not a quoted JSON literal.
        var w = ProtoWriter()
        w.stringField(1, "goal")
        w.messageField(2) { entry in
            entry.stringField(1, "op")
            entry.bytesField(2, CursorProto.encodeProtoValue(.string("get")))
        }
        w.messageField(2) { entry in
            entry.stringField(1, "limit")
            entry.bytesField(2, CursorProto.encodeProtoValue(.int(5)))
        }
        w.messageField(2) { entry in
            entry.stringField(1, "nested")
            entry.bytesField(2, CursorProto.encodeProtoValue(.object(["a": .bool(true)])))
        }
        // A Value string that itself holds JSON text is double-encoded and
        // gets one more parse.
        w.messageField(2) { entry in
            entry.stringField(1, "jsonInString")
            entry.bytesField(2, CursorProto.encodeProtoValue(.string("{\"b\":2}")))
        }
        let args = CursorProto.decodeMcpArgs(w.data)
        guard case .object(let obj) = args.arguments else {
            Issue.record("expected object")
            return
        }
        #expect(obj["op"] == .string("get"))
        #expect(obj["limit"] == .int(5))
        #expect(obj["nested"] == .object(["a": .bool(true)]))
        #expect(obj["jsonInString"] == .object(["b": .int(2)]))
    }

    @Test("google.protobuf.Value encodes a JSON schema object")
    func protoValue() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("path")]),
        ])
        let data = CursorProto.encodeProtoValue(schema)
        // Value { struct_value=5: Struct { fields=1: entries } }
        var reader = ProtoReader(data)
        let structField = reader.next()
        #expect(structField?.number == 5)
        var entries: [String: Data] = [:]
        var s = ProtoReader(structField!.value.asData!)
        while let f = s.next() {
            guard f.number == 1, let entry = f.value.asData else { continue }
            var e = ProtoReader(entry)
            var key = ""
            var value = Data()
            while let ef = e.next() {
                if ef.number == 1 { key = ef.value.asString ?? "" }
                if ef.number == 2 { value = ef.value.asData ?? Data() }
            }
            entries[key] = value
        }
        #expect(Set(entries.keys) == ["type", "required"])
        var typeReader = ProtoReader(entries["type"]!)
        let typeField = typeReader.next()
        #expect(typeField?.number == 3)
        #expect(typeField?.value.asString == "object")
    }

    @Test("malicious length varint aborts the parse instead of trapping")
    func maliciousLength() {
        // Field 1, wire type 2, declared length UInt64.max.
        var data = Data([0x0A])
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
        data.append(contentsOf: [0x00, 0x01])
        var reader = ProtoReader(data)
        #expect(reader.next() == nil)
    }
}

@Suite("Cursor stream state")
struct CursorStreamStateTests {
    private func makeState() -> CursorStreamState {
        CursorStreamState(
            api: "cursor-agent",
            model: Model(id: "auto", api: "cursor-agent", provider: "cursor")
        )
    }

    @Test("second thinking segment opens a fresh block with its own start event")
    func secondThinkingSegment() {
        let state = makeState()
        var events: [String] = []
        let emit: (AssistantMessageEvent) -> Void = { events.append($0.type) }
        state.appendThinking("first", emit: emit)
        state.endThinking(emit: emit)
        state.appendText("mid", emit: emit)
        state.appendThinking("second", emit: emit)
        state.endThinking(emit: emit)
        #expect(events.filter { $0 == "thinking_start" }.count == 2)
        #expect(events.filter { $0 == "thinking_end" }.count == 2)
        let final = state.finalize()
        let thinkingBlocks = final.content.compactMap { block -> String? in
            if case .thinking(let t) = block { return t.thinking }
            return nil
        }
        #expect(thinkingBlocks == ["first", "second"])
    }

    @Test("mcp tool call streams cumulative args snapshots and completes with merged args")
    func mcpToolCallStreaming() {
        let state = makeState()
        var events: [AssistantMessageEvent] = []
        let emit: (AssistantMessageEvent) -> Void = { events.append($0) }
        state.startMcpToolCall(id: "call-1", name: "search", emit: emit)
        state.appendToolCallArgs(snapshot: "{\"query\":", emit: emit)
        state.appendToolCallArgs(snapshot: "{\"query\":\"hi\"}", emit: emit)
        state.completeToolCall(completionArgs: .object(["extra": .int(1)]), emit: emit)

        let deltas = events.compactMap { event -> String? in
            if case .toolCallDelta(_, let delta, _) = event { return delta }
            return nil
        }
        #expect(deltas == ["{\"query\":", "\"hi\"}"])
        guard case .toolCallEnd(_, let call, _)? = events.last else {
            Issue.record("expected toolCallEnd")
            return
        }
        #expect(call.id == "call-1")
        #expect(call.name == "search")
        guard case .object(let args) = call.arguments else {
            Issue.record("expected object args")
            return
        }
        #expect(args["query"] == .string("hi"))
        #expect(args["extra"] == .int(1))
    }

    @Test("synthesized exec tool calls are marked resolved and pairable by id")
    func synthesizedExec() {
        let state = makeState()
        var events: [AssistantMessageEvent] = []
        state.synthesizeResolvedToolCall(
            id: "exec-1", name: "bash", arguments: .object(["command": .string("ls")]),
            emit: { events.append($0) }
        )
        let final = state.finalize()
        guard case .toolCall(let call)? = final.content.first else {
            Issue.record("expected toolCall block")
            return
        }
        #expect(call.cursorExecResolved == true)
        #expect(events.map(\.type) == ["toolcall_start", "toolcall_end"])
    }

    @Test("markToolCallResolved flags the matching streamed block")
    func markResolved() {
        let state = makeState()
        state.startMcpToolCall(id: "call-2", name: "search", emit: { _ in })
        state.completeToolCall(completionArgs: nil, emit: { _ in })
        #expect(state.markToolCallResolved(id: "call-2"))
        #expect(!state.markToolCallResolved(id: "missing"))
        guard case .toolCall(let call)? = state.finalize().content.first else {
            Issue.record("expected toolCall block")
            return
        }
        #expect(call.cursorExecResolved == true)
    }

    @Test("checkpoint used_tokens is only a fallback when no token deltas arrived")
    func usedTokensFallback() {
        let withDeltas = makeState()
        withDeltas.addOutputTokens(10)
        withDeltas.applyCheckpointUsedTokens(50_000)
        #expect(withDeltas.finalize().usage.output == 10)

        let withoutDeltas = makeState()
        withoutDeltas.applyCheckpointUsedTokens(321)
        #expect(withoutDeltas.finalize().usage.output == 321)
    }
}

@Suite("Cursor model routing")
struct CursorModelRoutingTests {

    @Test("reasoning level routes to the -thinking wire id via thinkingLevelMap")
    func wireModelRouting() {
        let model = Model(
            id: "claude-4.5-sonnet", api: "cursor-agent", provider: "cursor",
            reasoning: true,
            thinkingLevelMap: [
                "off": "claude-4.5-sonnet",
                "minimal": "claude-4.5-sonnet-thinking",
                "low": "claude-4.5-sonnet-thinking",
                "medium": "claude-4.5-sonnet-thinking",
                "high": "claude-4.5-sonnet-thinking",
            ]
        )
        #expect(CursorAgentProvider.wireModelId(model: model, reasoning: nil) == "claude-4.5-sonnet")
        #expect(CursorAgentProvider.wireModelId(model: model, reasoning: .medium) == "claude-4.5-sonnet-thinking")
        // Neither extended level is mapped, so both clamp down to high.
        #expect(CursorAgentProvider.wireModelId(model: model, reasoning: .xhigh) == "claude-4.5-sonnet-thinking")
        #expect(CursorAgentProvider.wireModelId(model: model, reasoning: .max) == "claude-4.5-sonnet-thinking")

        var maxOnly = model
        maxOnly.thinkingLevelMap = ["max": "claude-max"]
        // Clamping searches upward first: legacy xhigh callers route to max
        // when max is the model's only explicitly supported extended level.
        #expect(CursorAgentProvider.wireModelId(model: maxOnly, reasoning: .xhigh) == "claude-max")
        #expect(CursorAgentProvider.wireModelId(model: maxOnly, reasoning: .max) == "claude-max")
    }

    @Test("normalize applies curated capabilities and collapses -thinking variants")
    func curatedOverlay() {
        func usable(_ id: String) -> CursorProto.UsableModel {
            CursorProto.UsableModel(
                modelId: id, displayName: id, displayNameShort: "",
                displayModelId: "", aliases: [], hasThinking: false
            )
        }
        let models = CursorModelCatalog.normalize(
            [
                usable("claude-4.5-sonnet"), usable("claude-4.5-sonnet-thinking"),
                usable("brand-new-model"), usable("brand-new-model-thinking"),
                usable("composer-1.5"),
            ],
            host: "api2.cursor.sh"
        )
        let byId = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        // Curated: reasoning + image from the reference table; -thinking hidden.
        #expect(byId["claude-4.5-sonnet"]?.reasoning == true)
        #expect(byId["claude-4.5-sonnet"]?.input.contains(.image) == true)
        #expect(byId["claude-4.5-sonnet"]?.thinkingLevelMap?["high"] == "claude-4.5-sonnet-thinking")
        #expect(byId["claude-4.5-sonnet-thinking"] == nil)
        // Unknown model with a -thinking sibling gets the generic routing rule.
        #expect(byId["brand-new-model"]?.reasoning == true)
        #expect(byId["brand-new-model"]?.thinkingLevelMap?["high"] == "brand-new-model-thinking")
        #expect(byId["brand-new-model-thinking"] == nil)
        // Curated non-reasoning model stays non-reasoning.
        #expect(byId["composer-1.5"]?.reasoning == false)
    }
}

@Suite("Cursor OAuth")
struct CursorOAuthTests {

    @Test("jwt expiry claim is decoded to ms minus a 5-minute margin")
    func jwtExpiry() {
        // header.payload.signature with payload { "exp": 2000000000 }.
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let token = "\(b64url("{}")).\(b64url("{\"exp\":2000000000}")).sig"
        let expiry = OAuth.jwtExpiryMillis(token)
        let expected: Int64 = 2_000_000_000 * 1000 - 5 * 60 * 1000
        #expect(expiry == expected)
    }

    @Test("non-jwt token yields nil expiry")
    func nonJwt() {
        #expect(OAuth.jwtExpiryMillis("not-a-jwt") == nil)
    }

    @Test("refresh exchanges the refresh token for a fresh access token")
    func refresh() async throws {
        let client = SequentialStubClient()
        client.queue.append((
            status: 200,
            body: #"{"accessToken":"new-access","refreshToken":"new-refresh"}"#
        ))
        let provider = CursorOAuthProvider()
        let creds = OAuthCredentials(access: "old", refresh: "the-refresh", expires: 0)
        let refreshed = try await provider.refresh(creds, using: client)
        #expect(refreshed.access == "new-access")
        #expect(refreshed.refresh == "new-refresh")
        // The refresh token rides as the bearer with an empty JSON body.
        #expect(client.recorded[0].url.absoluteString.contains("exchange_user_api_key"))
        #expect(client.recorded[0].headers["authorization"] == "Bearer the-refresh")
    }

    @Test("refresh keeps the old refresh token when none is returned")
    func refreshKeepsToken() async throws {
        let client = SequentialStubClient()
        client.queue.append((status: 200, body: #"{"accessToken":"fresh"}"#))
        let provider = CursorOAuthProvider()
        let creds = OAuthCredentials(access: "old", refresh: "keep-me", expires: 0)
        let refreshed = try await provider.refresh(creds, using: client)
        #expect(refreshed.access == "fresh")
        #expect(refreshed.refresh == "keep-me")
    }
}
