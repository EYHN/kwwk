import Foundation

/// A registered provider that knows how to stream assistant messages for a
/// specific `api` identifier. Provider instances are responsible for surfacing
/// errors via stream events (never via thrown errors).
public protocol APIProvider: Sendable {
    var api: String { get }
    func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream
}

/// A globally addressable registry of `APIProvider` instances, keyed by
/// `api` string. Registrations can be tagged with an opaque `sourceId` so
/// groups of providers can be removed together.
public actor APIRegistry {
    public static let shared = APIRegistry()

    private var providers: [String: APIProvider] = [:]
    private var bySource: [String: Set<String>] = [:]

    public init() {}

    public func register(_ provider: APIProvider, sourceId: String? = nil) {
        providers[provider.api] = provider
        if let sourceId {
            bySource[sourceId, default: []].insert(provider.api)
        }
    }

    public func provider(for api: String) -> APIProvider? {
        providers[api]
    }

    public func unregister(api: String) {
        providers.removeValue(forKey: api)
        for key in bySource.keys {
            bySource[key]?.remove(api)
        }
    }

    public func unregisterSource(_ sourceId: String) {
        guard let apis = bySource.removeValue(forKey: sourceId) else { return }
        for api in apis {
            providers.removeValue(forKey: api)
        }
    }
}

public enum ProviderNotFoundError: Error, Equatable {
    case api(String)
}

/// Top-level streaming entry point. Looks up the registered provider for the
/// model's `api` and delegates to it. Throws if no provider is registered.
public func stream(model: Model, context: Context, options: StreamOptions? = nil) async throws -> AssistantMessageStream {
    guard let provider = await APIRegistry.shared.provider(for: model.api) else {
        throw ProviderNotFoundError.api(model.api)
    }
    return provider.stream(model: model, context: context, options: options)
}

/// Convenience: run a stream to completion and return the final message.
public func complete(model: Model, context: Context, options: StreamOptions? = nil) async throws -> AssistantMessage {
    let s = try await stream(model: model, context: context, options: options)
    // Drain events so producers aren't blocked waiting for consumption.
    for await _ in s {}
    return await s.result()
}
