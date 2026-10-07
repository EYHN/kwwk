import Foundation

/// Hand-rolled protobuf codec for the slice of Codeium Cascade's `exa.*`
/// schema the Devin provider speaks (ported from oh-my-pi's generated
/// `devin-proto.ts`). Field numbers come from the vendored `.proto` sources
/// (`exa/codeium_common_pb`, `exa/chat_pb`, `exa/api_server_pb`,
/// `exa/auth_pb`). Only fields kwwk reads or writes are modelled; unknown
/// fields are skipped on decode.
enum DevinProto {

    // MARK: - Enums

    enum ChatMessageSource: UInt64 {
        case user = 1
        case system = 2
        case tool = 4
    }

    /// `exa.codeium_common_pb.StopReason` values the provider distinguishes.
    enum StopReason {
        static let unspecified: UInt64 = 0
        static let maxTokens: UInt64 = 3
    }

    static let chatMessageRequestTypeCascade: UInt64 = 5
    static let plannerModeDefault: UInt64 = 1
    static let cacheControlEphemeral: UInt64 = 1

    /// `exa.codeium_common_pb.DisplayOption`. Values 6-8 postdate the vendored
    /// descriptor but are plain int32 on the wire.
    enum DisplayOption {
        static let unspecified: UInt64 = 0
        static let modelRouter: UInt64 = 3
        static let quickReview: UInt64 = 4
        static let internalDefault: UInt64 = 6
        static let unclassified: UInt64 = 7
        static let normal: UInt64 = 8
    }

    enum ModelDimensionKind {
        static let cost: UInt64 = 1
        static let costFuzzy: UInt64 = 2
    }

    // MARK: - Metadata (exa.codeium_common_pb.Metadata)

    struct Metadata: Sendable, Equatable {
        var ideName = ""
        var ideVersion = ""
        var ideType = ""
        var extensionName = ""
        var extensionVersion = ""
        var apiKey = ""
        var locale = ""
        var os = ""
        var userJwt = ""
        var supportedModelDisplays: [UInt64] = []

        func encode() -> Data {
            var w = ProtoWriter()
            if !ideName.isEmpty { w.stringField(1, ideName) }
            if !extensionVersion.isEmpty { w.stringField(2, extensionVersion) }
            if !apiKey.isEmpty { w.stringField(3, apiKey) }
            if !locale.isEmpty { w.stringField(4, locale) }
            if !os.isEmpty { w.stringField(5, os) }
            if !ideVersion.isEmpty { w.stringField(7, ideVersion) }
            if !extensionName.isEmpty { w.stringField(12, extensionName) }
            if !userJwt.isEmpty { w.stringField(21, userJwt) }
            if !ideType.isEmpty { w.stringField(28, ideType) }
            if !supportedModelDisplays.isEmpty {
                // proto3 packs repeated scalars.
                var packed = ProtoWriter()
                for value in supportedModelDisplays { packed.rawVarint(value) }
                w.bytesField(30, packed.data)
            }
            return w.data
        }
    }

    // MARK: - Chat request pieces

    struct ImageData: Sendable, Equatable {
        var base64Data: String
        var mimeType: String

        func encode() -> Data {
            var w = ProtoWriter()
            if !base64Data.isEmpty { w.stringField(1, base64Data) }
            if !mimeType.isEmpty { w.stringField(2, mimeType) }
            return w.data
        }
    }

    struct ChatToolCall: Sendable, Equatable {
        var id = ""
        var name = ""
        var argumentsJson = ""

        func encode() -> Data {
            var w = ProtoWriter()
            if !id.isEmpty { w.stringField(1, id) }
            if !name.isEmpty { w.stringField(2, name) }
            if !argumentsJson.isEmpty { w.stringField(3, argumentsJson) }
            return w.data
        }

        static func decode(_ data: Data) -> ChatToolCall {
            var call = ChatToolCall()
            var r = ProtoReader(data)
            while let f = r.next() {
                switch f.number {
                case 1: call.id = f.value.asString ?? ""
                case 2: call.name = f.value.asString ?? ""
                case 3: call.argumentsJson = f.value.asString ?? ""
                default: break
                }
            }
            return call
        }
    }

    struct ChatMessagePrompt: Sendable, Equatable {
        var messageId = ""
        var source: ChatMessageSource = .user
        var prompt = ""
        var toolCalls: [ChatToolCall] = []
        var toolCallId = ""
        var toolResultIsError = false
        var images: [ImageData] = []
        var thinking = ""
        var signature = ""

