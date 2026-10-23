import Foundation
import Testing
@testable import KWWKAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Stands in for Cursor's API: each URL takes its scripted answers in turn,
/// the last one repeating, and every request is recorded.
private final class CursorStubClient: HTTPClient, @unchecked Sendable {
    struct Answer {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var error: URLError?
    }

    typealias Request = (url: URL, method: String, headers: [String: String], body: Data?)

    private let lock = NSLock()
    private var answers: [String: [Answer]]
    private var recorded: [Request] = []

    init(_ answers: [String: [Answer]]) { self.answers = answers }

    var requests: [Request] { lock.withLock { recorded } }

    func requests(to url: String) -> [Request] {
        requests.filter { $0.url.absoluteString == url }
    }

    func stream(
        url: URL, method: String, headers: [String: String], body: Data?, cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let answer: Answer = lock.withLock {
            recorded.append((url, method, headers, body))
            guard var queue = answers[url.absoluteString], !queue.isEmpty else {
                return Answer(status: 404, body: Data("no route".utf8))
            }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            answers[url.absoluteString] = queue
            return next
        }
        if let error = answer.error { throw error }
        let response = HTTPURLResponse(
            url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers
        )!
        let bytes = answer.body
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(bytes)
            continuation.finish()
        }
        return (response, stream)
    }
}

/// Answers `answered` URLs at once and holds every other request until its
/// cancellation handle fires, then fails it as URLSession fails a cancelled
/// task. `entered` names each URL as it is asked.
private final class HoldingStubClient: HTTPClient, @unchecked Sendable {
    private let answered: [String: Data]
    let entered: AsyncStream<String>
    private let enter: AsyncStream<String>.Continuation

    init(answered: [String: Data]) {
        self.answered = answered
        (entered, enter) = AsyncStream<String>.makeStream()
    }

    func stream(
        url: URL, method: String, headers: [String: String], body: Data?, cancellation: CancellationHandle?
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        enter.yield(url.absoluteString)
        if let bytes = answered[url.absoluteString] {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (response, AsyncThrowingStream { $0.yield(bytes); $0.finish() })
        }
        guard let cancellation else { throw URLError(.badServerResponse) }
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            _ = cancellation.onCancel { _ in held.resume() }
        }
        throw URLError(.cancelled)
    }
}

@Suite("Cursor: an account's own model list")
struct CursorModelsTests {
    static let login = OAuthCredentials(access: "cursor-at", refresh: "cursor-rt", expires: .max)
    static let usableURL = "https://api2.cursor.sh/agent.v1.AgentService/GetUsableModels"
    static let pickerURL = "https://api2.cursor.sh/aiserver.v1.AiService/AvailableModels"
    static let configURL = "https://api2.cursor.sh/aiserver.v1.ServerConfigService/GetServerConfig"
    static let proto = ["content-type": "application/proto"]
    static let json = ["content-type": "application/json"]

    /// Ids the picker speaks of, a curated base with its thinking variant,
    /// and an uncurated pair the family rule folds together.
    static let ids = [
        "claude-opus-5-5-medium", "grok-4.7-high", "cursor-grok-4.6-high",
        "claude-4.5-sonnet", "claude-4.5-sonnet-thinking", "gpt-9-unlisted", "gpt-9-unlisted-thinking",
    ]

    /// `GetUsableModelsResponse { models=1 (repeated ModelDetails) }`.
    static func usable(_ ids: [String]) -> Data {
        var reply = ProtoWriter()
        for id in ids {
            reply.messageField(1) { details in
                details.stringField(1, id)
                details.stringField(4, id.uppercased())
            }
        }
        return reply.data
    }

