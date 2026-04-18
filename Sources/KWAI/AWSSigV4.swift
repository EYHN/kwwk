import Foundation
import CryptoKit

/// Minimal AWS Signature V4 signer — enough for `bedrock-runtime` streaming
/// requests. Single-shot `authorization` header signing, no query-string
/// pre-signing, no chunked body signing.
public struct AWSSigV4 {

    public struct Credentials: Sendable {
        public var accessKeyId: String
        public var secretAccessKey: String
        public var sessionToken: String?

        public init(accessKeyId: String, secretAccessKey: String, sessionToken: String? = nil) {
            self.accessKeyId = accessKeyId
            self.secretAccessKey = secretAccessKey
            self.sessionToken = sessionToken
        }
    }

    /// Sign a POST request: returns the set of headers the caller should send.
    /// `headers` must include `host`; the signer adds `x-amz-date`,
    /// `x-amz-security-token` (if any), `x-amz-content-sha256`, and
    /// `authorization`.
    public static func signPOST(
        url: URL,
        body: Data,
        region: String,
        service: String,
        credentials: Credentials,
        extraHeaders: [String: String] = [:],
        now: Date = Date()
    ) -> [String: String] {
        var headers = extraHeaders
        headers["host"] = url.host ?? ""

        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = dateFormatter.string(from: now)
        let shortDate = String(amzDate.prefix(8))

        let payloadHash = sha256Hex(body)
        headers["x-amz-date"] = amzDate
        headers["x-amz-content-sha256"] = payloadHash
        if let token = credentials.sessionToken, !token.isEmpty {
            headers["x-amz-security-token"] = token
        }

        // Canonical request.
        let method = "POST"
        let canonicalURI = canonicalURIPath(url.path)
        let canonicalQuery = canonicalQueryString(url: url)
        let (canonicalHeadersString, signedHeaders) = canonicalHeaders(headers)

        let canonicalRequest = [
            method,
            canonicalURI,
            canonicalQuery,
            canonicalHeadersString,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        // String to sign.
        let credentialScope = "\(shortDate)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        // Signing key.
        let kDate = hmacSHA256(key: Data("AWS4\(credentials.secretAccessKey)".utf8),
                               data: Data(shortDate.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data(service.utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        let signature = hmacSHA256(key: kSigning, data: Data(stringToSign.utf8))
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()

        headers["authorization"] = [
            "AWS4-HMAC-SHA256",
            "Credential=\(credentials.accessKeyId)/\(credentialScope),",
            "SignedHeaders=\(signedHeaders),",
            "Signature=\(signatureHex)",
        ].joined(separator: " ")

        return headers
    }

    // MARK: - Canonicalization

    private static func canonicalURIPath(_ path: String) -> String {
        let trimmed = path.isEmpty ? "/" : path
        // Segment-by-segment percent-encoding per AWS spec (double-encode
        // except for unreserved chars).
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        let encoded = segments.map { segment -> String in
            segment.addingPercentEncoding(withAllowedCharacters: awsUnreserved) ?? String(segment)
        }
        return encoded.joined(separator: "/")
    }

    private static func canonicalQueryString(url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else {
            return ""
        }
        var encoded: [(String, String)] = []
        encoded.reserveCapacity(items.count)
        for item in items {
            let rawValue = item.value ?? ""
            let name = item.name.addingPercentEncoding(withAllowedCharacters: awsUnreserved) ?? item.name
            let value = rawValue.addingPercentEncoding(withAllowedCharacters: awsUnreserved) ?? rawValue
            encoded.append((name, value))
        }
        encoded.sort { a, b in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
        return encoded.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    private static func canonicalHeaders(_ headers: [String: String]) -> (String, String) {
        let lowered = headers.reduce(into: [String: String]()) { acc, pair in
            acc[pair.key.lowercased()] = pair.value.trimmingCharacters(in: .whitespaces)
        }
        let sortedKeys = lowered.keys.sorted()
        let header = sortedKeys.map { "\($0):\(lowered[$0] ?? "")" }.joined(separator: "\n") + "\n"
        let signed = sortedKeys.joined(separator: ";")
        return (header, signed)
    }

    // MARK: - Hashing

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacSHA256(key: Data, data: Data) -> Data {
        let k = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: k)
        return Data(mac)
    }

    /// AWS's "unreserved" set: A-Z a-z 0-9 `-` `_` `.` `~`
    private static let awsUnreserved: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return s
    }()
}