        func encode() -> Data {
            var w = ProtoWriter()
            if !messageId.isEmpty { w.stringField(1, messageId) }
            w.varintField(2, source.rawValue)
            if !prompt.isEmpty { w.stringField(3, prompt) }
            for call in toolCalls { w.bytesField(6, call.encode()) }
            if !toolCallId.isEmpty { w.stringField(7, toolCallId) }
            if toolResultIsError { w.boolField(9, true) }
            for image in images { w.bytesField(10, image.encode()) }
            if !thinking.isEmpty { w.stringField(11, thinking) }
            if !signature.isEmpty { w.stringField(12, signature) }
            return w.data
        }
    }

    struct ChatToolDefinition: Sendable, Equatable {
        var name: String
        var description: String
        var jsonSchemaString: String
        var strict = false

        func encode() -> Data {
            var w = ProtoWriter()
            if !name.isEmpty { w.stringField(1, name) }
            if !description.isEmpty { w.stringField(2, description) }
            if !jsonSchemaString.isEmpty { w.stringField(3, jsonSchemaString) }
            if strict { w.boolField(12, true) }
            return w.data
        }
    }

    struct CompletionConfiguration: Sendable, Equatable {
        var numCompletions: UInt64 = 1
        var maxTokens: UInt64
        var maxNewlines: UInt64 = 200
        var temperature: Double
        var firstTemperature: Double
        var topK: UInt64 = 50
        var topP: Double
        var stopPatterns: [String]
        var fimEotProbThreshold: Double = 1

        func encode() -> Data {
            var w = ProtoWriter()
            if numCompletions != 0 { w.varintField(1, numCompletions) }
            if maxTokens != 0 { w.varintField(2, maxTokens) }
            if maxNewlines != 0 { w.varintField(3, maxNewlines) }
            if temperature != 0 { w.doubleField(5, temperature) }
            if firstTemperature != 0 { w.doubleField(6, firstTemperature) }
            if topK != 0 { w.varintField(7, topK) }
            if topP != 0 { w.doubleField(8, topP) }
            for pattern in stopPatterns { w.stringField(9, pattern) }
            if fimEotProbThreshold != 0 { w.doubleField(11, fimEotProbThreshold) }
            return w.data
        }
    }

    /// `exa.api_server_pb.GetChatMessageRequest`.
    struct GetChatMessageRequest: Sendable, Equatable {
        var metadata: Metadata
        var prompt: String
        var chatMessagePrompts: [ChatMessagePrompt]
        var chatModelUid: String
        var configuration: CompletionConfiguration
        var tools: [ChatToolDefinition]
        var disableParallelToolCalls: Bool
        var cascadeId: String
        var executionId: String
        var modelAssignmentJwt: String?

        func encode() -> Data {
            var w = ProtoWriter()
            w.bytesField(1, metadata.encode())
            if !prompt.isEmpty { w.stringField(2, prompt) }
            for p in chatMessagePrompts { w.bytesField(3, p.encode()) }
            w.varintField(7, chatMessageRequestTypeCascade)
            w.bytesField(8, configuration.encode())
            for t in tools { w.bytesField(10, t.encode()) }
            if disableParallelToolCalls { w.boolField(11, true) }
            // ChatToolChoice { option_name = 1 } = "auto"
            w.messageField(12) { $0.stringField(1, "auto") }
            // PromptCacheOptions { type = 1 } = EPHEMERAL
            w.messageField(13) { $0.varintField(1, cacheControlEphemeral) }
            if !cascadeId.isEmpty { w.stringField(16, cascadeId) }
            w.varintField(20, plannerModeDefault)
            if !chatModelUid.isEmpty { w.stringField(21, chatModelUid) }
            if !executionId.isEmpty { w.stringField(22, executionId) }
            if let jwt = modelAssignmentJwt, !jwt.isEmpty { w.stringField(26, jwt) }
            return w.data
        }

        /// Encoded size of the history field alone — the part context
        /// maintenance can shrink (used by large-history error recovery).
        static func historyByteCount(_ prompts: [ChatMessagePrompt]) -> Int {
            var w = ProtoWriter()
            for p in prompts { w.bytesField(3, p.encode()) }
            return w.data.count
        }
    }

    // MARK: - Chat response

    struct ModelUsageStats: Sendable, Equatable {
        var inputTokens: UInt64 = 0
        var outputTokens: UInt64 = 0
        var cacheWriteTokens: UInt64 = 0
        var cacheReadTokens: UInt64 = 0

        static func decode(_ data: Data) -> ModelUsageStats {
            var usage = ModelUsageStats()
            var r = ProtoReader(data)
            while let f = r.next() {
                switch f.number {
                case 2: usage.inputTokens = f.value.asUInt64 ?? 0
                case 3: usage.outputTokens = f.value.asUInt64 ?? 0
                case 4: usage.cacheWriteTokens = f.value.asUInt64 ?? 0
                case 5: usage.cacheReadTokens = f.value.asUInt64 ?? 0
                default: break
                }
            }
            return usage
        }
    }

