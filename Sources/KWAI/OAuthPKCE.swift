import Foundation
import CryptoKit

/// PKCE verifier + challenge. The verifier is 32 random bytes encoded as
/// base64url; the challenge is SHA-256(verifier) in the same encoding.
public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public static func random() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SystemRandomNumberGenerator()
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        let verifier = base64URL(Data(bytes))
        let hashed = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URL(Data(hashed))
        return PKCE(verifier: verifier, challenge: challenge)
    }

    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
    }

    /// Base64url encoding (RFC 4648 §5): standard base64 but with `-` and
    /// `_` instead of `+` and `/`, and no trailing `=`.
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Generate a short random hex string suitable for OAuth `state`.
    public static func randomHex(bytes: Int = 16) -> String {
        var out = ""
        for _ in 0..<bytes {
            out += String(format: "%02x", UInt8.random(in: 0...255))
        }
        return out
    }
}
