import Foundation

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

public struct NativeCompactionError: Error, LocalizedError, Sendable {
    public var status: Int?
    public var message: String
    public var errorDescription: String? { message }
    public init(status: Int? = nil, message: String) {
        self.status = status
        self.message = message
    }
}

extension HTTPClient {
    func compactionJSON(url: URL, headers: [String: String], body: Data,
                        cancellation: CancellationHandle?) async throws -> [String: JSONValue] {
        try cancellation?.throwIfCancelled()
        let (response, chunks) = try await stream(url: url, method: "POST", headers: headers,
                                                body: body, cancellation: cancellation, timeoutSeconds: 300)
        var data = Data()
        for try await chunk in chunks {
            try cancellation?.throwIfCancelled()
            data.append(chunk)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw NativeCompactionError(status: response.statusCode,
                message: "Compaction HTTP \(response.statusCode): \(String(decoding: data, as: UTF8.self))")
        }
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }
}
