import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a token refresh produced no credentials, sorted by what the holder of
/// the login should do next.
///
/// A refresh token that rotates on use dies the moment two parties spend it,
/// so a server that refreshes on behalf of users has to tell "this login is
/// gone, ask the user to sign in again" from "try again later" — retrying the
/// first forever hides a dead login, parking on the second strands a good one.
public struct OAuthRefreshError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// The provider refused the refresh token itself (revoked, expired,
        /// already rotated elsewhere). Only a new sign-in revives the login.
        case rejected
        /// The provider could not be reached or answered with a server-side
        /// or rate-limit failure, or an answer that could not be read. The
        /// same refresh may succeed later.
        case unavailable
    }

    public let providerId: String
    public let kind: Kind
    /// The provider's HTTP status, when it answered.
    public let status: Int?
    /// The start of the provider's answer or the transport failure, for logs.
    public let detail: String

    public init(providerId: String, kind: Kind, status: Int?, detail: String) {
        self.providerId = providerId
        self.kind = kind
        self.status = status
        self.detail = detail
    }

    public var errorDescription: String? {
        if let status {
            return "\(providerId) \(status): \(detail)"
        }
        return "\(providerId) refresh failed: \(detail)"
    }

    /// A 4xx other than 429 refuses the grant itself; everything else — 429,
    /// 5xx — is the provider's moment, not the login's end.
    public static func classify(providerId: String, status: Int, body: Data) -> OAuthRefreshError {
        let kind: Kind = (400..<500).contains(status) && status != 429 ? .rejected : .unavailable
        return OAuthRefreshError(
            providerId: providerId,
            kind: kind,
            status: status,
            detail: String((String(data: body, encoding: .utf8) ?? "").prefix(300))
        )
    }

    // MARK: - Helpers the refresh providers share

    /// POSTs a refresh request. A transport failure is `.unavailable` rather
    /// than a raw `URLError`; an error status is classified.
    package static func post(
        provider: String,
        url: URL,
        headers: [String: String],
        body: Data,
        client: HTTPClient
    ) async throws -> (HTTPURLResponse, Data) {
        let response: HTTPURLResponse
        let data: Data
        do {
            (response, data) = try await client.request(url: url, method: "POST", headers: headers, body: body)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OAuthRefreshError(
                providerId: provider, kind: .unavailable, status: nil,
                detail: error.localizedDescription
            )
        }
        if response.statusCode >= 400 {
            throw classify(providerId: provider, status: response.statusCode, body: data)
        }
        return (response, data)
    }

    /// `post`, then the standard token answer; an unreadable one is
    /// `.unavailable`.
    package static func postForToken(
        provider: String,
        url: URL,
        headers: [String: String],
        body: Data,
        client: HTTPClient
    ) async throws -> OAuth.TokenResponse {
        let (_, data) = try await post(provider: provider, url: url, headers: headers, body: body, client: client)
        do {
            return try JSONDecoder().decode(OAuth.TokenResponse.self, from: data)
        } catch {
            throw OAuthRefreshError(
                providerId: provider, kind: .unavailable, status: nil,
                detail: "unreadable token response: \(String((String(data: data, encoding: .utf8) ?? "").prefix(300)))"
            )
        }
    }
}
