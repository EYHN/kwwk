import Foundation

// The parts of a sign-in that differ per host app. kwwk's CLI prints the URL
// and uses the default NIO listener; an iOS/Mac app presents a
// web-authentication sheet and may bind its own listener. The flows stay the same
// for both and reach the host only through these seams.

/// A loopback HTTP listener a browser sign-in redirects back to.
///
/// Providers register fixed redirect URIs (`http://localhost:1455/auth/callback`
/// for Codex, `http://127.0.0.1:59653/callback` for Devin), so the host, port
/// and path are the flow's to choose, never the listener's.
public protocol OAuthLoopbackListener: AnyObject, Sendable {
    /// The exact redirect URI the flow sends in its authorize request.
    var redirectURI: String { get }
    /// Bind the port. Called before the browser opens, so a port still held
    /// by an earlier sign-in fails the flow instead of stranding the user on
    /// a page nothing answers.
    func listen() async throws
    /// The query parameters of the provider's redirect. A provider-reported
    /// failure (`error=access_denied`) is returned like any other redirect,
    /// not thrown: the flow decides what it means.
    func waitForCallback() async throws -> [String: String]
    /// Release the port. Idempotent.
    func stop()
}

/// Builds the listener for one sign-in.
public typealias OAuthLoopbackFactory = @Sendable (
    _ host: String, _ port: UInt16, _ path: String
) throws -> any OAuthLoopbackListener

/// Shows an authorization or verification page while the flow's own work
/// (waiting for the redirect, polling a device code) runs.
///
/// A presenter that owns a sheet races it against `work`: a dismissed sheet
/// is the user leaving (throw `OAuthLoginError.cancelled`), a finished `work`
/// closes the sheet.
public protocol OAuthBrowserPresenter: Sendable {
    func run<Outcome: Sendable>(
        _ url: URL,
        while work: @escaping @Sendable () async throws -> Outcome
    ) async throws -> Outcome
}

/// Why a sign-in ended without credentials, when the reason is the user's or
/// the clock's rather than a malformed exchange.
public enum OAuthLoginError: Error, LocalizedError, Equatable, Sendable {
    /// The user declined in the browser (`access_denied`) or left the sheet.
    case cancelled
    /// The device code or the browser poll expired before approval.
    case timedOut
    /// The provider refused the authorization for a reason of its own.
    case denied(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "sign-in was cancelled"
        case .timedOut: "sign-in timed out before it was approved"
        case .denied(let reason): "the provider refused the sign-in: \(reason)"
        }
    }
}

extension OAuthLogin {
    /// Runs `work` while `url` is in front of the user: through the host's
    /// presenter when it has one, otherwise by handing the URL to
    /// `onAuthURL` (the CLI opens the browser there) and running `work`.
    static func present<Outcome: Sendable>(
        _ url: URL,
        callbacks: Callbacks,
        while work: @escaping @Sendable () async throws -> Outcome
    ) async throws -> Outcome {
        if let browser = callbacks.browser {
            return try await browser.run(url, while: work)
        }
        callbacks.onAuthURL(url)
        return try await work()
    }

    /// Builds and binds the flow's listener.
    static func openLoopback(
        _ callbacks: Callbacks,
        host: String = "localhost",
        port: UInt16,
        path: String = "/callback"
    ) async throws -> any OAuthLoopbackListener {
        let listener = try callbacks.loopback(host, port, path)
        do {
            try await listener.listen()
        } catch {
            listener.stop()
            throw error
        }
        return listener
    }

    /// Turns a redirect's `error=` into the flow's error, or returns when the
    /// redirect carries none.
    static func checkCallbackError(_ params: [String: String], provider: String) throws {
        guard let error = params["error"], !error.isEmpty else { return }
        if error == "access_denied" { throw OAuthLoginError.cancelled }
        let description = params["error_description"].map { ": \($0)" } ?? ""
        throw OAuthLoginError.denied("\(provider) \(error)\(description)")
    }
}
