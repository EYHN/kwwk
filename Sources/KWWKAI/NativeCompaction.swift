import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider-owned context, persisted with the recap and replayed without decoding
/// its opaque contents. Codex retains the source prefix for cross-provider use;
/// Anthropic already supplies a portable text summary.
public struct NativeCompactionPayload: Codable, Sendable, Hashable {
    public var provider: String
    public var api: String
    public var items: [JSONValue]
    public var fallbackMessages: [Message]?

    public init(model: Model, items: [JSONValue], fallbackMessages: [Message]? = nil) {
        provider = model.provider
        api = model.api
        self.items = items
        self.fallbackMessages = fallbackMessages
    }

    public func canReplay(with model: Model) -> Bool {
        guard provider == model.provider && api == model.api,
              model.compat?.supportsServerCompaction != false else { return false }
        return api != "anthropic-messages" || AnthropicProvider.supportsNativeCompaction(model: model)
    }

    public var textSummary: String? {
        guard api == "anthropic-messages" else { return nil }
        return items.compactMap { item in
            if case .string(let text) = item["content"] { return text }
            return nil
        }.joined(separator: "\n")
    }
}

public struct NativeCompactionResult: Sendable {
    public var summary: String
    public var payload: NativeCompactionPayload
    public init(summary: String, payload: NativeCompactionPayload) {
        self.summary = summary
        self.payload = payload
    }
}

/// Return nil when the route does not support native compaction. Errors from
/// an available route remain errors so authentication and outages stay visible.
public protocol NativeCompactionProvider: APIProvider {
    func compact(model: Model, context: Context, instructions: String,
                 options: StreamOptions?) async throws -> NativeCompactionResult?
}

public typealias NativeCompactionFn = @Sendable (
    Model, Context, String, StreamOptions?
) async throws -> NativeCompactionResult?

public func compactNative(model: Model, context: Context, instructions: String,
                          options: StreamOptions?) async throws -> NativeCompactionResult? {
    guard let provider = await APIRegistry.shared.provider(scope: model.provider, api: model.api)
        as? any NativeCompactionProvider else { return nil }
    return try await provider.compact(model: model, context: context,
                                      instructions: instructions, options: options)
}

extension HTTPClient {
    /// Codex V2 must finish and supply exactly one native compaction item.
    /// A partial item followed by EOF must never replace the source history.
    func compactionSSE(url: URL, headers: [String: String], body: Data,
                       cancellation: CancellationHandle?) async throws -> JSONValue {
        try cancellation?.throwIfCancelled()
        let (response, chunks) = try await stream(url: url, method: "POST", headers: headers,
            body: body, cancellation: cancellation, timeoutSeconds: 300)
        guard (200..<300).contains(response.statusCode) else {
            throw await ProviderFailure.http(response, body: chunks)
        }
        var items: [JSONValue] = []
        var completed = false
        for try await event in parseSSE(bytes: chunks) {
            try cancellation?.throwIfCancelled()
            if event.data == "[DONE]" { continue }
            guard let json = parseJSONObject(event.data) else {
                throw ProviderFailure(message: "Invalid native compaction stream event")
            }
            let type = json["type"] ?? .string(event.event)
            if type == "response.output_item.done", let item = json["item"], item["type"] == "compaction" {
                items.append(item)
            } else if type == "response.completed" || type == "response.done" {
                completed = true
                break
            } else if type == "error" || type == "response.failed" || type == "response.incomplete" {
                throw ProviderFailure.payload(json["response"] ?? json, fallback: "Native compaction failed")
            }
        }
        guard completed else { throw ProviderFailure(message: "Native compaction stream closed before response.completed") }
        guard items.count == 1, case .string(let encrypted) = items[0]["encrypted_content"], !encrypted.isEmpty else {
            throw ProviderFailure(message: "Invalid native compaction output: expected exactly one nonempty compaction item")
        }
        return items[0]
    }

    func compactionJSON(url: URL, headers: [String: String], body: Data,
                        cancellation: CancellationHandle?) async throws -> [String: JSONValue] {
        try cancellation?.throwIfCancelled()
        let (response, chunks) = try await stream(url: url, method: "POST", headers: headers,
                                                body: body, cancellation: cancellation, timeoutSeconds: 300)
        guard (200..<300).contains(response.statusCode) else {
            throw await ProviderFailure.http(response, body: chunks)
        }
        var data = Data()
        for try await chunk in chunks {
            try cancellation?.throwIfCancelled()
            data.append(chunk)
        }
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }
}