    /// The same bytes in one Connect unary frame.
    static func framed(_ payload: Data) -> Data {
        let length = UInt32(payload.count)
        let prefix = [0, UInt8(length >> 24), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff)]
        return Data(prefix + [UInt8(length & 0xff)]) + payload
    }

    private static func client(
        usable: [CursorStubClient.Answer],
        picker: CursorStubClient.Answer = .init(
            headers: CursorModelsTests.json,
            body: CursorPickerParityTests.picker
        ),
        more: [String: [CursorStubClient.Answer]] = [:]
    ) -> CursorStubClient {
        CursorStubClient([usableURL: usable, pickerURL: [picker]].merging(more) { $1 })
    }

    // MARK: - Listing

    @Test(
        "one reply makes the models fetchUsableModels makes of it, with the picker's windows",
        arguments: [false, true]
    )
    func sameModelsAsTheScript(framedReply: Bool) async throws {
        let body = framedReply ? Self.framed(Self.usable(Self.ids)) : Self.usable(Self.ids)
        let client = Self.client(usable: [.init(headers: Self.proto, body: body)])
        let listing = try await CursorModels.fetch(credentials: Self.login, client: client)
        let script = try await CursorModelCatalog.fetchUsableModels(apiKey: Self.login.access, client: client)
        #expect(listing.models == script)
        #expect(listing.pickerApplied)
        // The thinking variants fold into their bases.
        #expect(listing.models.map(\.id) == [
            "claude-4.5-sonnet", "claude-opus-5-5-medium", "cursor-grok-4.6-high", "gpt-9-unlisted", "grok-4.7-high",
        ])
        let by = Dictionary(uniqueKeysWithValues: listing.models.map { ($0.id, $0) })
        #expect(by["claude-opus-5-5-medium"]?.contextWindow == 300_000)
        #expect(by["grok-4.7-high"]?.input == [.text])
        #expect(by["cursor-grok-4.6-high"]?.input == [.text, .image])
        #expect(listing.models.allSatisfy { $0.baseURL == "https://api2.cursor.sh" })
    }

    @Test("a picker Cursor cannot give leaves the list the curated table and the defaults make")
    func pickerFailure() async throws {
        let withoutPicker = CursorModelCatalog.normalize(
            CursorProto.decodeUsableModels(Self.usable(Self.ids)), host: "api2.cursor.sh"
        )
        let failures: [CursorStubClient.Answer] = [
            .init(status: 500, headers: Self.json, body: Data(#"{"code":"internal","message":"boom"}"#.utf8)),
            .init(error: URLError(.networkConnectionLost)),
            .init(headers: Self.json, body: Data("down".utf8)),
            .init(headers: Self.json, body: Data(#"{"configVersion":"x"}"#.utf8)),
        ]
        for picker in failures {
            let client = Self.client(usable: [.init(headers: Self.proto, body: Self.usable(Self.ids))], picker: picker)
            let listing = try await CursorModels.fetch(credentials: Self.login, client: client)
            #expect(!listing.pickerApplied)
            #expect(listing.models == withoutPicker)
            #expect(listing.models == (try await CursorModelCatalog.fetchUsableModels(
                apiKey: Self.login.access, client: client
            )))
        }
        #expect(withoutPicker.first { $0.id == "claude-opus-5-5-medium" }?.contextWindow == 200_000)
    }

    @Test("an account with no models is an empty list, not a failure")
    func emptyList() async throws {
        var unknownField = ProtoWriter()
        unknownField.stringField(7, "later")
        var noId = ProtoWriter()
        noId.messageField(1) { $0.stringField(4, "Nameless") }
        for body in [Data(), Self.framed(Data()), unknownField.data, noId.data] {
            let client = Self.client(usable: [.init(headers: Self.proto, body: body)])
            let listing = try await CursorModels.fetch(credentials: Self.login, client: client)
            #expect(listing.models.isEmpty)
            #expect(!listing.pickerApplied)
            // Nothing to apply the picker to: it is not asked.
            #expect(client.requests(to: Self.pickerURL).isEmpty)
        }
    }

    @Test("a reply that is no model list is a failure that says so, not an empty list")
    func unreadableReply() async throws {
        let whole = Self.usable(["gpt-5.2", "grok-4.7-high"])
        var varintModels = ProtoWriter()
        varintModels.varintField(1, 7)
        var numberedId = ProtoWriter()
        numberedId.messageField(1) { $0.varintField(1, 42) }
        let replies: [CursorStubClient.Answer] = [
            .init(headers: ["content-type": "text/html; charset=utf-8"], body: Data("<html>Access denied</html>".utf8)),
            .init(headers: Self.json, body: Data(#"{"models":[]}"#.utf8)),
            // Bytes proto would read as a fixed32 field, said to be text.
            .init(headers: ["content-type": "text/plain"], body: Data("Error".utf8)),
            .init(headers: Self.proto, body: whole.prefix(whole.count - 3)),
            .init(headers: Self.proto, body: varintModels.data),
            .init(headers: Self.proto, body: numberedId.data),
            // A model id that is no UTF-8.
            .init(headers: Self.proto, body: Data([0x0a, 0x05, 0x0a, 0x03, 0xff, 0xfe, 0xfd])),
        ]
        for reply in replies {
            let client = Self.client(usable: [reply])
            let thrown = await #expect(throws: ProviderFailure.self) {
                _ = try await CursorModels.fetch(credentials: Self.login, client: client)
            }
            #expect(thrown?.message.hasPrefix("Cursor's model list could not be read") == true)
            #expect(thrown?.httpStatus == 502)
            #expect(thrown?.category == .server)
            #expect(client.requests(to: Self.pickerURL).isEmpty)
        }
        // Where the script's decoder keeps what it read before the cut.
        #expect(CursorProto.decodeUsableModels(whole.prefix(whole.count - 3)).map(\.modelId) == ["gpt-5.2"])
        #expect(CursorProto.decodeUsableModelsStrictly(whole)?.map(\.modelId) == ["gpt-5.2", "grok-4.7-high"])
    }

    // MARK: - Refusals

    @Test("a 429 keeps the wait Retry-After asks for and the request id")
    func rateLimited() async throws {
        let headers = ["content-type": "text/plain", "Retry-After": "120", "x-request-id": "req-429"]
        let client = Self.client(usable: [.init(status: 429, headers: headers, body: Data("Too Many Requests".utf8))])
        let thrown = await #expect(throws: ProviderFailure.self) {
            _ = try await CursorModels.fetch(credentials: Self.login, client: client)
        }
        #expect(thrown?.httpStatus == 429)
        #expect(thrown?.retryAfterMs == 120_000)
        #expect(thrown?.requestId == "req-429")
        #expect(thrown?.category == .rateLimit)
        #expect(thrown?.isRetryable == true)

        // A Connect error keeps its code and words, read as a Run's refusal
        // is: the 429 is only Connect's rendering of the code and is left
        // out, the wait is kept.
        let connect = Self.client(usable: [.init(
            status: 429,
            headers: ["content-type": "application/json", "retry-after": "120"],
            body: Data(#"{"code":"resource_exhausted","message":"slow down"}"#.utf8)
        )])
        let busy = await #expect(throws: ProviderFailure.self) {
            _ = try await CursorModels.fetch(credentials: Self.login, client: connect)
        }
        #expect(busy?.providerCode == "resource_exhausted")
        #expect(busy?.message.hasSuffix("slow down") == true)
        #expect(busy?.retryAfterMs == 120_000)
        #expect(busy?.category == .rateLimit)
        #expect(client.requests(to: Self.pickerURL).isEmpty)
    }

    @Test("a sign-in Cursor turns away is a credential rejection, and the server config is not asked")
    func signInRefused() async throws {
        let plain = Self.client(usable: [.init(status: 401, body: Data("Unauthorized".utf8))])
        let thrown = await #expect(throws: ProviderFailure.self) {
            _ = try await CursorModels.fetch(credentials: Self.login, client: plain)
        }
        #expect(thrown?.httpStatus == 401)
        #expect(thrown?.isCredentialRejection == true)
        #expect(plain.requests(to: Self.configURL).isEmpty)

        let connect = Self.client(usable: [.init(
            status: 401, headers: Self.json, body: Data(#"{"code":"unauthenticated","message":"token expired"}"#.utf8)
        )])
        let expired = await #expect(throws: ProviderFailure.self) {
            _ = try await CursorModels.fetch(credentials: Self.login, client: connect)
        }
        #expect(expired?.providerCode == "unauthenticated")
        #expect(expired?.message.hasSuffix("token expired") == true)
        #expect(expired?.isCredentialRejection == true)
        #expect(connect.requests(to: Self.configURL).isEmpty)
        #expect(connect.requests.count == 1)
    }

    @Test("a transport failure is the ProviderFailure it captures as")
    func transportFailure() async throws {
        let client = Self.client(usable: [.init(error: URLError(.notConnectedToInternet))])
        let thrown = await #expect(throws: ProviderFailure.self) {
            _ = try await CursorModels.fetch(credentials: Self.login, client: client)
        }
        #expect(thrown?.transportDomain == NSURLErrorDomain)
        #expect(thrown?.transportCode == URLError.notConnectedToInternet.rawValue)
        #expect(thrown?.category == .transport)
    }

    // MARK: - Region

    /// A region refusal as Cursor answers a Run with it over HTTP (the
    /// fixture of magpie's TestCursorFailure).
    private static let regionRefusal = CursorStubClient.Answer(
        status: 401,
        headers: json,
        body: Data(#"{"code":"unauthenticated","message":"Error","details":[{"debug":{"details":{"title":"Unauthorized request.","detail":"This region is not yet available for your team"}}}]}"#.utf8)
    )

    @Test("a team refused over a region is listed on the agent API the server config names, once")
    func regionRefusalIsListedOnTheAgentAPI() async throws {
        let agentURL = "https://agent.eu.example:8443/n/agent.v1.AgentService/GetUsableModels"
        let body = Self.usable(Self.ids)
        let client = Self.client(
            usable: [Self.regionRefusal],
            more: [
                Self.configURL: [.init(headers: Self.json, body: Data(
                    #"{"agentUrlConfig":{"agentUrl":"","agentnUrl":"https://agent.eu.example:8443/n/"}}"#.utf8
                ))],
                agentURL: [.init(headers: Self.proto, body: body)],
            ]
        )
        let login = OAuthCredentials(access: "cursor-models-region", refresh: "rt", expires: .max)
        let listing = try await CursorModels.fetch(credentials: login, client: client)
        #expect(client.requests.map(\.url.absoluteString) == [Self.usableURL, Self.configURL, agentURL, Self.pickerURL])
        #expect(client.requests(to: agentURL).first?.headers["authorization"] == "Bearer cursor-models-region")
        #expect(listing.pickerApplied)
        #expect(listing.models == CursorModelCatalog.normalize(
            CursorProto.decodeUsableModels(body),
            host: "api2.cursor.sh",
            picker: CursorModelCatalog.pickerFacts(fromAvailableModels: CursorPickerParityTests.picker)
        ))
        // The Run's record of where the account was moved is its own.
        #expect(CursorAgentProvider.endpoints.endpoint(for: login.access) == nil)
    }

    @Test("the refusal stands when the server config cannot be had, names nothing, or names the same API")
    func regionRefusalStands() async throws {
        let configs: [CursorStubClient.Answer] = [
            .init(status: 503, body: Data("down".utf8)),
            .init(error: URLError(.timedOut)),
            .init(headers: Self.json, body: Data(#"{"agentUrlConfig":{}}"#.utf8)),
            .init(headers: Self.json, body: Data(#"{"agentUrlConfig":{"agentUrl":"https://api2.cursor.sh"}}"#.utf8)),
        ]
        for config in configs {
            let client = Self.client(usable: [Self.regionRefusal], more: [Self.configURL: [config]])
            let thrown = await #expect(throws: ProviderFailure.self) {
                _ = try await CursorModels.fetch(credentials: Self.login, client: client)
            }
            #expect(thrown?.message.hasSuffix("This region is not yet available for your team") == true)
            #expect(thrown?.category == .invalidRequest)
            #expect(client.requests.map(\.url.absoluteString) == [Self.usableURL, Self.configURL])
        }
    }

    @Test("the agent API is tried once: a second refusal is the one thrown")
    func regionRetriedOnce() async throws {
        let agentURL = "https://agent.us.example/agent.v1.AgentService/GetUsableModels"
        let client = Self.client(
            usable: [Self.regionRefusal],
            more: [
                Self.configURL: [.init(headers: Self.json, body: Data(
                    #"{"agentUrlConfig":{"agentUrl":"https://agent.us.example"}}"#.utf8
                ))],
                agentURL: [Self.regionRefusal],
            ]
        )
        let thrown = await #expect(throws: ProviderFailure.self) {
            _ = try await CursorModels.fetch(credentials: Self.login, client: client)
        }
        #expect(CursorAgentEndpoint.isRegionRefusal(try #require(thrown)))
        #expect(client.requests.map(\.url.absoluteString) == [Self.usableURL, Self.configURL, agentURL])
    }

    // MARK: - The request

    @Test("both RPCs are asked as fetchUsableModels asks them, at the client version given")
    func requestsMatchTheScript() async throws {
        let host = "api3.cursor.example"
        let usableURL = "https://\(host)/agent.v1.AgentService/GetUsableModels"
        let pickerURL = "https://\(host)/aiserver.v1.AiService/AvailableModels"
        let client = CursorStubClient([
            usableURL: [.init(headers: Self.proto, body: Self.usable(Self.ids))],
            pickerURL: [.init(headers: Self.json, body: CursorPickerParityTests.picker)],
        ])
        let listing = try await CursorModels.fetch(
            credentials: Self.login, host: host, clientVersion: "cli-test-1", client: client
        )
        _ = try await CursorModelCatalog.fetchUsableModels(
            apiKey: Self.login.access, host: host, clientVersion: "cli-test-1", client: client
        )
        #expect(listing.models.allSatisfy { $0.baseURL == "https://\(host)" })

        let usable = client.requests(to: usableURL)
        try #require(usable.count == 2)
        func withoutRequestId(_ headers: [String: String]) -> [String: String] {
            headers.filter { $0.key != "x-request-id" }
        }
        #expect(withoutRequestId(usable[0].headers) == withoutRequestId(usable[1].headers))
        #expect(usable[0].headers["x-request-id"].flatMap(UUID.init(uuidString:)) != nil)
        #expect(usable[0].headers["x-request-id"] != usable[1].headers["x-request-id"])
        #expect(usable[0].headers["authorization"] == "Bearer cursor-at")
        #expect(usable[0].headers["x-cursor-client-version"] == "cli-test-1")
        #expect(usable[0].method == usable[1].method)
        #expect(usable[0].body == usable[1].body)

        let picker = client.requests(to: pickerURL)
        try #require(picker.count == 2)
        #expect(picker[0].headers == picker[1].headers)
        #expect(picker[0].headers["x-cursor-client-version"] == "cli-test-1")
        #expect(picker[0].method == picker[1].method)
        #expect(picker[0].body == picker[1].body)
    }

    @Test("a cancelled task ends in CancellationError, while either RPC is waited on")
    func cancelled() async throws {
        let cases: [[String: Data]] = [[:], [Self.usableURL: Self.usable(Self.ids)]]
        for answered in cases {
            let client = HoldingStubClient(answered: answered)
            let task = Task { try await CursorModels.fetch(credentials: Self.login, client: client) }
            let held = answered.isEmpty ? Self.usableURL : Self.pickerURL
            for await url in client.entered where url == held { break }
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
    }

    // MARK: - The script's fetch is unchanged

    @Test("fetchUsableModels still throws FetchError: the status and body, and an empty list")
    func scriptFetchErrors() async throws {
        let refused = Self.client(usable: [.init(status: 403, body: Data("forbidden".utf8))])
        do {
            _ = try await CursorModelCatalog.fetchUsableModels(apiKey: Self.login.access, client: refused)
            Issue.record("a refused list was a catalog")
        } catch CursorModelCatalog.FetchError.http(let status, let body) {
            #expect(status == 403)
            #expect(body == "forbidden")
        }
        let empty = Self.client(usable: [.init(headers: Self.proto, body: Data())])
        do {
            _ = try await CursorModelCatalog.fetchUsableModels(apiKey: Self.login.access, client: empty)
            Issue.record("an empty list was a catalog")
        } catch CursorModelCatalog.FetchError.emptyResponse {}
    }
}
