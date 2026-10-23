import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An account's own Cursor model list, for hosts that serve more than one
/// login (AirBuild's backend lists each user's models with their own
/// sign-in). kwwk itself runs on the bundled catalog and never calls this.
///
/// It asks what `CursorModelCatalog.fetchUsableModels` asks — the same two
/// RPCs, the same headers, the same `normalize` — so one reply makes the
/// same models. What differs is what a runtime caller needs and the
/// generate script does not:
///
/// - a refusal is a ``ProviderFailure`` with Cursor's code and words, its
///   `Retry-After` and request id, not a bare status and body;
/// - a team Cursor serves in one region only is listed on the agent API the
///   server config names, as its Runs are run there (``CursorAgentEndpoint``);
/// - an account with no models is an empty list, and a reply that cannot be
///   read is a failure, not one of the two passed off as the other;
/// - a picker Cursor cannot give is said, in ``Listing/pickerApplied``.
public enum CursorModels {
    public struct Listing: Sendable, Hashable {
        /// The account's models, sorted by id; each names `host` as its
        /// base URL, whichever API served the list — the Run finds its own
        /// way to a region's agent API.
        public var models: [Model]
        /// Whether each model's window and image input are the picker's
        /// (`AvailableModels`). False when the picker could not be had or
        /// read — the models then carry the curated table's and the
        /// defaults, as `fetchUsableModels` gives them — and when there
        /// were no models to apply it to.
        public var pickerApplied: Bool

        public init(
            models: [Model],
            pickerApplied: Bool
        ) {
            self.models = models
            self.pickerApplied = pickerApplied
        }
    }

