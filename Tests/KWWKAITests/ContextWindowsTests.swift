import Foundation
import Testing
@testable import KWWKAI

/// Kimi For Coding's answer to a 278k-token k3 request on a Plus login,
/// captured 2026-10-07.
private let kimiPlanRefusal = #"{"error":{"type":"authentication_error","message":"Your current plan supports only k3 up to 256K context. 1M context is available on higher-tier Kimi Code plans. Upgrade: https://www.kimi.com/code?from=server_k3_error#pricing"},"type":"error"}"#

private func model(
    _ id: String = UUID().uuidString,
    provider: String = "context-window-tests",
    window: Int = 1_048_576
) -> Model {
    Model(
        id: id,
        api: "anthropic-messages",
        provider: provider,
        baseURL: "https://api.example.test/coding",
        contextWindow: window,
        maxTokens: 32_768
    )
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@Suite("Context windows")
struct ContextWindowsTests {
    @Test("stated limits are read from each provider's overflow wording")
    func reportedLimits() {
        let cases: [(String, Int?)] = [
            (kimiPlanRefusal, 262_144),
            ("Your request exceeded model token limit: 262144 (requested: 300000)", 262_144),
            ("prompt is too long: 213462 tokens > 200000 maximum", 200_000),
            ("input length and max_tokens exceed context limit: 190000 + 32000 > 200000", 200_000),
            ("This endpoint's maximum context length is 131072 tokens. However, you requested about 140000 tokens", 131_072),
            ("Requested token count exceeds the model's maximum context length of 131,072 tokens", 131_072),
            ("Input length (265330) exceeds model's maximum context length (262144).", 262_144),
            ("This model's maximum prompt length is 131072 but the request contains 537812 tokens", 131_072),
            ("The input token count (1196265) exceeds the maximum number of tokens allowed (1048575)", 1_048_575),
            ("prompt token count of 140000 exceeds the limit of 128000", 128_000),
            ("context_length_exceeded", nil),
            ("unauthorized", nil),
        ]
        for (message, expected) in cases {
            #expect(ProviderContextLimit.reportedLimit(in: message) == expected, "\(message)")
        }
        #expect(ProviderContextLimit.reportedLimit(in: "supports only k3 up to 1M context") == 1_048_576)
    }

    @Test("Kimi's plan refusal is an overflow even though it arrives as 401")
    func kimiPlanRefusalIsOverflow() {
        let refusal = ProviderFailure(message: kimiPlanRefusal, httpStatus: 401)
        #expect(refusal.category == .contextOverflow)
        #expect(refusal.reportedContextLimit == 262_144)

        let login = ProviderFailure(
            message: #"{"error":{"type":"authentication_error","message":"The API Key appears to be invalid or may have expired."}}"#,
            httpStatus: 401
        )
        #expect(login.category == .authentication)

        let tokenLimit = ProviderFailure(
            message: "Your request exceeded model token limit: 262144 (requested: 300000)",
            httpStatus: 400
        )
        #expect(tokenLimit.category == .contextOverflow)
    }

    @Test("a stated limit lowers the window and never raises it")
    func rejectionsOnlyLower() {
        let windows = ContextWindows(discoveries: [:])
        let k3 = model("k3")
        let refusal = ProviderFailure(message: kimiPlanRefusal, httpStatus: 401)

        #expect(windows.effectiveWindow(for: k3) == 1_048_576)
        #expect(windows.recordRejection(refusal, for: k3) == 262_144)
        #expect(windows.effectiveWindow(for: k3) == 262_144)

        let larger = ProviderFailure(message: "prompt is too long: 600000 tokens > 500000 maximum", httpStatus: 400)
        #expect(windows.recordRejection(larger, for: k3) == nil)
        #expect(windows.effectiveWindow(for: k3) == 262_144)

        // The host ceiling already on the model still wins.
        var capped = k3
        capped.contextWindow = 200_000
        #expect(windows.effectiveWindow(for: capped) == 200_000)

        // Failures that are not overflows, or state nothing, record nothing.
        let other = model()
        #expect(windows.recordRejection(ProviderFailure(message: "prompt is too long: 9 tokens > 8 maximum", httpStatus: 429), for: other) == nil)
        #expect(windows.recordRejection(ProviderFailure(message: "context_length_exceeded", httpStatus: 400), for: other) == nil)
        #expect(windows.recordRejection(ProviderFailure(message: "prompt is too long: 900 tokens > 512 maximum", httpStatus: 400), for: other) == nil)
        #expect(windows.effectiveWindow(for: other) == 1_048_576)
    }

    @Test("discovery is cached, refreshed after its interval and retried sooner after a failure")
    func discoveryCaching() async {
        let clock = Clock()
        let calls = CallCounter()
        let answers = AnswerQueue([.success(262_144), .failure, .success(524_288)])
        let windows = ContextWindows(
            refreshInterval: 3_600,
            failureRetryInterval: 300,
            discoveries: ["kimi-test": { _, _ in
                await calls.increment()
                return try await answers.next()
            }],
            now: { clock.now() }
        )
        let k3 = model("k3", provider: "kimi-test")
        let auth: @Sendable () async throws -> ResolvedProviderAuth? = { ResolvedProviderAuth(token: "t", scheme: .bearer) }

        await windows.refreshIfNeeded(model: k3, auth: auth)
        #expect(windows.effectiveWindow(for: k3) == 262_144)
        await windows.refreshIfNeeded(model: k3, auth: auth)
        #expect(await calls.count == 1)

        // A failed refresh keeps the last answer and retries after 300 s.
        clock.advance(3_601)
        await windows.refreshIfNeeded(model: k3, auth: auth)
        #expect(await calls.count == 2)
        #expect(windows.effectiveWindow(for: k3) == 262_144)
        clock.advance(200)
        await windows.refreshIfNeeded(model: k3, auth: auth)
        #expect(await calls.count == 2)

        // A plan change is picked up on the next refresh.
        clock.advance(101)
        await windows.refreshIfNeeded(model: k3, auth: auth)
        #expect(await calls.count == 3)
        #expect(windows.effectiveWindow(for: k3) == 524_288)

        // Providers without a discovery never call out.
        await windows.refreshIfNeeded(model: model(provider: "no-discovery"), auth: auth)
        #expect(await calls.count == 3)
    }

    @Test("concurrent refreshes for one model share a single lookup")
    func discoverySingleFlight() async {
        let calls = CallCounter()
        let windows = ContextWindows(discoveries: ["kimi-test": { _, _ in
            await calls.increment()
            try await Task.sleep(nanoseconds: 50_000_000)
            return 262_144
        }])
        let k3 = model("k3", provider: "kimi-test")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await windows.refreshIfNeeded(model: k3) { nil } }
            }
        }
        #expect(await calls.count == 1)
        #expect(windows.effectiveWindow(for: k3) == 262_144)
    }

    @Test("a discovered window above the model's own never raises it")
    func discoveryNeverRaises() async {
        let windows = ContextWindows(discoveries: ["kimi-test": { _, _ in 1_048_576 }])
        let capped = model("k3", provider: "kimi-test", window: 300_000)
        await windows.refreshIfNeeded(model: capped) { nil }
        #expect(windows.effectiveWindow(for: capped) == 300_000)
    }

    @Test("the model-list discovery reads the account's context_length with its bearer")
    func modelListDiscovery() async throws {
        let body = #"{"data":[{"id":"k3-256k","context_length":262144},{"id":"k3","context_length":262144,"display_name":"K3"}],"object":"list"}"#
        let client = StubResponseClient(status: 200, body: Data(body.utf8))
        let discovery = ContextWindows.modelListDiscovery(client: client)
        var k3 = model("k3")
        k3.headers = ["User-Agent": "KimiCLI/1.5"]

        let window = try await discovery(k3, ResolvedProviderAuth(token: "kimi-token", scheme: .bearer))

        #expect(window == 262_144)
        let request = try #require(client.lastRequest)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://api.example.test/coding/v1/models")
        #expect(request.headers["Authorization"] == "Bearer kimi-token")
        #expect(request.headers["User-Agent"] == "KimiCLI/1.5")

        #expect(try await discovery(model("unlisted"), ResolvedProviderAuth(token: "kimi-token", scheme: .bearer)) == nil)
        await #expect(throws: ContextWindowDiscoveryError.missingCredentials) {
            _ = try await discovery(k3, nil)
        }
        let refused = ContextWindows.modelListDiscovery(client: StubResponseClient(status: 401, body: Data("{}".utf8)))
        await #expect(throws: ContextWindowDiscoveryError.status(401)) {
            _ = try await refused(k3, ResolvedProviderAuth(token: "kimi-token", scheme: .bearer))
        }
    }

    @Test("Kimi For Coding discovers its window out of the box")
    func kimiCodingHasBuiltInDiscovery() {
        #expect(ContextWindows.builtInDiscoveries()["kimi-coding"] != nil)
    }
}

private actor AnswerQueue {
    enum Answer { case success(Int), failure }
    private var answers: [Answer]

    init(_ answers: [Answer]) { self.answers = answers }

    func next() throws -> Int? {
        guard !answers.isEmpty else { return nil }
        switch answers.removeFirst() {
        case .success(let window): return window
        case .failure: throw ContextWindowDiscoveryError.status(503)
        }
    }
}