    /// `exa.api_server_pb.GetChatMessageResponse` (one streamed delta).
    struct GetChatMessageResponse: Sendable, Equatable {
        var messageId = ""
        var deltaText = ""
        var stopReason: UInt64 = StopReason.unspecified
        var deltaToolCalls: [ChatToolCall] = []
        var usage: ModelUsageStats?
        var deltaThinking = ""
        var deltaSignature = ""
        var actualModelUid: String?

        static func decode(_ data: Data) -> GetChatMessageResponse {
            var msg = GetChatMessageResponse()
            var r = ProtoReader(data)
            while let f = r.next() {
                switch f.number {
                case 1: msg.messageId = f.value.asString ?? ""
                case 3: msg.deltaText = f.value.asString ?? ""
                case 5: msg.stopReason = f.value.asUInt64 ?? 0
                case 6: if let d = f.value.asData { msg.deltaToolCalls.append(.decode(d)) }
                case 7: if let d = f.value.asData { msg.usage = .decode(d) }
                case 9: msg.deltaThinking = f.value.asString ?? ""
                case 10: msg.deltaSignature = f.value.asString ?? ""
                case 23: msg.actualModelUid = f.value.asString
                default: break
                }
            }
            return msg
        }
    }

    // MARK: - Auth (exa.auth_pb)

    static func encodeGetUserJwtRequest(metadata: Metadata) -> Data {
        var w = ProtoWriter()
        w.bytesField(1, metadata.encode())
        return w.data
    }

    struct GetUserJwtResponse: Sendable, Equatable {
        var userJwt = ""
        var customApiServerUrl = ""

        static func decode(_ data: Data) -> GetUserJwtResponse {
            var out = GetUserJwtResponse()
            var r = ProtoReader(data)
            while let f = r.next() {
                switch f.number {
                case 1: out.userJwt = f.value.asString ?? ""
                case 2: out.customApiServerUrl = f.value.asString ?? ""
                default: break
                }
            }
            return out
        }
    }

    // MARK: - Router assignment (AssignModel)

    static func encodeAssignModelRequest(
        metadata: Metadata, modelRouterUid: String, cascadeId: String, prompt: ChatMessagePrompt?
    ) -> Data {
        var w = ProtoWriter()
        w.bytesField(1, metadata.encode())
        if !modelRouterUid.isEmpty { w.stringField(2, modelRouterUid) }
        if !cascadeId.isEmpty { w.stringField(3, cascadeId) }
        if let prompt { w.bytesField(5, prompt.encode()) }
        return w.data
    }

    struct ModelAssignment: Sendable, Equatable {
        var assignmentJwt = ""
        var modelUid = ""
    }

    static func decodeAssignModelResponse(_ data: Data) -> ModelAssignment? {
        var r = ProtoReader(data)
        while let f = r.next() {
            guard f.number == 1, let bytes = f.value.asData else { continue }
            var assignment = ModelAssignment()
            var inner = ProtoReader(bytes)
            while let g = inner.next() {
                switch g.number {
                case 1: assignment.assignmentJwt = g.value.asString ?? ""
                case 2: assignment.modelUid = g.value.asString ?? ""
                default: break
                }
            }
            return assignment
        }
        return nil
    }

    // MARK: - Model discovery (GetCliModelConfigs)

    static func encodeGetCliModelConfigsRequest(metadata: Metadata) -> Data {
        var w = ProtoWriter()
        w.bytesField(1, metadata.encode())
        return w.data
    }

    struct ModelFeatures: Sendable, Equatable {
        var supportsImages = false
        var supportsToolCalls = false
        var supportsParallelToolCalls = false
        var supportsThinking = false
    }

    struct ModelInfo: Sendable, Equatable {
        var modelFeatures: ModelFeatures?
        var maxOutputTokens: Int32 = 0
        var harnessUids: [String] = []
        var displayOption: UInt64 = DisplayOption.unspecified
        var isModelRouter = false
    }

    struct ModelFamilyEntry: Sendable, Equatable {
        var key = ""
        var order: Int32 = 0
        var name = ""
        var hasValue = false
    }

    struct ModelFamilyMetadata: Sendable, Equatable {
        var label = ""
        var entries: [ModelFamilyEntry] = []
        var isDefaultModelInFamily = false
    }

    struct ModelDimension: Sendable, Equatable {
        var label = ""
        var value: Float = 0
        var denominator = ""
        var kind: UInt64 = 0
    }

    /// `exa.codeium_common_pb.ClientModelConfig`.
    struct ClientModelConfig: Sendable, Equatable {
        var label = ""
        var modelUid = ""
        var disabled = false
        var supportsImages = false
        var isBeta = false
        var isRecommended = false
        var isNew = false
        var maxTokens: Int32 = 0
        var modelInfo: ModelInfo?
        var description: String?
        var modelFamilyMetadata: ModelFamilyMetadata?
        var isDefaultModelInFamily = false
        var modelDimensions: [ModelDimension] = []
    }