    /// List the models of the account behind `credentials`.
    ///
    /// Throws a ``ProviderFailure`` when Cursor refuses the list, cannot be
    /// reached, or answers with something that is no list, and
    /// `CancellationError` when the calling task is cancelled.
    public static func fetch(
        credentials: OAuthCredentials,
        host: String = CursorAgentProvider.defaultBaseHost,
        clientVersion: String = CursorAgentProvider.defaultClientVersion,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> Listing {
        // The client's wait for response headers is out of reach of task
        // cancellation; the handle reaches it.
        let cancellation = CancellationHandle()
        return try await withTaskCancellationHandler {
            try await list(
                apiKey: credentials.access,
                host: host,
                clientVersion: clientVersion,
                client: client,
                cancellation: cancellation
            )
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func list(
        apiKey: String,
        host: String,
        clientVersion: String,
        client: HTTPClient,
        cancellation: CancellationHandle
    ) async throws -> Listing {
        let api = CursorAgentEndpoint(host: host)
        let response: HTTPURLResponse
        let body: Data
        do {
            (response, body) = try await usableModels(
                at: api,
                apiKey: apiKey,
                clientVersion: clientVersion,
                client: client,
                cancellation: cancellation
            )
        } catch let refusal as ProviderFailure where CursorAgentEndpoint.isRegionRefusal(refusal) {
            // Once more on the agent API the server config names, as a Run
            // refused over a region is; the refusal stands when the config
            // names none or the one that refused. Nothing is remembered:
            // the Run keeps its own record (`CursorAgentProvider.endpoints`).
            let named = await CursorAgentEndpoint.resolve(
                apiKey: apiKey,
                apiHost: host,
                clientVersion: clientVersion,
                client: client,
                cancellation: cancellation
            )
            try Task.checkCancellation()
            guard let named, named != api else { throw refusal }
            (response, body) = try await usableModels(
                at: named,
                apiKey: apiKey,
                clientVersion: clientVersion,
                client: client,
                cancellation: cancellation
            )
        }
        guard let usable = readUsableModels(body, response: response) else {
            throw unreadable(body, response: response)
        }
        guard !usable.isEmpty else { return Listing(models: [], pickerApplied: false) }
        let picker = try await pickerFacts(
            apiKey: apiKey,
            host: host,
            clientVersion: clientVersion,
            client: client,
            cancellation: cancellation
        )
        return Listing(
            models: CursorModelCatalog.normalize(usable, host: host, picker: picker ?? [:]),
            pickerApplied: picker != nil
        )
    }

    // MARK: - The two RPCs

    /// `GetUsableModels` at `endpoint`, asked as `fetchUsableModels` asks
    /// it; a reply outside 2xx is thrown as its ``ProviderFailure``.
    static func usableModels(
        at endpoint: CursorAgentEndpoint,
        apiKey: String,
        clientVersion: String,
        client: HTTPClient,
        cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, Data) {
        let port = endpoint.port == 443 ? "" : ":\(endpoint.port)"
        let rpc = endpoint.path("/agent.v1.AgentService/GetUsableModels")
        guard let url = URL(string: "https://\(endpoint.host)\(port)\(rpc)") else {
            throw ProviderFailure(message: "Cursor: invalid host \(endpoint.host)")
        }
        let (response, body) = try await post(
            url: url,
            headers: [
                "content-type": "application/proto",
                "authorization": "Bearer \(apiKey)",
                "x-ghost-mode": "true",
                "x-cursor-client-version": clientVersion,
                "x-cursor-client-type": "cli",
                "x-request-id": UUID().uuidString,
            ],
            body: CursorProto.encodeGetUsableModelsRequest(),
            client: client,
            cancellation: cancellation
        )
        guard (200..<300).contains(response.statusCode) else { throw failure(response, body: body) }
        return (response, body)
    }

    /// What the picker says of each wire id, asked as `fetchPickerFacts`
    /// asks it; nil when it cannot be had or its reply holds no model list.
    /// Only a cancel is thrown: the list stands without the picker.
    static func pickerFacts(
        apiKey: String,
        host: String,
        clientVersion: String,
        client: HTTPClient,
        cancellation: CancellationHandle?
    ) async throws -> [String: CursorModelCatalog.PickerFacts]? {
        guard let url = URL(string: "https://\(host)/aiserver.v1.AiService/AvailableModels") else { return nil }
        let response: HTTPURLResponse
        let body: Data
        do {
            (response, body) = try await post(
                url: url,
                headers: [
                    "content-type": "application/json",
                    "connect-protocol-version": "1",
                    "authorization": "Bearer \(apiKey)",
                    "x-ghost-mode": "true",
                    "x-cursor-client-version": clientVersion,
                    "x-cursor-client-type": "cli",
                ],
                body: Data(#"{"useModelParameters":true,"doNotUseMarkdown":true}"#.utf8),
                client: client,
                cancellation: cancellation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        // `pickerFacts(fromAvailableModels:)` reads a reply it cannot make
        // out as a picker with nothing to say; here that is no picker.
        guard (200..<300).contains(response.statusCode),
              let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              root["models"] is [[String: Any]] else { return nil }
        return CursorModelCatalog.pickerFacts(fromAvailableModels: body)
    }

    /// One unary POST. A transport failure is thrown as
    /// ``ProviderFailure/capture(_:)`` reads it, a cancel as
    /// `CancellationError` — also when the body stream, torn down by the
    /// cancel, ended as if it were whole.
    private static func post(
        url: URL,
        headers: [String: String],
        body: Data,
        client: HTTPClient,
        cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, Data) {
        let answer: (HTTPURLResponse, Data)
        do {
            answer = try await client.request(
                url: url,
                method: "POST",
                headers: headers,
                body: body,
                cancellation: cancellation
            )
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ProviderFailure.capture(error)
        }
        try Task.checkCancellation()
        return answer
    }

    // MARK: - Reading the reply

    /// A refusal as a Run answered with an HTTP error reads it — Cursor's
    /// Connect code and words where the body carries them — with the wait
    /// `Retry-After` asks for and the request id. The body is bounded as
    /// every HTTP error body is.
    static func failure(
        _ response: HTTPURLResponse,
        body: Data
    ) -> ProviderFailure {
        var failure = CursorConnectResponse.failureFromHTTP(
            status: response.statusCode,
            body: String(decoding: body.prefix(4096), as: UTF8.self)
        )
        failure.retryAfterMs = ProviderFailure.retryDelay(response: response)
        failure.requestId = response.value(forHTTPHeaderField: "x-request-id") ?? failure.requestId
        return failure
    }

    /// The usable models in a 2xx reply, unwrapped from a Connect frame as
    /// `fetchUsableModels` unwraps it; nil when it is no
    /// `GetUsableModelsResponse`. A reply that says it is a page or JSON is
    /// none whatever its bytes: proto's wire format reads some text as
    /// fields.
    static func readUsableModels(
        _ body: Data,
        response: HTTPURLResponse
    ) -> [CursorProto.UsableModel]? {
        let type = response.value(forHTTPHeaderField: "content-type")?
            .split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard !type.hasPrefix("text/"), !type.hasSuffix("json") else { return nil }
        return CursorProto.decodeUsableModelsStrictly(CursorModelCatalog.stripConnectUnaryFrame(body))
    }

    /// A 2xx reply that is no model list: a proxy's page, a body cut short.
    /// A 502, as Kiro's provider reads a web page served 200 — the fault is
    /// the server's, and asking again may find it mended. The bytes are
    /// left out: whatever words a page carries must not decide the
    /// failure's category.
    static func unreadable(
        _ body: Data,
        response: HTTPURLResponse
    ) -> ProviderFailure {
        let type = response.value(forHTTPHeaderField: "content-type").map { ", \($0)" } ?? ""
        return ProviderFailure(
            message: "Cursor's model list could not be read: GetUsableModels answered \(response.statusCode) "
                + "with \(body.count) bytes\(type) that are no GetUsableModelsResponse",
            httpStatus: 502,
            requestId: response.value(forHTTPHeaderField: "x-request-id")
        )
    }
}
