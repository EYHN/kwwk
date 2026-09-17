import Foundation

/// URLSession errors can arrive as NSError or as a provider's serialized message.
/// Classify the domain/code before prose: Linux can supply a null description,
/// and permanent TLS failures can contain misleading words such as "connection".
enum URLSessionRetryClassifier {
    static func classify(_ error: any Error) -> Bool? {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return nil }
        return isTransient(error.code)
    }

    static func classify(_ message: String) -> Bool? {
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = serializedCode.firstMatch(in: message, range: range),
              let codeRange = Range(match.range(at: 1), in: message),
              let code = Int(message[codeRange]) else { return nil }
        return isTransient(code)
    }

    private static let serializedCode = try! NSRegularExpression(
        pattern: #"\bDomain\s*=\s*NSURLErrorDomain\s+Code\s*=\s*(-?\d+)\b"#,
        options: .caseInsensitive
    )

    private static func isTransient(_ code: Int) -> Bool {
        switch URLError.Code(rawValue: code) {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
             .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            // Cancellation, invalid URLs, TLS/certificate failures, authentication
            // and unknown codes are not repaired by replaying the same request.
            return false
        }
    }
}
