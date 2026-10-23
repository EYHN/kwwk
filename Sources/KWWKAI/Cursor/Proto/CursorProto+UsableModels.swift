import Foundation

extension CursorProto {
    // MARK: - GetUsableModels (the kwwk-generate-cursor-models script, and `CursorModels.fetch` for hosts)

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
                modelId: "",
                displayName: "",
                displayNameShort: "",
                displayModelId: "",
                aliases: [],
                hasThinking: false
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

    /// `decodeUsableModels`, or nil for bytes that are no
    /// `GetUsableModelsResponse`. That decoder stops at the first field it
    /// cannot read and keeps what came before, so a web page, a JSON body
    /// or a cut-off reply reads as a short or empty list; a host listing an
    /// account's models must tell that from an account that has none. The
    /// bytes count as a reply when every field reads to the end, with field
    /// numbers above 0 and `models` and the fields of each `ModelDetails`
    /// length-delimited (the strings valid UTF-8). The models are then
    /// `decodeUsableModels`' own.
    static func decodeUsableModelsStrictly(_ data: Data) -> [UsableModel]? {
        var reader = ProtoReader(data)
        while let field = reader.next() {
            guard field.number > 0 else { return nil }
            guard field.number == 1 else { continue }
            guard let bytes = field.value.asData else { return nil }
            var inner = ProtoReader(bytes)
            while let f = inner.next() {
                switch f.number {
                case 0: return nil
                case 2: guard f.value.asData != nil else { return nil }
                case 1, 3, 4, 5, 6: guard f.value.asString != nil else { return nil }
                default: break
                }
            }
            guard inner.isAtEnd else { return nil }
        }
        guard reader.isAtEnd else { return nil }
        return decodeUsableModels(data)
    }
}
