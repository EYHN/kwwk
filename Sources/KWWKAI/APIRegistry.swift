import Foundation

/// A registered provider that knows how to stream assistant messages for a
/// specific `api` identifier. Provider instances are responsible for surfacing
/// errors via stream events (never via thrown errors).
public protocol APIProvider: Sendable {
    var api: String { get }
    func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream
}

/// Optional provider lifecycle hook for resources keyed by
/// `StreamOptions.sessionId` (for example, persistent WebSocket
/// connections). Providers that do not keep per-session resources do not need
/// to conform.
public protocol APIProviderSessionLifecycle: Sendable {
    func closeSession(sessionId: String) async
}

/// A globally addressable registry of `APIProvider` instances.
///
/// Two dispatch layers coexist so that multiple logged-in providers can share
/// one wire protocol without clobbering each other:
///
///   - **Flat**, keyed by `api` string. This is the single-login / env-key
///     path — one provider per wire protocol.
///   - **Provider-scoped**, keyed by `(providerScope, api)`. When several
///     accounts speak the same wire (e.g. Anthropic-OAuth and GitHub-Copilot's
///     Claude models both ride `anthropic-messages`, with different tokens and
///     headers), each registers under its own `providerScope` — the model's
///     `provider` field. Dispatch prefers a scoped match and falls back to the
///     flat map, so existing single-login behavior is unchanged.
///
/// Registrations can be tagged with an opaque `sourceId` so groups of
/// providers can be removed together.
public actor APIRegistry {
    public static let shared = APIRegistry()

    private var providers: [String: APIProvider] = [:]
    /// `providerScope → api → provider`. Populated when `register` is given a
    /// `scope`. Looked up first by `stream`, keyed on `model.provider`.
    private var scoped: [String: [String: APIProvider]] = [:]
    /// `sourceId → set of "scope\u{1}api"` (scope empty for flat entries), so a
    /// source can be torn down across both maps.
    private var bySource: [String: Set<String>] = [:]

    public init() {}

    /// Register `provider`. Without `scope`, it lands in the flat map keyed by
    /// its `api` (legacy behavior). With `scope`, it also lands in the
    /// provider-scoped map under `(scope, api)` so it can coexist with other
    /// providers sharing the same wire `api`.
    public func register(_ provider: APIProvider, scope: String? = nil, sourceId: String? = nil) {
        if let scope, !scope.isEmpty {
            scoped[scope, default: [:]][provider.api] = provider
            if let sourceId {
                bySource[sourceId, default: []].insert("\(scope)\u{1}\(provider.api)")
            }
        } else {
            providers[provider.api] = provider
            if let sourceId {
                bySource[sourceId, default: []].insert("\u{1}\(provider.api)")
            }
        }
    }

    public func provider(for api: String) -> APIProvider? {
        providers[api]
    }

    /// Resolve the provider for a model: prefer a provider-scoped match on
    /// `(scope, api)`, then fall back to the flat `api` map.
    public func provider(scope: String, api: String) -> APIProvider? {
        scoped[scope]?[api] ?? providers[api]
    }

    public func unregister(api: String) {
        providers.removeValue(forKey: api)
        for key in bySource.keys {
            bySource[key]?.remove("\u{1}\(api)")
        }
    }

    public func unregisterScope(_ scope: String) {
        scoped.removeValue(forKey: scope)
        for key in bySource.keys {
            bySource[key] = bySource[key]?.filter { !$0.hasPrefix("\(scope)\u{1}") }
        }
    }

    public func unregisterSource(_ sourceId: String) {
        guard let keys = bySource.removeValue(forKey: sourceId) else { return }
        for key in keys {
            guard let sep = key.firstIndex(of: "\u{1}") else { continue }
            let scope = String(key[..<sep])
            let api = String(key[key.index(after: sep)...])
            if scope.isEmpty {
                providers.removeValue(forKey: api)
            } else {
                scoped[scope]?.removeValue(forKey: api)
                if scoped[scope]?.isEmpty == true { scoped.removeValue(forKey: scope) }
            }
        }
    }

    public func closeSession(sessionId: String) async {
        guard !sessionId.isEmpty else { return }
        var snapshot = Array(providers.values)
        for byApi in scoped.values { snapshot.append(contentsOf: byApi.values) }
        for provider in snapshot {
            guard let lifecycle = provider as? APIProviderSessionLifecycle else { continue }
            await lifecycle.closeSession(sessionId: sessionId)
        }
    }
}

public enum ProviderNotFoundError: Error, Equatable {
    case api(String)
}

/// Top-level streaming entry point. Looks up the registered provider for the
/// model's `api` and delegates to it. Throws if no provider is registered.
public func stream(model: Model, context: Context, options: StreamOptions? = nil) async throws -> AssistantMessageStream {
    guard let provider = await APIRegistry.shared.provider(scope: model.provider, api: model.api) else {
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

/// Close provider-owned resources associated with a session id across every
/// registered provider. This is intentionally provider-scoped: higher layers
/// remain responsible for their own session-scoped resources such as
/// background tasks.
public func closeProviderSession(sessionId: String) async {
    await APIRegistry.shared.closeSession(sessionId: sessionId)
}
