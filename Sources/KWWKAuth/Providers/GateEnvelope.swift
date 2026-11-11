import Foundation

/// The JSON a vendor's own gate answers its client with, as Trae's and
/// Raccoon's are read: an object, often an envelope whose business code says
/// whether it is a refusal, in whichever spelling the gate uses.
package enum GateEnvelope {
    static let jsonHeaders = ["Content-Type": "application/json", "Accept": "application/json"]

    /// An answer as an object; nil for one that is none, or is past 1 MB.
    static func object(_ data: Data) -> [String: Any]? {
        guard data.count <= 1024 * 1024 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The first non-empty string among `keys`, a number as its text.
    package static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let text = object[key] as? String {
                if !text.isEmpty { return text }
            } else if let number = object[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    /// A stored login's extra, when it is a string that says something.
    package static func string(_ extra: JSONValue?) -> String? {
        guard case .string(let text)? = extra, !text.isEmpty else { return nil }
        return text
    }

    /// A gate's refusal: its business code, and its words when it gave any.
    struct Refusal: Equatable {
        var code: Int
        var said: String?
    }

    /// The refusal an answer carries; nil for a success, which is code 0 or
    /// no code at all. An `error` string alone is a refusal of code 0.
    ///
    /// Where the gates put it, as each answered a made-up token on
    /// 2026-11-11: Trae's account gates under `ResponseMetadata.Error`, the
    /// code a string (`{"Code":"20101","Message":"Token invalid: …"}`);
    /// Trae's chat gate and Raccoon at the top (`{"code":1001,"message":…}`),
    /// Raccoon with a slug for `message` and its words in `details`.
    static func refusal(_ root: [String: Any]) -> Refusal? {
        let metadata = root["ResponseMetadata"] as? [String: Any]
        let envelope = metadata?["Error"] as? [String: Any] ?? root
        for key in ["code", "Code", "errCode", "ErrCode"] {
            let code: Int? = switch envelope[key] {
            case let number as NSNumber: number.intValue
            case let text as String: Int(text)
            default: nil
            }
            guard let code, code != 0 else { continue }
            return Refusal(
                code: code,
                said: firstString(envelope, ["details", "message", "Message", "msg", "Msg", "errMsg", "ErrMsg"])
            )
        }
        if let error = (root["error"] ?? root["Error"]) as? String, !error.isEmpty {
            return Refusal(code: 0, said: error)
        }
        return nil
    }
}