    static func decodeGetCliModelConfigsResponse(_ data: Data) -> [ClientModelConfig] {
        var configs: [ClientModelConfig] = []
        var r = ProtoReader(data)
        while let f = r.next() {
            if f.number == 1, let bytes = f.value.asData {
                configs.append(decodeClientModelConfig(bytes))
            }
        }
        return configs
    }

    static func decodeClientModelConfig(_ data: Data) -> ClientModelConfig {
        var c = ClientModelConfig()
        var r = ProtoReader(data)
        while let f = r.next() {
            switch f.number {
            case 1: c.label = f.value.asString ?? ""
            case 4: c.disabled = f.value.asBool ?? false
            case 5: c.supportsImages = f.value.asBool ?? false
            case 9: c.isBeta = f.value.asBool ?? false
            case 11: c.isRecommended = f.value.asBool ?? false
            case 15: c.isNew = f.value.asBool ?? false
            case 18: c.maxTokens = f.value.asInt32 ?? 0
            case 22: c.modelUid = f.value.asString ?? ""
            case 23: if let d = f.value.asData { c.modelInfo = decodeModelInfo(d) }
            case 27: c.description = f.value.asString
            case 30: if let d = f.value.asData { c.modelFamilyMetadata = decodeFamilyMetadata(d) }
            case 31: c.isDefaultModelInFamily = f.value.asBool ?? false
            case 32: if let d = f.value.asData { c.modelDimensions.append(decodeDimension(d)) }
            default: break
            }
        }
        return c
    }

    private static func decodeModelInfo(_ data: Data) -> ModelInfo {
        var info = ModelInfo()
        var r = ProtoReader(data)
        while let f = r.next() {
            switch f.number {
            case 6:
                guard let bytes = f.value.asData else { break }
                var features = ModelFeatures()
                var inner = ProtoReader(bytes)
                while let g = inner.next() {
                    switch g.number {
                    case 11: features.supportsImages = g.value.asBool ?? false
                    case 12: features.supportsToolCalls = g.value.asBool ?? false
                    case 15: features.supportsThinking = g.value.asBool ?? false
                    case 21: features.supportsParallelToolCalls = g.value.asBool ?? false
                    default: break
                    }
                }
                info.modelFeatures = features
            case 13: info.maxOutputTokens = f.value.asInt32 ?? 0
            case 20: if let s = f.value.asString { info.harnessUids.append(s) }
            case 22: info.displayOption = f.value.asUInt64 ?? 0
            case 25: info.isModelRouter = f.value.asBool ?? false
            default: break
            }
        }
        return info
    }

    private static func decodeFamilyMetadata(_ data: Data) -> ModelFamilyMetadata {
        var meta = ModelFamilyMetadata()
        var r = ProtoReader(data)
        while let f = r.next() {
            switch f.number {
            case 1: meta.label = f.value.asString ?? ""
            case 2:
                guard let bytes = f.value.asData else { break }
                var entry = ModelFamilyEntry()
                var inner = ProtoReader(bytes)
                while let g = inner.next() {
                    switch g.number {
                    case 1: entry.key = g.value.asString ?? ""
                    case 2:
                        guard let valueBytes = g.value.asData else { break }
                        entry.hasValue = true
                        var vr = ProtoReader(valueBytes)
                        while let h = vr.next() {
                            switch h.number {
                            case 1: entry.order = h.value.asInt32 ?? 0
                            case 2: entry.name = h.value.asString ?? ""
                            default: break
                            }
                        }
                    default: break
                    }
                }
                meta.entries.append(entry)
            case 3: meta.isDefaultModelInFamily = f.value.asBool ?? false
            default: break
            }
        }
        return meta
    }

    private static func decodeDimension(_ data: Data) -> ModelDimension {
        var dim = ModelDimension()
        var r = ProtoReader(data)
        while let f = r.next() {
            switch f.number {
            case 1: dim.label = f.value.asString ?? ""
            case 2: if case .fixed32(let bits) = f.value { dim.value = Float(bitPattern: bits) }
            case 3: dim.denominator = f.value.asString ?? ""
            case 6: dim.kind = f.value.asUInt64 ?? 0
            default: break
            }
        }
        return dim
    }

    // MARK: - Unary body decoding

    /// Unary Connect responses arrive as bare protobuf or a gzipped body
    /// (URLSession usually decompresses `content-encoding: gzip` already).
    static func unaryPayload(_ body: Data) -> Data {
        if Gzip.isGzip(body), let inflated = try? Gzip.decompress(body) { return inflated }
        return body
    }
}
